import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../platform/file_usage.dart';

abstract interface class LocalStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

// App records and reconstructible catalog data have separate write queues.
// Download manifests continue using the ordinary single-file storage.
abstract interface class PartitionedStorage implements LocalStorage {
  String? get cacheReadError;
  Future<void> writeRecords(Map<String, dynamic> value);
  Future<void> writeCache(Map<String, dynamic> value);
}

const catalogCacheKeys = {
  'sourceCategories',
  'categorySlices',
  'pages',
  'hasMore',
  'searchCache',
  'discoveryCache',
  'catalogs',
  'episodeUpdatedAt',
  'episodes',
};

Map<String, dynamic> _recordsPart(Map<String, dynamic> value) => {
  for (final entry in value.entries)
    if (!catalogCacheKeys.contains(entry.key)) entry.key: entry.value,
};

Map<String, dynamic> _cachePart(Map<String, dynamic> value) => {
  for (final key in catalogCacheKeys)
    if (value.containsKey(key)) key: value[key],
};

class AppFileStorage implements PartitionedStorage {
  AppFileStorage(
    this.directory, {
    Future<String> Function(Object?) encodeCache = encodeJsonInBackground,
  }) : _records = FileStorage(directory, fileName: 'records.json'),
       _cache = FileStorage(
         directory,
         fileName: 'catalog-cache.json',
         encode: encodeCache,
       );

  final Directory directory;
  final FileStorage _records, _cache;
  _CacheWrite? _waitingCache;
  @override
  String? cacheReadError;

  @override
  Future<Map<String, dynamic>?> read() async {
    cacheReadError = null;
    // Damaged records must surface an error rather than silently reset history.
    final records = await _records.read();
    if (records == null) return null;
    Map<String, dynamic> cache = {};
    try {
      final saved = await _cache.read();
      if (saved != null) {
        if (saved['format'] != 'guoguo.catalog-cache' ||
            saved['version'] != 1 ||
            saved['cache'] is! Map) {
          throw const FormatException('目录缓存格式不兼容');
        }
        cache = _cachePart(Map<String, dynamic>.from(saved['cache'] as Map));
      }
    } catch (_) {
      cacheReadError = '目录缓存无法读取，可联网重新加载';
    }
    return {..._recordsPart(records), ...cache};
  }

  @override
  Future<void> writeRecords(Map<String, dynamic> value) =>
      _records.write(_recordsPart(value));

  @override
  Future<void> writeCache(Map<String, dynamic> value) {
    // Public map writes still detach at invocation, even when queued together.
    final detached = _detachJson(_cachePart(value)) as Map<String, dynamic>;
    return _queueCache(() => detached);
  }

  // Capture reconstructible state only when its write reaches the file queue.
  // Every caller waits for a committed snapshot covering its request; no timer
  // or unawaited debounce can leave an acknowledged save only in memory.
  Future<void> writeCacheSnapshot(Map<String, dynamic> Function() snapshot) =>
      _queueCache(
        () => _detachJson(_cachePart(snapshot())) as Map<String, dynamic>,
      );

  Future<void> _queueCache(Map<String, dynamic> Function() capture) {
    final waiting = _waitingCache;
    if (waiting != null) {
      waiting.capture = capture;
      return waiting.done;
    }
    final write = _CacheWrite(capture);
    _waitingCache = write;
    write.done = _cache._writeCaptured(() {
      if (identical(_waitingCache, write)) _waitingCache = null;
      return {
        'format': 'guoguo.catalog-cache',
        'version': 1,
        'cache': write.capture(),
      };
    });
    return write.done;
  }

  Future<int?> catalogCacheBytes() {
    _waitingCache = null;
    return _cache.bytes();
  }

  Future<void> clearCatalogCache() async {
    // Later requests must start after this barrier, never join an earlier save.
    _waitingCache = null;
    await _cache.clear();
    cacheReadError = null;
  }

  Future<File> preserveRecords() => _records.preserve();

  Future<File> replaceRecordsPreserving(Map<String, dynamic> value) =>
      _records.replacePreserving(_recordsPart(value));

