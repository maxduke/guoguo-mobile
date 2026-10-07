import 'dart:async';

import 'package:background_downloader/background_downloader.dart';

/// Isolates native task operations so recovery can be tested with real files.
class DownloadDriver {
  final FileDownloader downloader = FileDownloader();
  // The plugin exposes a single-subscription stream for its process-wide
  // downloader. Share it so a failed startup can detach and subscribe again.
  static final _updates = FileDownloader().updates.asBroadcastStream();
  Stream<TaskUpdate> get updates => _updates;
  Future<void> trackTasks() async => downloader.trackTasks();
  Future<bool> requireWiFi(bool cellular) => downloader.requireWiFi(
    cellular ? RequireWiFi.forNoTasks : RequireWiFi.forAllTasks,
  );
  Future<void> start() async => downloader.start();
  Future<List<TaskRecord>> records() =>
      downloader.database.allRecords(group: 'guoguo');
  Future<TaskRecord?> record(String id) => downloader.database.recordForId(id);
  Future<bool> enqueue(DownloadTask task) => downloader.enqueue(task);
  Future<bool> pause(DownloadTask task) => downloader.pause(task);
  Future<bool> resume(DownloadTask task) => downloader.resume(task);
  Future<bool> cancel(Iterable<String> ids) =>
      downloader.cancelTasksWithIds(ids);
  Future<void> deleteRecord(String id) =>
      downloader.database.deleteRecordWithId(id);
}
