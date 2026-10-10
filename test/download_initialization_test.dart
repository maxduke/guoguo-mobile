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

class InitializationDriver extends FakeDriver {
  bool failTrack = false, failRecords = false, wifiAccepted = true;
  int tracked = 0, rules = 0, started = 0;
  Completer<void>? trackGate;
  final tracking = Completer<void>();
  @override
  Future<void> trackTasks() async {
    tracked++;
    if (!tracking.isCompleted) tracking.complete();
    await trackGate?.future;
    if (failTrack) throw StateError('native failed');
  }

  @override
  Future<bool> requireWiFi(bool cellular) async {
    rules++;
    return wifiAccepted;
  }

  @override
  Future<void> start() async => started++;
  @override
  Future<List<TaskRecord>> records() async {
    if (failRecords) throw StateError('task database unavailable');
    return super.records();
  }
}

class InitializationStorage extends MemoryStorage {
  int reads = 0;
  Completer<Map<String, dynamic>?>? gate;
  final reading = Completer<void>();
  @override
  Future<Map<String, dynamic>?> read() async {
    reads++;
    if (!reading.isCompleted) reading.complete();
    return gate == null ? super.read() : gate!.future;
  }
}

class DelayedPlanProvider extends PlanProvider {
  final requested = Completer<void>(), released = Completer<void>();
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'downloadPlan') {
      requested.complete();
      await released.future;
    }
    return super.call(method, args);
  }
}