  Future<File> replaceRecordsPreservingFuture(
    Future<Map<String, dynamic>> value,
  ) => _records.replacePreservingFuture(value.then(_recordsPart));

  @override
  Future<void> write(Map<String, dynamic> value) async {
    // Detach both parts at invocation, before awaiting either write.
    final detached = _detachJson(value) as Map<String, dynamic>;
    await Future.wait([writeRecords(detached), writeCache(detached)]);
  }
}

class _CacheWrite {
  _CacheWrite(this.capture);
  Map<String, dynamic> Function() capture;
  late final Future<void> done;
}

class FileStorage implements LocalStorage {
  FileStorage(
    this.directory, {
    this.fileName = 'state.json',
    Future<String> Function(Object?) encode = encodeJsonInBackground,
  }) : _encode = encode;
  final Directory directory;
  final String fileName;
  final Future<String> Function(Object?) _encode;
  Future<void> _pending = Future.value();
  File get _file => File('${directory.path}/$fileName');
  @override
  Future<Map<String, dynamic>?> read() => _readJsonFileInBackground(_file.path);

  @override
  Future<void> write(Map<String, dynamic> value) {
    final detached = _detachJson(value) as Map<String, dynamic>;
    return _writeCaptured(() => detached);
  }

  Future<void> _writeCaptured(Map<String, dynamic> Function() capture) {
    return _serialized(() async {
      final snapshot = await _encode(capture());
      await _commit(snapshot);
    });
  }

  Future<void> _commit(String snapshot) async {
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(snapshot, flush: true);
    await temporary.rename(_file.path);
  }

  Future<File> preserve() => _serialized(_preserve);

  Future<File> replacePreserving(Map<String, dynamic> value) {
    final detached = _detachJson(value);
    return replacePreservingFuture(
      Future.value(detached as Map<String, dynamic>),
    );
  }

  Future<File> replacePreservingFuture(Future<Map<String, dynamic>> value) {
    value.ignore();
    return _serialized(() async {
      final snapshot = await _encode(await value);
      final original = await _preserve();
      await _commit(snapshot);
      return original;
    });
  }

  Future<File> _preserve() async {
    if (await FileSystemEntity.type(_file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('无法保留原记录文件');
    }
    final archive = await Directory(
      '${directory.path}/recovery',
    ).create(recursive: true);
    final destination = await archive.createTemp('records-');
    final saved = await _file.copy(
      '${destination.path}/guoguo-records-original.json',
    );
    final handle = await saved.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    return saved;
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  // Include the unfinished atomic-write file, but never sweep the parent.
  Future<int?> bytes() => _serialized(() async {
    final sizes = await Future.wait([
      fileBytes(_file),
      fileBytes(File('${_file.path}.tmp')),
    ]);
    return sizes.any((size) => size == null)
        ? null
        : sizes.fold<int>(0, (sum, size) => sum + size!);
  });

  Future<void> clear() => _serialized(() async {
    for (final file in [_file, File('${_file.path}.tmp')]) {
      try {
        // File deletion unlinks a symlink and refuses a directory collision.
        await file.delete();
      } on FileSystemException catch (error) {
        if (!missingFileScope(error, file.path)) rethrow;
      }
    }
  });
}

// Keep the isolate closure outside storage instances and their pending Futures.
Future<String> encodeJsonInBackground(Object? value) =>
    Isolate.run(() => jsonEncode(value));

// Transfer only the path, never storage instances or their queued operations.
// Read and decode together so UTF-8 conversion also stays off the UI isolate.
Future<Map<String, dynamic>?> _readJsonFileInBackground(String path) =>
    Isolate.run(() async {
      final file = File(path);
      if (!await file.exists()) return null;
      return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    }, debugName: 'guoguo.storage-read');

class MemoryStorage implements LocalStorage {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    value = Map<String, dynamic>.from(jsonDecode(jsonEncode(next)) as Map);
  }
}

Object? _detachJson(Object? value) {
  if (value is Map<String, dynamic>) {
    return {
      for (final entry in value.entries) entry.key: _detachJson(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _detachJson(item)];
  return value;
}
