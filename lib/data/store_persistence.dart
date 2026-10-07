import '../domain/models.dart';

typedef SaveRecords = Future<void> Function({RecordBackup? candidate});

abstract interface class StorePersistence {
  String? get persistenceError;
  Future<void> persist({bool records = true, bool cache = true});

  // The supplied saver writes directly within the operation, never re-enqueues.
  Future<T> updateRecords<T>(Future<T> Function(SaveRecords save) operation);
}
