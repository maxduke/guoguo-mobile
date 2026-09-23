import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'download_recovery_test.dart' show FakeDriver, PlanProvider;

class _Driver extends FakeDriver {
  bool allowCancel = true, allowPause = true, deleteFails = false;
  Completer<bool>? cancelGate;
  @override
  Future<bool> cancel(Iterable<String> ids) async {
    if (cancelGate != null) return cancelGate!.future;
    if (!allowCancel) return false;
    for (final id in ids) {
      final record = saved[id];
      if (record != null && record.status != TaskStatus.complete) {
        saved[id] = record.copyWith(status: TaskStatus.canceled);
      }
    }
    return super.cancel(ids);
  }

  @override
  Future<bool> pause(DownloadTask task) async {
    if (allowPause) {
      saved[task.taskId] = saved[task.taskId]!.copyWith(
        status: TaskStatus.paused,
      );
    }
    return allowPause;
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    saved[task.taskId] = saved[task.taskId]!.copyWith(
      status: TaskStatus.running,
    );
    return true;
  }

  @override
  Future<void> deleteRecord(String id) async {
    if (deleteFails) throw StateError('database unavailable');
    await super.deleteRecord(id);
  }
}

class _Store extends DownloadStore {
  _Store(
    super.app, {
    required super.driver,
    required super.storage,
    required super.root,
  });
  int scans = 0;
  @override
  Future<void> refreshUsage() {
    scans++;
    return super.refreshUsage();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Driver driver;
  late _Store store;
  late AppStore app;
  late MemoryStorage storage;
  late DownloadEntry entry;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('guoguo-management-');
    driver = _Driver();
    storage = MemoryStorage();
    app = AppStore(storage: MemoryStorage(), provider: PlanProvider());
    store = _Store(app, driver: driver, storage: storage, root: root);
    final directory = await Directory('${root.path}/123').create();
    entry = DownloadEntry(
      id: '123',
      drama: const Drama(
        id: '1',
        source: DramaSource.huangguo,
        title: 'fixture',
      ),
      episode: Episode.fromJson({'id': '1'}, 0),
      index: 0,
      directory: directory.path,
      input: 'video.mp4',
      contentKey: '',
      process: false,
      tasks: [
        for (var i = 0; i < 2; i++)
          DownloadTask(
            taskId: '123_$i',
            url: 'https://example.com/$i',
            filename: '$i.bin',
            group: DownloadStore.group,
          ),
      ],
    );
    store.entries.add(entry);
    await File('${directory.path}/0.bin').writeAsBytes(List.filled(100, 0));
    await File('${directory.path}/1.bin').writeAsBytes(List.filled(50, 0));
    driver.saved['123_0'] = TaskRecord(
      entry.tasks[0],
      TaskStatus.complete,
      1,
      100,
    );
    driver.saved['123_1'] = TaskRecord(
      entry.tasks[1],
      TaskStatus.running,
      .5,
      100,
    );
  });
  tearDown(() async {
    store.dispose();
    app.dispose();
    await root.delete(recursive: true);
  });

  test(
    'disk usage counts saved nested files but never follows symlinks',
    () async {
      await Directory('${entry.directory}/nested').create();
      await File(
        '${entry.directory}/nested/temp',
      ).writeAsBytes(List.filled(25, 0));
      final external = await File(
        '${root.path}/external',
      ).writeAsBytes(List.filled(999, 0));
      await Link('${entry.directory}/link').create(external.path);
      final first = store.refreshUsage();
      expect(identical(first, store.refreshUsage()), isTrue);
      await first;
      expect(store.bytesFor([entry]), 175);
      await File('${entry.directory}/nested/temp').delete();
      await store.refreshUsage();
      expect(store.bytesFor([entry]), 150);
    },
  );

  test(
    'progress events do not rescan disk; failed progress keeps completed bytes',
    () async {
      await store.reload();
      expect(entry.phase, DownloadPhase.downloading);
      expect(entry.progress, .75);
      expect(entry.totalBytes, 200);
      expect(entry.downloadedBytes, 150);
      final scans = store.scans;
      driver.saved['123_1'] = TaskRecord(
        entry.tasks[1],
        TaskStatus.failed,
        -1,
        100,
      );
      await store.reload(verifyFiles: false);
      expect(store.scans, scans);
      expect(entry.phase, DownloadPhase.failed);
      expect(entry.progress, .5);
      expect(entry.downloadedBytes, 100);
      expect(entry.canRetry, isTrue);
      await store.reload(verifyFiles: false);
      expect(entry.progress, .5);
    },
  );

  test(
    'automatic retry and native pause are distinct states with correct actions',
    () async {
      driver.saved['123_1'] = TaskRecord(
        entry.tasks[1],
        TaskStatus.waitingToRetry,
        -4,
        -1,
      );
      await store.reload(verifyFiles: false);
      expect(entry.phase, DownloadPhase.retrying);
      expect(entry.canPause, isTrue);
      expect(entry.totalBytes, isNull);
      driver.saved['123_1'] = TaskRecord(
        entry.tasks[1],
        TaskStatus.paused,
        .5,
        100,
      );
      await store.reload(verifyFiles: false);
      expect(entry.phase, DownloadPhase.paused);
      expect(entry.canResume, isTrue);
      await store.resume(entry);
      expect(entry.phase, DownloadPhase.downloading);
      await store.pause(entry);
      expect(entry.phase, DownloadPhase.paused);
    },
  );

  test(
    'finished transfers waiting for foreground processing are not called downloading',
    () async {
      store.didChangeAppLifecycleState(AppLifecycleState.paused);
      driver.saved['123_1'] = TaskRecord(
        entry.tasks[1],
        TaskStatus.complete,
        1,
        100,
      );
      await store.reload(verifyFiles: false);
      expect(entry.phase, DownloadPhase.waitingProcessing);
      expect(entry.complete, isFalse);
      expect(entry.progress, 1);
      expect(entry.canPause, isTrue);
    },
  );

  test(
    'cancel rejection preserves files and records; successful removal clears both',
    () async {
      await store.refreshUsage();
      driver.allowCancel = false;
      await expectLater(store.remove(entry), throwsA(isA<ProviderException>()));
      expect(store.entries, [entry]);
      expect(driver.saved.length, 2);
      expect(await File('${entry.directory}/0.bin').length(), 100);
      expect(store.bytesFor([entry]), 150);
      driver.allowCancel = true;
      await store.remove(entry);
      expect(store.entries, isEmpty);
      expect(driver.saved, isEmpty);
      expect(await Directory(entry.directory).exists(), isFalse);
      expect(storage.value!['jobs'], isEmpty);
      expect(store.bytesByEntry, isEmpty);
    },
  );

  test(
    'record removal failure cannot leave a nonexistent video marked playable',
    () async {
      entry.ready = true;
      driver.deleteFails = true;
      await expectLater(store.remove(entry), throwsStateError);
      expect(entry.ready, isFalse);
      expect(entry.canRetry, isTrue);
      expect(store.bytesFor([entry]), 0);
      expect((storage.value!['jobs'] as List).single['ready'], false);
      driver.deleteFails = false;
      await store.remove(entry);
      expect(store.entries, isEmpty);
    },
  );

  test(
    'overlapping removal and pause report busy rather than claiming success',
    () async {
      driver.cancelGate = Completer<bool>();
      final removal = store.remove(entry);
      await expectLater(store.pause(entry), throwsA(isA<ProviderException>()));
      await expectLater(store.remove(entry), throwsA(isA<ProviderException>()));
      driver.cancelGate!.complete(true);
      await removal;
      expect(store.entries, isEmpty);
    },
  );

  test(
    'pause and resume failures persist an actionable failure state',
    () async {
      driver.allowPause = false;
      driver.allowCancel = false;
      await expectLater(store.pause(entry), throwsA(isA<ProviderException>()));
      expect(entry.phase, DownloadPhase.failed);
      expect(entry.failure, contains('暂停'));
      entry.userPaused = true;
      driver.saved['123_1'] = TaskRecord(
        entry.tasks[1],
        TaskStatus.canceled,
        0,
        -1,
      );
      driver.failSubmit = true;
      await expectLater(store.resume(entry), throwsStateError);
      expect(entry.phase, DownloadPhase.failed);
      expect((storage.value!['jobs'] as List).single['failure'], isNotNull);
    },
  );
}
