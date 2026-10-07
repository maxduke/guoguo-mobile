import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';

import 'download_recovery_test.dart' show FakeDriver, PlanProvider;

class RestoreDriver extends FakeDriver {
  final rejected = <String>{};
  final throwing = <String>{};
  @override
  Future<bool> enqueue(DownloadTask task) async {
    if (throwing.contains(task.taskId)) {
      throw StateError('native https://secret.invalid/?token=secret');
    }
    if (rejected.contains(task.taskId)) return false;
    return super.enqueue(task);
  }
}

class RestoreStorage extends MemoryStorage {
  bool fail = false;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw const FileSystemException('full disk');
    await super.write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore app;
  late DownloadStore downloads;
  late RestoreDriver driver;
  late RestoreStorage storage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-restore-');
    driver = RestoreDriver();
    storage = RestoreStorage();
    app = AppStore(storage: MemoryStorage(), provider: PlanProvider());
    downloads = DownloadStore(
      app,
      driver: driver,
      storage: storage,
      root: root,
    );
    const drama = Drama(id: 'd', source: DramaSource.hongguo, title: '测试');
    await downloads.enqueue(drama, Episode.fromJson({'id': 'one'}, 0), 0);
    await downloads.enqueue(drama, Episode.fromJson({'id': 'two'}, 1), 1);
    driver.saved.clear();
    driver.submitted.clear();
  });
  tearDown(() async {
    downloads.dispose();
    app.dispose();
    await root.delete(recursive: true);
  });

  for (final throws in [false, true]) {
    test(
      'restored submission ${throws ? 'throw' : 'false'} fails only that entry and survives restart',
      () async {
        final failed = downloads.entries.first, other = downloads.entries.last;
        final retained = File('${failed.directory}/1.bin');
        await retained.writeAsString('keep partial data');
        (throws ? driver.throwing : driver.rejected).add(
          failed.tasks.first.taskId,
        );
        await downloads.restorePendingTasks();
        await downloads.reload(verifyFiles: false);
        expect(failed.canRetry, true);
        expect(failed.phase, DownloadPhase.failed);
        expect(failed.failure, isNotNull);
        expect(failed.failure, isNot(contains('secret')));
        expect(
          driver.submitted.map((t) => t.taskId),
          containsAll(other.tasks.map((t) => t.taskId)),
        );
        expect(await retained.readAsString(), 'keep partial data');
        final restarted =
            DownloadStore(app, driver: driver, storage: storage, root: root)
              ..entries = (storage.value!['jobs'] as List)
                  .map(
                    (row) => DownloadEntry.fromJson(
                      Map<String, dynamic>.from(row as Map),
                    ),
                  )
                  .toList();
        addTearDown(restarted.dispose);
        expect(restarted.entries.first.canRetry, true);
        driver.rejected.clear();
        driver.throwing.clear();
        await restarted.retry(restarted.entries.first);
        expect(restarted.entries.first.failure, isNull);
        expect(
          driver.submitted.map((t) => t.taskId),
          containsAll(failed.tasks.map((t) => t.taskId)),
        );
      },
    );
  }

  test(
    'manifest failure remains visible after reload while other entries recover',
    () async {
      final failed = downloads.entries.first, other = downloads.entries.last;
      driver.rejected.add(failed.tasks.first.taskId);
      storage.fail = true;
      await downloads.restorePendingTasks();
      await downloads.reload(verifyFiles: false);
      expect(failed.canRetry, true);
      expect(downloads.error, contains('下载记录保存失败'));
      expect(
        driver.submitted.map((t) => t.taskId),
        containsAll(other.tasks.map((t) => t.taskId)),
      );
      storage.fail = false;
      driver.rejected.clear();
      await downloads.retry(failed);
      expect(downloads.error, isNull);
      expect(failed.failure, isNull);
    },
  );

  test('paused and completed entries are not resubmitted on startup', () async {
    downloads.entries.first.userPaused = true;
    downloads.entries.last.ready = true;
    await downloads.restorePendingTasks();
    expect(driver.submitted, isEmpty);
  });
}
