import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/models.dart';
import '../domain/user_input_exception.dart';

const maxRecordBackupBytes = 20 * 1024 * 1024;

Uint8List encodeRecordBackup(RecordBackup backup) {
  final document = backup.toJson();
  try {
    RecordBackup.fromJson(document);
  } catch (_) {
    throw const UserInputException('当前记录无法生成有效备份，原记录已保留');
  }
  final sink = _BackupBytes();
  final encoder = JsonUtf8Encoder().startChunkedConversion(sink);
  encoder.add(document);
  encoder.close();
  return sink.bytes.takeBytes();
}

class _BackupBytes extends ByteConversionSink {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > maxRecordBackupBytes) {
      throw const UserInputException('记录备份超过 20 MB，未生成备份文件');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

bool _smallBackup(RecordBackup backup) {
  if (backup.seasonReminders.isNotEmpty ||
      backup.favorites.length + backup.history.length > 64) {
    return false;
  }
  var size = 0;
  for (final record in backup.history) {
    size += record.episodeId.length * 3;
    if (size > 64 * 1024) return false;
  }
  for (final drama in [
    ...backup.favorites,
    ...backup.history.map((r) => r.drama),
  ]) {
    size +=
        512 +
        3 *
            (drama.id.length +
                drama.title.length +
                drama.description.length +
                drama.cover.length +
                drama.category.length +
                drama.heat.length +
                drama.date.length +
                drama.status.length);
    if (size > 64 * 1024) return false;
    for (final tag in drama.tags) {
      size += 8 + tag.length * 3;
      if (size > 64 * 1024) return false;
    }
  }
  return true;
}

Future<Uint8List> encodeRecordBackupBytes(RecordBackup backup) =>
    _smallBackup(backup)
    ? Future.sync(() => encodeRecordBackup(backup))
    : Isolate.run(
        () => encodeRecordBackup(backup),
        debugName: 'guoguo.backup-write',
      );

// Isolate submission copies the model graph before returning. Validation and
// JSON-model conversion run off the UI isolate, without a JSON string roundtrip.
Future<RecordBackup> validateRecordBackup(RecordBackup backup) {
  RecordBackup validate() {
    try {
      return RecordBackup.fromJson(backup.toJson());
    } catch (_) {
      throw const UserInputException('备份损坏或格式不兼容，原记录未修改');
    }
  }

  return _smallBackup(backup)
      ? Future.sync(validate)
      : Isolate.run(validate, debugName: 'guoguo.backup-validate');
}

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
