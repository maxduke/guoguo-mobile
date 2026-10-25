import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/models.dart';
import '../domain/user_input_exception.dart';

const maxRecordBackupBytes = 20 * 1024 * 1024;

RecordBackup decodeRecordBackup(String raw) {
  if (raw.length > maxRecordBackupBytes ||
      utf8.encode(raw).length > maxRecordBackupBytes) {
    throw const UserInputException('备份文件超过 20 MB');
  }
  try {
    return RecordBackup.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  } catch (_) {
    throw const UserInputException('备份损坏或格式不兼容，原记录未修改');
  }
}

Future<RecordBackup> decodeRecordBackupBytes(Uint8List bytes) async {
  if (bytes.length > maxRecordBackupBytes) {
    throw const UserInputException('备份文件超过 20 MB');
  }
  RecordBackup decode() {
    try {
      return decodeRecordBackup(utf8.decode(bytes));
    } on FormatException {
      throw const UserInputException('备份损坏或格式不兼容，原记录未修改');
    }
  }

  // Small backups avoid isolate startup and transfer costs.
  if (bytes.length <= 64 * 1024) return decode();
  return Isolate.run(decode, debugName: 'guoguo.backup-read');
}
