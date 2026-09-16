import 'package:background_downloader/background_downloader.dart';

/// Isolates native task operations so recovery can be tested with real files.
class DownloadDriver {
  final FileDownloader downloader = FileDownloader();
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
