import 'package:background_downloader/background_downloader.dart';

/// Coalesce progress without querying the plugin database for every event.
/// Full reconciliation still supplies authoritative snapshots at lifecycle gates.
class DownloadTaskUpdates {
  final records = <String, TaskRecord>{};
  final _pending = <String, List<TaskUpdate>>{};
  bool get hasPending => _pending.isNotEmpty;

  void add(TaskUpdate update) {
    final events = _pending.putIfAbsent(update.task.taskId, () => []);
    if (update is TaskStatusUpdate &&
        update.status != TaskStatus.complete &&
        events.any(
          (event) =>
              event is TaskStatusUpdate && event.status == TaskStatus.complete,
        )) {
      return;
    }
    events.removeWhere((event) => event.runtimeType == update.runtimeType);
    events.add(update);
  }

  void resetTask(String id) {
    records.remove(id);
    _pending.remove(id);
  }

  void replace(Iterable<TaskRecord> snapshot, Set<String> owned) {
    records
      ..clear()
      ..addEntries(
        snapshot
            .where((r) => owned.contains(r.taskId))
            .map((r) => MapEntry(r.taskId, r)),
      );
  }

  Set<String> apply() {
    final changed = <String>{};
    for (final row in _pending.entries) {
      final previous = records[row.key];
      var record =
          previous ??
          TaskRecord(row.value.first.task, TaskStatus.enqueued, 0, -1);
      for (final event in row.value) {
        if (record.status == TaskStatus.complete) continue;
        record = switch (event) {
          TaskStatusUpdate() => TaskRecord(
            event.task,
            event.status,
            event.status == TaskStatus.complete ? 1 : record.progress,
            record.expectedFileSize,
            event.exception,
          ),
          TaskProgressUpdate() => TaskRecord(
            event.task,
            // Bytes reaching 100% do not confirm native file finalization.
            // Only TaskStatus.complete may start video processing.
            event.progress > 0 &&
                    {
                      TaskStatus.enqueued,
                      TaskStatus.waitingToRetry,
                    }.contains(record.status)
                ? TaskStatus.running
                : record.status,
            event.progress.isFinite ? event.progress : record.progress,
            event.expectedFileSize >= 0
                ? event.expectedFileSize
                : record.expectedFileSize,
            record.exception,
          ),
        };
      }
      records[row.key] = record;
      if (record != previous) changed.add(row.key);
    }
    _pending.clear();
    return changed;
  }
}