const drama = Drama(id: 'd', source: DramaSource.hongguo, title: '离线记录');
final episode = Episode.fromJson({'id': 'e', 'number': 4}, 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore app;
  late PlanProvider planProvider;
  late InitializationDriver driver;
  late InitializationStorage storage;
  late DownloadStore downloads;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-initialization-');
    planProvider = PlanProvider();
    app = AppStore(storage: MemoryStorage(), provider: planProvider);
    driver = InitializationDriver();
    storage = InitializationStorage();
    final folder = await Directory('${root.path}/123').create();
    await File('${folder.path}/video.mp4').writeAsString('saved video');
    final entry = DownloadEntry(
      id: '123',
      drama: drama,
      episode: episode,
      index: 0,
      directory: '/old/container/123',
      input: 'video.mp4',
      contentKey: '',
      process: false,
      tasks: [],
      ready: true,
    );
    storage.value = {
      'version': 1,
      'jobs': [entry.toJson()],
    };
    downloads = DownloadStore(
      app,
      driver: driver,
      storage: storage,
      root: root,
    );
  });

  tearDown(() async {
    downloads.dispose();
    app.dispose();
    await root.delete(recursive: true);
  });

  test(
    'usage waits for the manifest without waiting for native task recovery',
    () async {
      storage.gate = Completer<Map<String, dynamic>?>();
      driver.trackGate = Completer<void>();
      final initialization = downloads.initialize();
      await storage.reading.future;
      var measured = false;
      final measuring = downloads.refreshUsage().then((_) => measured = true);
      await Future<void>.delayed(Duration.zero);
      expect(measured, isFalse);
      storage.gate!.complete(storage.value);
      await measuring;
      expect(downloads.bytesFor(downloads.entries), 'saved video'.length);
      expect(downloads.manifestLoaded, isTrue);
      expect(downloads.initializing, isTrue);
      driver.trackGate!.complete();
      await initialization;
    },
  );

  test(
    'manifest read failure leaves usage unknown and allows measurement to finish',
    () async {
      storage.gate = Completer<Map<String, dynamic>?>();
      final initialization = downloads.initialize();
      await storage.reading.future;
      final measuring = downloads.refreshUsage();
      storage.gate!.completeError(StateError('manifest unavailable'));
      await Future.wait([initialization, measuring]);
      expect(downloads.manifestLoaded, isFalse);
      expect(downloads.usageError, isNotNull);
      expect(downloads.measuringUsage, isFalse);
    },
  );

  test(
    'saved videos are available before core readiness; mutations cannot race restoration',
    () async {
      downloads.dispose();
      final core = Completer<void>(), loaded = Completer<void>();
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
        waitForProvider: () => core.future,
      );
      downloads.addListener(() {
        if (downloads.manifestLoaded && !loaded.isCompleted) loaded.complete();
      });
      final initialization = downloads.initialize();
      expect(downloads.initialize(), same(initialization));
      await loaded.future;
      expect(downloads.initializing, true);
      expect(
        await downloads.localFile(drama, episode),
        '${root.path}/123/video.mp4',
      );
      expect(driver.tracked, 0);
      final entry = downloads.entries.single;
      final blocked = throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('尚未就绪'),
        ),
      );
      await expectLater(downloads.enqueue(drama, episode, 0), blocked);
      await expectLater(downloads.pause(entry), blocked);
      await expectLater(downloads.retry(entry), blocked);
      await expectLater(downloads.remove(entry), blocked);
      await expectLater(downloads.setCellular(true), blocked);
      expect(driver.submitted, isEmpty);
      expect(driver.canceled, isEmpty);
      core.complete();
      await initialization;
      expect(downloads.initialized, true);
      expect(downloads.initializationError, isNull);
      expect(
        [storage.reads, driver.tracked, driver.rules, driver.started],
        [1, 1, 1, 1],
      );
      expect(downloads.entries.single, same(entry));
      await downloads.initialize();
      expect(driver.tracked, 1);
    },
  );

  test(
    'native failure can retry without reloading or losing the loaded manifest',
    () async {
      driver.failTrack = true;
      await downloads.initialize();
      final entry = downloads.entries.single;
      expect(downloads.initialized, false);
      expect(downloads.initializationError, isNotNull);
      expect(await downloads.localFile(drama, episode), isNotNull);
      storage.value = {'jobs': []};
      driver.failTrack = false;
      final retry = downloads.initialize();
      expect(downloads.initialize(), same(retry));
      await retry;
      expect(downloads.initialized, true);
      expect(downloads.error, isNull);
      expect(downloads.entries.single, same(entry));
      expect(storage.reads, 1);
      expect(driver.tracked, 2);
      expect(driver.started, 1);
    },
  );

  test(
    'immediate playback waits only for the local manifest and uses saved video before core initialization',
    () async {
      downloads.dispose();
      storage.gate = Completer<Map<String, dynamic>?>();
      final core = Completer<void>();
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
        waitForProvider: () => core.future,
      );
      final loading = downloads.initialize();
      var found = false;
      final file = downloads.localFile(drama, episode).then((path) {
        found = true;
        return path;
      });
      await storage.reading.future;
      expect(found, false);
      storage.gate!.complete(storage.value);
      expect(await file, '${root.path}/123/video.mp4');
      expect(downloads.initialized, false);
      expect(driver.tracked, 0);
      core.complete();
      await loading;
    },
  );

  test(
    'a rejected Wi-Fi policy does not start transfers and remains retryable',
    () async {
      driver.wifiAccepted = false;
      await downloads.initialize();
      expect(downloads.initialized, false);
      expect(downloads.initializationError, isNotNull);
      expect(driver.started, 0);
      expect(driver.submitted, isEmpty);
      driver.wifiAccepted = true;
      await downloads.initialize();
      expect(downloads.initialized, true);
      expect(driver.started, 1);
      expect(storage.reads, 1);
    },
  );

  test(
    'a failure after subscribing can retry the same downloader update stream',
    () async {
      driver.failRecords = true;
      await downloads.initialize();
      expect(downloads.initializationError, isNotNull);
      expect(driver.started, 1);
      driver.failRecords = false;
      await downloads.initialize();
      expect(downloads.initialized, true);
      expect(downloads.initializationError, isNull);
      expect(storage.reads, 1);
      expect(await downloads.localFile(drama, episode), isNotNull);
    },
  );

  test(
    'a damaged manifest never starts cleanup or deletes saved files',
    () async {
      storage.value = {
        'jobs': ['invalid'],
      };
      await downloads.initialize();
      expect(downloads.manifestLoaded, false);
      expect(downloads.initializationError, isNotNull);
      expect(driver.tracked, 0);
      expect(driver.canceled, isEmpty);
      expect(
        await File('${root.path}/123/video.mp4').readAsString(),
        'saved video',
      );
      storage.value = {'version': 1, 'jobs': []};
      await downloads.initialize();
      expect(storage.reads, 2);
      expect(downloads.initialized, true);
    },
  );

  test(
    'disposal during manifest read stops native setup and notifications',
    () async {
      storage.gate = Completer<Map<String, dynamic>?>();
      var notifications = 0;
      downloads.addListener(() => notifications++);
      final loading = downloads.initialize();
      await storage.reading.future;
      downloads.dispose();
      final before = notifications;
      storage.gate!.complete(storage.value);
      await loading;
      expect(driver.tracked, 0);
      expect(downloads.entries, isEmpty);
      expect(notifications, before);
      // The fixture owns a fresh store so teardown disposes only once.
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
      );
    },
  );

  test(
    'disposal during native setup prevents later setup and restoration',
    () async {
      driver.trackGate = Completer<void>();
      final loading = downloads.initialize();
      await driver.tracking.future;
      downloads.dispose();
      driver.trackGate!.complete();
      await loading;
      expect([driver.rules, driver.started], [0, 0]);
      expect(driver.submitted, isEmpty);
      expect(await File('${root.path}/123/video.mp4').exists(), true);
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
      );
    },
  );

  test(
    'core failure leaves signed pending tasks recoverable on the next initialization',
    () async {
      downloads.dispose();
      final tasks = [
        for (var i = 1; i <= 2; i++)
          DownloadTask(
            taskId: '456_$i',
            url: 'https://example.com/$i?Signature=old',
            filename: '$i.bin',
            group: DownloadStore.group,
            metaData: '456',
          ),
      ];
      final folder = await Directory('${root.path}/456').create();
      await File('${folder.path}/local.m3u8').writeAsString('fixture playlist');
      planProvider.signed = true;
      final pending = DownloadEntry(
        id: '456',
        drama: drama,
        episode: Episode.fromJson({'id': 'next'}, 1),
        index: 1,
        directory: '/old/container/456',
        input: 'local.m3u8',
        contentKey: '',
        process: true,
        tasks: tasks,
        refreshOnResume: true,
      );
      (storage.value!['jobs'] as List).add(pending.toJson());
      var coreReady = false;
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
        waitForProvider: () async {
          if (!coreReady) throw const ProviderException('站源连接失败');
        },
      );
      await downloads.initialize();
      final savedPending = downloads.entries.last;
      expect(savedPending.failure, isNull);
      expect(driver.submitted, isEmpty);
      expect(driver.tracked, 0);
      coreReady = true;
      await downloads.initialize();
      expect(savedPending.failure, isNull);
      expect(driver.submitted.map((t) => t.taskId), ['456_1', '456_2']);
      expect(downloads.initialized, true);
    },
  );

  test(
    'disposal while refreshing a restored URL cannot cancel or enqueue transfers',
    () async {
      downloads.dispose();
      app.dispose();
      final provider = DelayedPlanProvider()..signed = true;
      app = AppStore(storage: MemoryStorage(), provider: provider);
      final folder = await Directory('${root.path}/456').create();
      await File('${folder.path}/local.m3u8').writeAsString('fixture playlist');
      final pending = DownloadEntry(
        id: '456',
        drama: drama,
        episode: Episode.fromJson({'id': 'next'}, 1),
        index: 1,
        directory: '/old/456',
        input: 'local.m3u8',
        contentKey: '',
        process: true,
        refreshOnResume: true,
        tasks: [
          for (var i = 1; i <= 2; i++)
            DownloadTask(
              taskId: '456_$i',
              url: 'https://example.com/$i?Signature=old',
              filename: '$i.bin',
              group: DownloadStore.group,
              metaData: '456',
            ),
        ],
      );
      (storage.value!['jobs'] as List).add(pending.toJson());
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
      );
      final loading = downloads.initialize();
      await provider.requested.future;
      final oldTasks = downloads.entries.last.tasks.toList();
      downloads.dispose();
      provider.released.complete();
      await loading;
      expect(driver.canceled, isEmpty);
      expect(driver.submitted, isEmpty);
      expect(downloads.entries.last.tasks, oldTasks);
      expect(downloads.entries.last.failure, isNull);
      expect(
        await File('${folder.path}/local.m3u8').readAsString(),
        'fixture playlist',
      );
      downloads = DownloadStore(
        app,
        driver: driver,
        storage: storage,
        root: root,
      );
    },
  );
}
