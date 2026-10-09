import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_startup.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

const drama = Drama(id: 'saved', source: DramaSource.hongguo, title: '已保存的故事');

class StartupProvider implements ProviderClient {
  final methods = <String>[];
  Completer<Map<String, dynamic>>? catalogGate;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    methods.add(method);
    if (method == 'recommendations') {
      return {
        'items': [drama.toJson()],
        'nextOffset': 1,
        'hasMore': false,
      };
    }
    if (method == 'categories') return {'items': <dynamic>[]};
    if (method == 'catalog') {
      return catalogGate == null
          ? {
              'items': [drama.toJson()],
              'hasMore': false,
            }
          : catalogGate!.future;
    }
    throw StateError('unexpected request $method');
  }
}

class StartupStore extends AppStore {
  StartupStore(StartupProvider provider)
    : super(storage: MemoryStorage(), provider: provider);
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class StartupDownloads extends DownloadStore {
  StartupDownloads(super.app);
  int attempts = 0;
  bool disposed = false;
  Future<void>? _pending;
  final gate = Completer<void>();
  @override
  bool get initializing => _pending != null;
  @override
  Future<void> initialize() {
    if (disposed || initialized) return Future.value();
    if (_pending != null) return _pending!;
    attempts++;
    _pending = gate.future.then((_) {
      _pending = null;
      if (disposed) return;
      initialized = true;
      notifyListeners();
    });
    return _pending!;
  }

  @override
  Future<void> refreshUsage() async {}
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StartupProvider provider;
  late StartupStore store;
  late StartupDownloads downloads;
  late StreamController<bool> changes;

  void createFixture({WidgetTester? tester}) {
    provider = StartupProvider();
    store = StartupStore(provider);
    downloads = StartupDownloads(store);
    changes = StreamController<bool>.broadcast();
    if (tester != null) {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    }
  }

  tearDown(() async {
    if (!downloads.disposed) downloads.dispose();
    if (!store.disposed) store.dispose();
    await changes.close();
  });

  AppStartup startup({
    required Future<void> Function() core,
    Future<bool> Function()? network,
  }) => AppStartup(
    store: store,
    downloads: downloads,
    initializeCore: core,
    checkOffline: network ?? () async => false,
    offlineChanges: changes.stream,
  );

  testWidgets(
    'cached content, records and saved theme render while all optional startup work is pending',
    (tester) async {
      createFixture(tester: tester);
      tester.view.physicalSize = const Size(1024, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.catalog.catalogs[DramaSource.hongguo] = [drama];
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        [drama],
        DateTime.now(),
      );
      await store.records.toggleFavorite(drama);
      await store.preferences.setTheme(ThemeMode.dark);
      final core = Completer<void>(), network = Completer<bool>();
      final app = startup(
        core: () => core.future,
        network: () => network.future,
      );
      await tester.pumpWidget(Bootstrap(load: () async => app));
      await tester.pump();
      await tester.pump();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('已保存的故事'), findsWidgets);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(provider.methods, isEmpty);
      expect(downloads.attempts, 1);
      await tester.tap(find.text('追剧'));
      await tester.pump();
      expect(find.text('我的收藏 1'), findsOneWidget);
      network.completeError(StateError('private network detail'));
      await tester.pump();
      expect(find.text('重试网络'), findsOneWidget);
      expect(find.text('我的收藏 1'), findsOneWidget);
      expect(find.textContaining('private network detail'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      core.complete();
      downloads.gate.complete();
      await tester.pump();
      expect(provider.methods, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'core failure offers a local retry and preserves the selected home tab',
    (tester) async {
      createFixture(tester: tester);
      store.catalog.catalogs[DramaSource.hongguo] = [drama];
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        [drama],
        DateTime.now(),
      );
      await store.records.toggleFavorite(drama);
      var attempts = 0;
      final retry = Completer<void>();
      final app = startup(
        core: () async {
          if (++attempts == 1) throw StateError('secret core detail');
          await retry.future;
        },
      );
      await tester.pumpWidget(Bootstrap(load: () async => app));
      await tester.pumpAndSettle();
      expect(find.text('重试站源'), findsOneWidget);
      expect(find.textContaining('secret core detail'), findsNothing);
      await tester.tap(find.text('追剧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试站源'));
      await tester.pump();
      await tester.pump();
      expect(attempts, 2);
      expect(find.text('我的收藏 1'), findsOneWidget);
      retry.complete();
      await tester.pumpAndSettle();
      expect(app.coreReady, true);
      expect(find.text('重试站源'), findsNothing);
      expect(provider.methods, isEmpty);
      expect(downloads.attempts, 1);
      expect(find.text('我的收藏 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('local-load retry is shared and does not expose raw errors', (
    tester,
  ) async {
    createFixture(tester: tester);
    final app = startup(core: () async {});
    final loaded = Completer<AppStartup>();
    var attempts = 0;
    await tester.pumpWidget(
      Bootstrap(
        load: () async {
          if (++attempts == 1) throw const FormatException('private path');
          return loaded.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法打开，原有记录已保留'), findsOneWidget);
    expect(find.textContaining('private path'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.tap(find.text('重试'));
    expect(attempts, 2);
    loaded.complete(app);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'completed downloads arriving after the home mounts are immediately visible',
    (tester) async {
      createFixture(tester: tester);
      tester.view.physicalSize = const Size(1024, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = Completer<void>();
      final app = startup(core: () => core.future);
      await tester.pumpWidget(Bootstrap(load: () async => app));
      await tester.pump();
      await tester.pump();
      final episode = Episode.fromJson({'id': 'e'}, 0);
      downloads.entries = [
        DownloadEntry(
          id: '123',
          drama: drama,
          episode: episode,
          index: 0,
          directory: '/saved/123',
          input: 'video.mp4',
          contentKey: '',
          process: false,
          tasks: [],
          ready: true,
        ),
      ];
      downloads.manifestLoaded = true;
      downloads.notifyListeners();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(find.text('已保存的故事'), findsWidgets);
      expect(find.text('1 部剧 · 1 集可播放'), findsOneWidget);
      expect(find.text('本地播放'), findsOneWidget);
      expect(find.text('查看分集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      core.complete();
      downloads.gate.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'leaving bootstrap before local load finishes disposes resources without starting subsystems',
    (tester) async {
      createFixture(tester: tester);
      var coreCalls = 0, networkCalls = 0;
      final app = startup(
        core: () async {
          coreCalls++;
        },
        network: () async {
          networkCalls++;
          return false;
        },
      );
      final loaded = Completer<AppStartup>();
      await tester.pumpWidget(Bootstrap(load: () => loaded.future));
      await tester.pumpWidget(const SizedBox.shrink());
      loaded.complete(app);
      await tester.pump();
      expect([coreCalls, networkCalls, downloads.attempts], [0, 0, 0]);
      expect(store.disposed, true);
      expect(downloads.disposed, true);
      expect(tester.takeException(), isNull);
    },
  );

  for (final snapshotFails in [false, true]) {
    test(
      'a live connectivity change beats a stale ${snapshotFails ? 'failed' : 'successful'} startup check',
      () async {
        createFixture();
        final snapshot = Completer<bool>();
        final app = startup(core: () async {}, network: () => snapshot.future);
        addTearDown(app.dispose);
        final checking = app.retryNetwork();
        await Future<void>.delayed(Duration.zero);
        changes.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(store.offline, true);
        if (snapshotFails) {
          snapshot.completeError(StateError('old request failed'));
        } else {
          snapshot.complete(false);
        }
        await checking;
        expect(store.offline, true);
        expect(app.networkError, isNull);
      },
    );
  }

  test(
    'a failed network check retains its listener and retry does not duplicate subscriptions',
    () async {
      createFixture();
      var checks = 0, subscriptions = 0;
      changes.onListen = () => subscriptions++;
      final app = startup(
        core: () async {},
        network: () async {
          if (++checks == 1) throw StateError('network check failed');
          return true;
        },
      );
      addTearDown(app.dispose);
      await app.retryNetwork();
      expect(app.networkError, isNotNull);
      final retry = app.retryNetwork();
      expect(app.retryNetwork(), same(retry));
      await retry;
      expect([checks, subscriptions], [2, 1]);
      expect(app.networkError, isNull);
      expect(store.offline, true);
      changes.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(store.offline, false);
      changes.addError(StateError('stream failed'));
      await Future<void>.delayed(Duration.zero);
      expect(app.networkError, isNotNull);
      await app.retryNetwork();
      expect(subscriptions, 2);
      expect(app.networkError, isNull);
    },
  );

  test(
    'disposal ignores late core and network completion and cancels the listener',
    () async {
      createFixture();
      final core = Completer<void>(), snapshot = Completer<bool>();
      var cancellations = 0, notifications = 0, attempts = 0;
      changes.onCancel = () => cancellations++;
      final app = startup(
        core: () async {
          attempts++;
          await core.future;
        },
        network: () => snapshot.future,
      );
      app.addListener(() => notifications++);
      app.start();
      app.start();
      final coreTask = app.retryCore(), networkTask = app.retryNetwork();
      await Future<void>.delayed(Duration.zero);
      expect([attempts, downloads.attempts], [1, 1]);
      app.dispose();
      final before = notifications;
      core.complete();
      snapshot.complete(true);
      downloads.gate.complete();
      await Future.wait([coreTask, networkTask]);
      expect(notifications, before);
      expect(store.offline, false);
      expect(provider.methods, isEmpty);
      expect(cancellations, 1);
    },
  );

  test('startup readies the core without preloading content', () async {
    createFixture();
    final app = startup(core: () async {});
    app.start();
    await app.retryCore();
    await Future<void>.delayed(Duration.zero);
    expect(app.coreReady, isTrue);
    expect(provider.methods, isEmpty);
    expect(store.catalog.catalogs, isEmpty);
    expect((store.storage as MemoryStorage).value, isNull);
    app.dispose();
  });

  test(
    'disposal in the same turn as start cannot install listeners or initialize the core',
    () async {
      createFixture();
      var coreCalls = 0, networkCalls = 0, subscriptions = 0;
      changes.onListen = () => subscriptions++;
      final app = startup(
        core: () async {
          coreCalls++;
        },
        network: () async {
          networkCalls++;
          return true;
        },
      );
      app.start();
      final core = app.retryCore(), network = app.retryNetwork();
      app.dispose();
      downloads.gate.complete();
      await Future.wait([core, network]);
      expect([coreCalls, networkCalls, subscriptions], [0, 0, 0]);
      expect(provider.methods, isEmpty);
    },
  );
}
