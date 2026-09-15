import 'dart:convert';
import 'dart:io';

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
    final snapshot = jsonEncode(value);
    final operation = _pending.catchError((Object _) {}).then((_) async {
      await directory.create(recursive: true);
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(_file.path);
    });
    _pending = operation;
    return operation;
  }
}

class MemoryStorage implements LocalStorage {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    value = Map<String, dynamic>.from(jsonDecode(jsonEncode(next)) as Map);
  }
}
