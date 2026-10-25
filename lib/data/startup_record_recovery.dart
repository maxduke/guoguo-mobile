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

  Future<void> restore(RecordBackup backup) => storage
      .replaceRecordsPreservingFuture(
        validateRecordBackup(
          backup,
        ).then((validated) => {'version': 1, 'records': validated.toJson()}),
      )
      .then((_) {});

  Future<void> startFresh() => restore(RecordBackup([], []));
}
