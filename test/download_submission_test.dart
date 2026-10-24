import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

import 'download_recovery_test.dart' show FakeDriver, PlanProvider;

class _SubmittingDriver extends FakeDriver {
  final entered = Completer<void>(), release = Completer<void>();
  bool rejectCancel = false, rejectSubmit = false;
  @override
  Future<bool> enqueue(DownloadTask task) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    if (rejectSubmit) return false;
    return super.enqueue(task);
  }

  @override
  Future<bool> cancel(Iterable<String> ids) async {
    if (rejectCancel) return false;
    for (final id in ids) {
      final record = saved[id];
      if (record != null && record.status != TaskStatus.complete) {
        saved[id] = record.copyWith(status: TaskStatus.canceled);
      }
    }
    return super.cancel(ids);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(id: 'd', source: DramaSource.hongguo, title: '提交交错');
  final episode = Episode.fromJson({'id': 'e'}, 0);
  late Directory root;
  late AppStore app;
  late DownloadStore store;
  late MemoryStorage storage;
  late _SubmittingDriver driver;
  var disposed = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-submission-');
    app = AppStore(storage: MemoryStorage(), provider: PlanProvider());
    storage = MemoryStorage();
    driver = _SubmittingDriver();
    store = DownloadStore(app, driver: driver, storage: storage, root: root);
    disposed = false;
  });
  tearDown(() async {
    if (!disposed) store.dispose();
    app.dispose();
    await root.delete(recursive: true);
  });

  for (final action in ['pause', 'remove']) {
    test(
      '$action drains an in-flight first submission before stopping tasks',
      () async {
        final enqueue = store.enqueue(drama, episode, 0);
        await driver.entered.future;
        final entry = store.entries.single;
        var finished = false;
        final stopping =
            (action == 'pause' ? store.pause(entry) : store.remove(entry)).then(
              (_) => finished = true,
            );
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        expect(driver.canceled, isEmpty);
        driver.release.complete();
        await Future.wait([enqueue, stopping]);
        expect(driver.submitted, hasLength(1));
        expect(driver.canceled, contains(entry.tasks.first.taskId));
        expect(
          driver.saved.values.every((r) => r.status == TaskStatus.canceled),
          isTrue,
        );
        if (action == 'pause') {
          expect(entry.phase, DownloadPhase.paused);
          expect((storage.value!['jobs'] as List).single['userPaused'], isTrue);
          await store.resume(entry);
          expect(driver.saved, hasLength(2));
          expect(
            driver.saved.values.every((r) => r.status == TaskStatus.enqueued),
            isTrue,
          );
        } else {
          expect(store.entries, isEmpty);
          expect(driver.saved, isEmpty);
          expect(await Directory(entry.directory).exists(), isFalse);
          expect(storage.value!['jobs'], isEmpty);
        }
      },
    );
  }

  test(
    'disposal stops late submissions and preserves a resumable entry',
    () async {
      final enqueue = store.enqueue(drama, episode, 0);
      await driver.entered.future;
      final entry = store.entries.single;
      store.dispose();
      disposed = true;
      driver.release.complete();
      await enqueue;
      expect(driver.submitted, hasLength(1));
      expect(
        driver.saved.values.every((r) => r.status == TaskStatus.canceled),
        isTrue,
      );
      expect((storage.value!['jobs'] as List).single['userPaused'], isTrue);
      expect(await Directory(entry.directory).exists(), isTrue);
    },
  );

  test(
    'cancel rejection after interrupted submission preserves actionable work',
    () async {
      final enqueue = store.enqueue(drama, episode, 0);
      await driver.entered.future;
      final entry = store.entries.single;
      driver.rejectCancel = true;
      final removing = expectLater(
        store.remove(entry),
        throwsA(isA<ProviderException>()),
      );
      driver.release.complete();
      await Future.wait([enqueue, removing]);
      expect(store.entries, [entry]);
      expect(entry.canRetry, isTrue);
      expect(await Directory(entry.directory).exists(), isTrue);
      expect(driver.submitted, hasLength(1));
      driver.rejectCancel = false;
      await store.remove(entry);
      expect(store.entries, isEmpty);
      expect(driver.saved, isEmpty);
    },
  );

  test(
    'a blocked submission and pause do not block a different episode',
    () async {
      final first = store.enqueue(drama, episode, 0);
      await driver.entered.future;
      final entry = store.entries.single;
      final pausing = store.pause(entry);
      final other = Episode.fromJson({'id': 'other'}, 1);
      await store.enqueue(drama, other, 1);
      final otherEntry = store.entryFor(drama, other)!;
      expect(driver.submitted, hasLength(2));
      driver.release.complete();
      await Future.wait([first, pausing]);
      expect(entry.phase, DownloadPhase.paused);
      expect(otherEntry.userPaused, isFalse);
      expect(
        otherEntry.tasks.every(
          (t) => driver.saved[t.taskId]?.status == TaskStatus.enqueued,
        ),
        isTrue,
      );
    },
  );

  test(
    'a rejected submission remains retryable with its plan and files',
    () async {
      driver.rejectSubmit = true;
      final enqueue = expectLater(
        store.enqueue(drama, episode, 0),
        throwsA(isA<ProviderException>()),
      );
      await driver.entered.future;
      driver.release.complete();
      await enqueue;
      final entry = store.entries.single;
      expect(entry.canRetry, isTrue);
      expect(
        await File('${entry.directory}/${entry.input}').readAsString(),
        'fixture playlist',
      );
      driver.rejectSubmit = false;
      await store.retry(entry);
      expect(driver.submitted, hasLength(2));
      expect(entry.failure, isNull);
    },
  );
}
