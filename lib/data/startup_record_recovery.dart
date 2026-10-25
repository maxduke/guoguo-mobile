import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'record_backup_codec.dart';
import 'storage.dart';

class RecordLoadFailure implements Exception {
  RecordLoadFailure(this.recovery);
  final StartupRecordRecovery recovery;
}

class StartupRecordRecovery {
  StartupRecordRecovery(this.storage);
  final AppFileStorage storage;

  Future<File> preserve() => storage.preserveRecords();

  Future<void> restore(RecordBackup backup) async {
    // Validate and detach before entering the file queue. Recovery creates only
    // the current records format; catalog cache and downloads keep their files.
    final validated = decodeRecordBackup(jsonEncode(backup.toJson()));
    await storage.replaceRecordsPreserving({
      'version': 1,
      'records': validated.toJson(),
    });
  }

  Future<void> startFresh() => restore(RecordBackup([], []));
}
