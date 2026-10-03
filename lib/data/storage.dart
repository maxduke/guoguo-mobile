import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

abstract interface class LocalStorage {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
}

class FileStorage implements LocalStorage {
  FileStorage(this.directory);
  final Directory directory;
  Future<void> _pending = Future.value();
  File get _file => File('${directory.path}/state.json');
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
