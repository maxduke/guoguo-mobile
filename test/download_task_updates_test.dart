import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/download_task_updates.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'download_initialization_test.dart' show InitializationDriver;
import 'download_recovery_test.dart' show PlanProvider;

class EventDriver extends InitializationDriver {
  final events = StreamController<TaskUpdate>.broadcast();
  int snapshots = 0;
  Completer<void>? snapshotGate;
  final snapshotStarted = Completer<void>();
  @override
  Stream<TaskUpdate> get updates => events.stream;
  @override
  Future<List<TaskRecord>> records() async {
    snapshots++;
    final result = await super.records();
    if (snapshotGate != null) {
      if (!snapshotStarted.isCompleted) snapshotStarted.complete();
      await snapshotGate!.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('coalesced updates retain status, bytes and terminal completion', () {
    final task = DownloadTask(
      taskId: 'one',
      url: 'https://example.org/video.mp4',
      group: 'guoguo',
    );
    final state = DownloadTaskUpdates();
    state.add(TaskStatusUpdate(task, TaskStatus.running));
    for (var i = 0; i < 100; i++) {
      state.add(TaskProgressUpdate(task, i / 100, 1000));
    }
    state.apply();
    expect(state.records[task.taskId]!.status, TaskStatus.running);
    expect(state.records[task.taskId]!.progress, .99);
    expect(state.records[task.taskId]!.expectedFileSize, 1000);
    state.add(TaskProgressUpdate(task, 1, 1000));
    state.apply();
    expect(state.records[task.taskId]!.status, TaskStatus.running);
    expect(state.records[task.taskId]!.progress, 1);
    state.add(TaskStatusUpdate(task, TaskStatus.complete));
    state.add(TaskStatusUpdate(task, TaskStatus.running));
    state.add(TaskProgressUpdate(task, .8, 1000));
    state.apply();
    expect(state.records[task.taskId]!.status, TaskStatus.complete);
    expect(state.records[task.taskId]!.progress, 1);
    state.resetTask(task.taskId);
    state.add(TaskProgressUpdate(task, .1, 1000));
    state.apply();
    expect(state.records[task.taskId]!.status, TaskStatus.running);
    expect(state.records[task.taskId]!.progress, .1);
  });

  test(
    'task events update their own entry without full database snapshots',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'download-incremental-',
      );
      final driver = EventDriver();
      final app = AppStore(storage: MemoryStorage(), provider: PlanProvider());
      final rows = <DownloadEntry>[];
      for (var i = 1; i <= 2; i++) {
        final folder = await Directory('${root.path}/$i').create();
        final tasks = List.generate(
          2,
          (n) => DownloadTask(
            taskId: '${i}_$n',
            url: 'https://example.org/$i/$n',
            directory: 'guoguo/$i',
            filename: '$n.bin',
            metaData: '$i',
            group: 'guoguo',
          ),
        );
        for (final task in tasks) {
          driver.saved[task.taskId] = TaskRecord(
            task,
            TaskStatus.running,
            0,
            100,
          );
        }
        rows.add(
          DownloadEntry(
            id: '$i',
            drama: Drama(
              id: '$i',
              source: DramaSource.hongguo,
              title: 'sample $i',
            ),
            episode: Episode.fromJson({'id': 'one'}, 0),
            index: 0,
            directory: folder.path,
            input: 'video.mp4',
            contentKey: '',
            process: false,
            tasks: tasks,
          ),
        );
      }
      final storage = MemoryStorage()
        ..value = {'version': 1, 'jobs': rows.map((e) => e.toJson()).toList()};
      final downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
      );
      addTearDown(() async {
        downloads.dispose();
        app.dispose();
        await driver.events.close();
        await root.delete(recursive: true);
      });
      await downloads.initialize();
      expect(downloads.initializationError, isNull);
      final initial = driver.snapshots;
      for (var i = 1; i <= 80; i++) {
        driver.events.add(
          TaskProgressUpdate(rows.first.tasks.first, i / 100, 100),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(driver.snapshots, initial);
      expect(downloads.entries.first.progress, .4);
      expect(downloads.entries.last.progress, 0);
      driver.events.add(
        TaskStatusUpdate(
          rows.first.tasks.first,
          TaskStatus.failed,
          TaskHttpException('private URL', 403),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(driver.snapshots, initial);
      expect(downloads.entries.first.failure, contains('HTTP 403'));
      expect(downloads.entries.first.failure, isNot(contains('private')));
      driver.events.add(TaskProgressUpdate(rows.last.tasks.first, .5, 100));
      await downloads.remove(downloads.entries.last);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(downloads.entries, hasLength(1));
      expect(driver.snapshots, initial);
      await downloads.reload(verifyFiles: false);
      expect(driver.snapshots, initial + 1);
      driver.snapshotGate = Completer<void>();
      final refreshing = downloads.reload(verifyFiles: false);
      await driver.snapshotStarted.future;
      driver.events.add(TaskProgressUpdate(rows.first.tasks.first, .5, 100));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      driver.snapshotGate!.complete();
      await refreshing;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(driver.snapshots, initial + 2);
      expect(downloads.entries.first.progress, .25);
    },
  );
}
