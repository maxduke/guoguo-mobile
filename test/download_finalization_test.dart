import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';

import 'download_recovery_test.dart' show FakeDriver, PlanProvider;

class _ManifestStorage extends MemoryStorage {
  bool fail = false;
  int failuresRemaining = 0, writes = 0;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    if (fail || failuresRemaining > 0) {
      if (failuresRemaining > 0) failuresRemaining--;
      throw const FileSystemException('manifest disk full');
    }
    await super.write(value);
  }
}

class _RecordsDriver extends FakeDriver {
  Completer<void>? gate, entered;

  @override
  Future<List<TaskRecord>> records() async {
    final waiting = gate;
    gate = null;
    if (waiting != null) {
      entered!.complete();
      await waiting.future;
    }
    return super.records();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore app;
  late DownloadStore downloads;
  late _RecordsDriver driver;
  late _ManifestStorage storage;
  late DownloadEntry entry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-finalization-');
    app = AppStore(storage: MemoryStorage(), provider: PlanProvider());
    driver = _RecordsDriver();
    storage = _ManifestStorage();
    final directory = await Directory('${root.path}/123').create();
    final task = DownloadTask(
      taskId: '123_video',
      url: 'https://fixtures.invalid/video.mp4',
      filename: 'video.mp4',
      group: DownloadStore.group,
      metaData: '123',
    );
    entry = DownloadEntry(
      id: '123',
      drama: const Drama(id: 'd', source: DramaSource.hongguo, title: '下载回归'),
      episode: Episode.fromJson({'id': 'episode', 'number': 1}, 0),
      index: 0,
      directory: directory.path,
      input: 'video.mp4',
      contentKey: '',
      process: false,
      tasks: [task],
    );
    await File(entry.output).writeAsString('saved download bytes');
    await storage.write({
      'version': 1,
      'jobs': [entry.toJson()],
    });
    driver.saved[task.taskId] = TaskRecord(task, TaskStatus.complete, 1, 20);
    downloads = DownloadStore(app, driver: driver, storage: storage, root: root)
      ..entries.add(entry);
  });

  tearDown(() async {
    downloads.dispose();
    app.dispose();
    await root.delete(recursive: true);
  });

  Future<void> finish() async {
    final finished = Completer<void>();
    void changed() {
      if (!entry.processing &&
          (entry.ready || entry.failure != null) &&
          !finished.isCompleted) {
        finished.complete();
      }
    }

    downloads.addListener(changed);
    try {
      await downloads.reload(verifyFiles: false);
      await finished.future.timeout(const Duration(seconds: 5));
      // Drain the automatic progress-only reload following finalization.
      await Future<void>.delayed(Duration.zero);
    } finally {
      downloads.removeListener(changed);
    }
  }

  test(
    'manifest failure keeps the saved video complete and recoverable',
    () async {
      storage.fail = true;
      await finish();
      expect(entry.ready, isTrue);
      expect(entry.failure, isNull);
      expect(entry.phase, DownloadPhase.complete);
      expect(entry.status, TaskStatus.complete);
      expect(downloads.error, contains('下载记录保存失败'));
      expect(downloads.error, contains('下拉刷新'));
      expect((storage.value!['jobs'] as List).single['ready'], isFalse);
      expect(
        await downloads.localFile(entry.drama, entry.episode),
        entry.output,
      );

      final attempts = storage.writes;
      await downloads.reload(verifyFiles: false);
      await downloads.reload(verifyFiles: false);
      expect(storage.writes, attempts);
      expect(downloads.error, contains('下载记录保存失败'));

      await downloads.reload();
      expect(storage.writes, attempts + 1);
      expect(downloads.error, contains('下载记录保存失败'));
      expect(entry.ready, isTrue);
      expect(entry.failure, isNull);
      expect((storage.value!['jobs'] as List).single['ready'], isFalse);

      storage.fail = false;
      await downloads.reload();
      expect(downloads.error, isNull);
      final saved = (storage.value!['jobs'] as List).single;
      expect(saved['ready'], isTrue);
      expect(saved['failure'], isNull);
      expect(await File(entry.output).readAsString(), 'saved download bytes');
      expect(driver.submitted, isEmpty);
      expect(driver.canceled, isEmpty);
    },
  );

  test(
    'a transient manifest failure does not persist a media failure',
    () async {
      storage.failuresRemaining = 1;
      await finish();
      expect(entry.ready, isTrue);
      expect(entry.failure, isNull);
      expect(entry.phase, DownloadPhase.complete);
      expect(downloads.error, isNull);
      final saved = (storage.value!['jobs'] as List).single;
      expect(saved['ready'], isTrue);
      expect(saved['failure'], isNull);
    },
  );

  test('a refresh queued during progress retries the manifest once', () async {
    storage.fail = true;
    await finish();
    final attempts = storage.writes;
    storage.fail = false;
    final release = Completer<void>();
    driver.gate = release;
    driver.entered = Completer<void>();
    final progress = downloads.reload(verifyFiles: false);
    try {
      await driver.entered!.future;
      await downloads.reload();
    } finally {
      release.complete();
    }
    await progress;
    expect(storage.writes, attempts + 1);
    expect(downloads.error, isNull);
    expect((storage.value!['jobs'] as List).single['ready'], isTrue);
    expect(entry.failure, isNull);
  });

  for (final missing in [false, true]) {
    test(
      '${missing ? 'missing' : 'empty'} output remains a media failure',
      () async {
        final file = File(entry.output);
        if (missing) {
          await file.delete();
        } else {
          await file.writeAsBytes([]);
        }
        await finish();
        expect(entry.ready, isFalse);
        expect(entry.canRetry, isTrue);
        expect(entry.failure, contains('视频整理失败'));
        expect(downloads.error, isNull);
        final saved = (storage.value!['jobs'] as List).single;
        expect(saved['ready'], isFalse);
        expect(saved['failure'], entry.failure);
      },
    );
  }
}
