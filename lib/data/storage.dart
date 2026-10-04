import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  AppFileStorage(this.directory)
    : _records = FileStorage(directory, fileName: 'records.json'),
      _cache = FileStorage(directory, fileName: 'catalog-cache.json'),
      _legacy = FileStorage(directory);

  final Directory directory;
  final FileStorage _records, _cache, _legacy;
  bool _recordsReady = false, _cacheReady = false;
  @override
  String? cacheReadError;

  @override
  Future<Map<String, dynamic>?> read() async {
    // Once the new record file exists it is authoritative. A damaged record
    // file must surface an error, never resurrect an older watch position.
    _cacheReady = false;
    final records = await _records.read();
    _recordsReady = records != null;
    final legacy = records == null ? await _legacy.read() : null;
    final durable = records ?? legacy;
    if (durable == null) return null;
    Map<String, dynamic> cache = {};
    cacheReadError = null;
    try {
      final saved = await _cache.read();
      if (saved != null) {
        if (saved['format'] != 'guoguo.catalog-cache' ||
            saved['version'] != 1 ||
            saved['cache'] is! Map) {
          throw const FormatException('目录缓存格式不兼容');
        }
        cache = _cachePart(Map<String, dynamic>.from(saved['cache'] as Map));
        _cacheReady = true;
      } else {
        // An interrupted migration may have committed records only. Keep the
        // legacy file until both independent replacement files are committed.
        cache = _cachePart(legacy ?? await _legacy.read() ?? {});
      }
    } catch (_) {
      cacheReadError = '目录缓存无法读取，可联网重新加载';
      _cacheReady = false;
    }
    return {..._recordsPart(durable), ...cache};
  }

  @override
  Future<void> writeRecords(Map<String, dynamic> value) async {
    await _records.write(_recordsPart(value));
    _recordsReady = true;
    await _retireLegacy();
  }

  @override
  Future<void> writeCache(Map<String, dynamic> value) async {
    await _cache.write({
      'format': 'guoguo.catalog-cache',
      'version': 1,
      'cache': _cachePart(value),
    });
    _cacheReady = true;
    await _retireLegacy();
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    // Detach both parts at invocation, before awaiting either write.
    final detached = _detachJson(value) as Map<String, dynamic>;
    await Future.wait([writeRecords(detached), writeCache(detached)]);
  }

  Future<void> _retireLegacy() async {
    if (!_recordsReady || !_cacheReady) return;
    try {
      if (await _legacy._file.exists()) await _legacy._file.delete();
    } on FileSystemException {
      // Cleanup failure must not turn a committed record save into a failure.
    }
  }
}

class FileStorage implements LocalStorage {
  FileStorage(this.directory, {this.fileName = 'state.json'});
  final Directory directory;
  final String fileName;
  Future<void> _pending = Future.value();
  File get _file => File('${directory.path}/$fileName');
  @override
  Future<Map<String, dynamic>?> read() async {
    if (!await _file.exists()) return null;
    return Map<String, dynamic>.from(
      jsonDecode(await _file.readAsString()) as Map,
    );
  }

  @override
  Future<void> write(Map<String, dynamic> value) {
    final detached = _detachJson(value) as Map<String, dynamic>;
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final snapshot = await encodeJsonInBackground(detached);
      await directory.create(recursive: true);
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(_file.path);
    });
    _pending = operation;
    return operation;
  }
}

// Keep the isolate closure outside storage instances and their pending Futures.
Future<String> encodeJsonInBackground(Object? value) =>
    Isolate.run(() => jsonEncode(value));

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
