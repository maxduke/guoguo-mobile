import 'dart:async';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/cast_entry_sheet.dart';
import 'package:guoguo_mobile/ui/cast_sheet.dart';
import 'package:guoguo_mobile/platform/cast_receivers.dart';
import 'package:guoguo_mobile/platform/media_preparer.dart';
import 'package:guoguo_mobile/ui/player_sheets.dart';

import 'player_cast_handoff_test.dart'
    show NativeCastPlayer, LocalDownloads, AirPlayFixturePreparer;
import 'widget_test.dart' show NoNetwork;
import 'support/cast_fakes.dart';
import 'player_pip_advance_test.dart' show PlaylistOverrides;

class _Provider extends NoNetwork {
  final resolved = <(String, int)>[];
  Completer<void>? gate;
  List<int> firstQualities = [720, 1080];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method != 'resolve') return {};
    final id = (arguments['chapter'] as Map)['id'] as String;
    final quality = arguments['quality'] as int;
    resolved.add((id, quality));
    await gate?.future;
    final qualities = id == 'one' ? firstQualities : [360, 480];
    return {
      'url': 'https://fixture.test/$id.mp4',
      'remoteUrl': 'https://fixture.test/$id.mp4',
      'qualities': qualities,
      'quality': quality == 0 ? qualities.last : quality,
    };
  }
}

class _Downloads extends LocalDownloads {
  _Downloads(super.store);
  final added = <(String, int)>[];
  @override
  Future<void> enqueue(Drama drama, Episode episode, int index) async =>
      added.add((episode.id, index));
}

class _CastPreparation extends MediaPreparer {
  bool progressive = false;
  int cancellations = 0;
  Completer<void>? cancelGate;
  @override
  bool get streaming => progressive;
  @override
  bool get complete => !progressive;
  @override
  Future<String> prepare(
    ResolvedMedia media, {
    bool progressive = false,
  }) async {
    this.progressive = progressive;
    return progressive
        ? 'http://127.0.0.1:43210/fixture/index.m3u8'
        : 'https://fixture.test/complete.mp4';
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    await cancelGate?.future;
  }

  @override
  Future<void> dispose() => cancel();
}

void main() {
  Future<(NativeCastPlayer, _Provider, AppStore, _Downloads)> mount(
    WidgetTester tester, {
    MethodChannel? airPlayChannel,
    bool casting = false,
    bool openSheet = true,
    CastDiscovery Function()? discoveryFactory,
    MediaPreparer Function()? preparerFactory,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider)
      ..preferences.prefetch = false
      ..preferences.autoAdvance = true
      ..preferences.progressivePreparation = preparerFactory != null;
    final downloads = _Downloads(store)..available = false;
    addTearDown(() {
      native.uninstall();
      downloads.dispose();
      store.dispose();
    });
    var preparers = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          store: store,
          downloads: downloads,
          drama: const Drama(
            id: 'fixture',
            source: DramaSource.hongguo,
            title: '菜单换集边界',
          ),
          episodes: [
            Episode.fromJson({'id': 'one'}, 0),
            Episode.fromJson({'id': 'two'}, 1),
          ],
          initialIndex: 0,
          airPlayChannel: airPlayChannel,
          castDiscoveryFactory: discoveryFactory,
          preparerFactory:
              preparerFactory ?? () => AirPlayFixturePreparer(preparers++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(const Offset(700, 150));
    await tester.pumpAndSettle();
    if (openSheet) {
      await tester.tap(find.byTooltip(casting ? '投屏' : '更多播放设置'));
      await tester.pumpAndSettle();
    }
    return (native, provider, store, downloads);
  }

  PlayerMoreSheet menu(WidgetTester tester) =>
      tester.widget<PlayerMoreSheet>(find.byType(PlayerMoreSheet));

  CastEntrySheet castEntry(WidgetTester tester) =>
      tester.widget<CastEntrySheet>(find.byType(CastEntrySheet));

  void finish(WidgetTester tester) => tester
      .widget<BetterPlayer>(find.byType(BetterPlayer))
      .controller
      .postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));

  testWidgets(
    'an open menu follows automatic advance and ignores old callbacks',
    (tester) async {
      final (native, provider, store, downloads) = await mount(tester);
      final old = menu(tester);
      expect(old.qualities, [720, 1080]);
      finish(tester);
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0), ('two', 0)]);
      expect(native.sources, hasLength(2));
      expect(menu(tester).qualities, [360, 480]);
      expect(menu(tester).quality, 480);
      old.onQuality(1080);
      old.onAction(PlayerMenuAction.download);
      old.onAutoAdvance(false);
      await tester.pumpAndSettle();
      expect(provider.resolved, hasLength(2));
      expect(downloads.added, isEmpty);
      expect(store.preferences.autoAdvance, true);
      expect(find.byType(PlayerMoreSheet), findsOneWidget);

      final select = menu(tester).onQuality;
      select(360);
      select(360);
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0), ('two', 0), ('two', 360)]);
      expect(find.byType(PlayerMoreSheet), findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending next media disables media actions and keeps its download target',
    (tester) async {
      final (_, provider, _, downloads) = await mount(tester);
      final gate = provider.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final old = menu(tester);
      finish(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.resolved, [('one', 0), ('two', 0)]);
      expect(menu(tester).qualities, isEmpty);
      expect(menu(tester).pipEnabled, false);
      old.onAction(PlayerMenuAction.download);
      expect(downloads.added, isEmpty);
      menu(tester).onAction(PlayerMenuAction.download);
      await tester.pump();
      expect(downloads.added, [('two', 1)]);
      gate.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same episode recovery refreshes choices and rejects the old generation',
    (tester) async {
      final (_, provider, _, downloads) = await mount(tester);
      final old = menu(tester);
      provider.firstQualities = [540, 720];
      tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller
          .postEvent(BetterPlayerEvent(BetterPlayerEventType.exception));
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0), ('one', 0)]);
      expect(menu(tester).qualities, [540, 720]);
      expect(menu(tester).quality, 720);
      old.onQuality(1080);
      old.onAction(PlayerMenuAction.download);
      await tester.pumpAndSettle();
      expect(provider.resolved, hasLength(2));
      expect(downloads.added, isEmpty);
      expect(find.byType(PlayerMoreSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'PiP changes update cast availability and reject an earlier enabled action',
    (tester) async {
      final (native, _, _, _) = await mount(tester, casting: true);
      final old = castEntry(tester);
      expect(old.televisionEnabled, true);
      native.emit('pipStart');
      await tester.pumpAndSettle();
      expect(castEntry(tester).televisionEnabled, false);
      expect(find.text('画中画播放时暂不能投屏'), findsOneWidget);
      old.onAction(CastEntryAction.television);
      await tester.pumpAndSettle();
      expect(find.byType(CastEntrySheet), findsOneWidget);
      native.emit('pipStop');
      await tester.pumpAndSettle();
      expect(castEntry(tester).televisionEnabled, true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'opening and dismissing casting leaves playback and media alone',
    (tester) async {
      final discoveries = <FakeCastDiscovery>[];
      final (native, provider, _, downloads) = await mount(
        tester,
        openSheet: false,
        discoveryFactory: () {
          final discovery = FakeCastDiscovery(FakeCastReceiver());
          discoveries.add(discovery);
          return discovery;
        },
      );
      final plays = native.plays, pauses = native.pauses;
      final lookups = downloads.lookups;
      await tester.tap(find.byTooltip('投屏'));
      await tester.pumpAndSettle();
      expect(castEntry(tester).airplay, isNull);
      expect(find.text('电视设备'), findsOneWidget);
      expect(find.text('AirPlay'), findsNothing);
      expect(discoveries, isEmpty);
      expect(provider.resolved, [('one', 0)]);
      expect(native.sources, hasLength(1));
      expect(native.plays, plays);
      expect(native.pauses, pauses);
      expect(downloads.lookups, lookups);
      final old = castEntry(tester);
      Navigator.of(tester.element(find.byType(CastEntrySheet))).pop();
      await tester.pumpAndSettle();
      old.onAction(CastEntryAction.television);
      await tester.pumpAndSettle();
      expect(find.byType(CastSheet), findsNothing);
      expect(discoveries, isEmpty);
      expect(native.pauses, pauses);
      await tester.tap(find.byTooltip('投屏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('电视设备'));
      await tester.pumpAndSettle();
      expect(find.byType(CastEntrySheet), findsNothing);
      expect(find.byType(CastSheet), findsOneWidget);
      expect(discoveries.single.searches, 1);
      expect(provider.resolved, [('one', 0)]);
      expect(downloads.lookups, lookups);
      await tester.pumpWidget(const SizedBox());
      old.onAction(CastEntryAction.television);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an old casting entry cannot open over another route or after disposal',
    (tester) async {
      await mount(tester, openSheet: false);
      final open = tester
          .widget<IconButton>(find.byKey(const Key('playerCastingButton')))
          .onPressed!;
      final navigator = Navigator.of(tester.element(find.byType(PlayerPage)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一页面'))),
        ),
      );
      await tester.pumpAndSettle();
      open();
      await tester.pumpAndSettle();
      expect(find.text('另一页面'), findsOneWidget);
      expect(find.byType(CastEntrySheet), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      open();
      open();
      await tester.pumpAndSettle();
      expect(find.byType(CastEntrySheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      open();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'casting follows a pending next episode and rejects its old owner',
    (tester) async {
      final discovery = FakeCastDiscovery(FakeCastReceiver());
      final (_, provider, _, _) = await mount(
        tester,
        casting: true,
        discoveryFactory: () => discovery,
      );
      final old = castEntry(tester);
      final gate = provider.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      finish(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.resolved, [('one', 0), ('two', 0)]);
      expect(castEntry(tester).televisionEnabled, false);
      old.onAction(CastEntryAction.television);
      castEntry(tester).onAction(CastEntryAction.television);
      await tester.pump();
      expect(discovery.searches, 0);
      expect(find.byType(CastEntrySheet), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(castEntry(tester).televisionEnabled, true);
      old.onAction(CastEntryAction.television);
      await tester.pumpAndSettle();
      expect(find.byType(CastEntrySheet), findsOneWidget);
      castEntry(tester).onAction(CastEntryAction.television);
      await tester.pumpAndSettle();
      expect(find.byType(CastEntrySheet), findsNothing);
      expect(discovery.searches, 1);
      expect(provider.resolved, [('one', 0), ('two', 0)]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final background in [false, true]) {
    testWidgets(
      'TV selection prepares compatible media before discovery, background=$background',
      (tester) async {
        final originalOverrides = HttpOverrides.current;
        HttpOverrides.global = PlaylistOverrides();
        addTearDown(() => HttpOverrides.global = originalOverrides);
        final gate = Completer<void>();
        final first = _CastPreparation()..cancelGate = gate;
        final jobs = <_CastPreparation>[];
        final discovery = FakeCastDiscovery(FakeCastReceiver());
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final (native, provider, _, _) = await mount(
          tester,
          casting: true,
          discoveryFactory: () => discovery,
          preparerFactory: () {
            final job = jobs.isEmpty ? first : _CastPreparation();
            jobs.add(job);
            return job;
          },
        );
        expect(first.progressive, true);
        expect(jobs, hasLength(1));
        expect(first.cancellations, 0);
        expect(discovery.searches, 0);
        castEntry(tester).onAction(CastEntryAction.television);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(CastEntrySheet), findsNothing);
        expect(first.cancellations, greaterThan(0));
        expect(jobs, hasLength(1));
        expect(discovery.searches, 0);
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
        }
        gate.complete();
        await tester.pumpAndSettle();
        expect(jobs, hasLength(2));
        expect(jobs.last.progressive, false);
        expect(provider.resolved, [('one', 0), ('one', 0)]);
        expect(native.sources.last['uri'], 'https://fixture.test/complete.mp4');
        expect(discovery.searches, background ? 0 : 1);
        expect(
          find.byType(CastSheet),
          background ? findsNothing : findsOneWidget,
        );
        if (background) {
          expect(
            tester
                .widget<BetterPlayer>(find.byType(BetterPlayer))
                .controller
                .isPlaying(),
            false,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('casting rejects a replaced generation on the same episode', (
    tester,
  ) async {
    final (_, provider, _, _) = await mount(tester, casting: true);
    final old = castEntry(tester);
    tester
        .widget<BetterPlayer>(find.byType(BetterPlayer))
        .controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.exception));
    await tester.pumpAndSettle();
    expect(provider.resolved, [('one', 0), ('one', 0)]);
    expect(castEntry(tester).televisionEnabled, true);
    old.onAction(CastEntryAction.television);
    await tester.pumpAndSettle();
    expect(find.byType(CastEntrySheet), findsOneWidget);
    expect(find.byType(CastSheet), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background casting actions cannot discover devices or pop a route',
    (tester) async {
      final discovery = FakeCastDiscovery(FakeCastReceiver());
      await mount(tester, casting: true, discoveryFactory: () => discovery);
      final old = castEntry(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      // Inactive frames are not rendered; check the action itself.
      old.onAction(CastEntryAction.television);
      await tester.pumpAndSettle();
      expect(discovery.searches, 0);
      expect(find.byType(CastEntrySheet), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(castEntry(tester).televisionEnabled, true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a changed AirPlay route updates casting and rejects stale TV selection',
    (tester) async {
      const channel = MethodChannel('guoguo/cast-entry-route');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var external = false;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'getState' ? {'routed': external} : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final (_, provider, _, _) = await mount(
        tester,
        casting: true,
        airPlayChannel: channel,
      );
      final old = castEntry(tester);
      expect(old.airPlayEnabled, true);
      Future<void> route(bool routed) async {
        external = routed;
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('state', {'sessionId': '', 'routed': routed}),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await tester.pumpAndSettle();
      }

      await route(true);
      expect(castEntry(tester).televisionEnabled, false);
      expect(castEntry(tester).routesEnabled, true);
      old.onAction(CastEntryAction.television);
      await tester.pumpAndSettle();
      expect(find.byType(CastEntrySheet), findsOneWidget);
      expect(calls, isNot(contains('open')));
      final routed = castEntry(tester);
      await route(false);
      expect(castEntry(tester).televisionEnabled, true);
      expect(castEntry(tester).routesEnabled, false);
      routed.onAction(CastEntryAction.routes);
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('showRoutes')));
      expect(provider.resolved, [('one', 0)]);
      expect(find.byType(CastEntrySheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dismissed callbacks cannot enqueue or pop the player twice', (
    tester,
  ) async {
    final (_, _, store, downloads) = await mount(tester);
    final old = menu(tester);
    old.onAction(PlayerMenuAction.download);
    old.onAction(PlayerMenuAction.download);
    await tester.pumpAndSettle();
    expect(downloads.added, [('one', 0)]);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(PlayerMoreSheet), findsNothing);
    old.onAutoAdvance(false);
    expect(store.preferences.autoAdvance, true);
    await tester.pumpWidget(const SizedBox());
    old.onAction(PlayerMenuAction.download);
    old.onQuality(720);
    expect(downloads.added, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AirPlay routing removes local media choices until the phone is available',
    (tester) async {
      const channel = MethodChannel('guoguo/menu-state-airplay');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var external = false;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getState' ? {'routed': external} : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final (_, provider, _, _) = await mount(tester, airPlayChannel: channel);
      final old = menu(tester);
      Future<void> route(bool routed) async {
        external = routed;
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('state', {'sessionId': '', 'routed': routed}),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await tester.pumpAndSettle();
      }

      await route(true);
      expect(menu(tester).qualities, isEmpty);
      expect(menu(tester).pipEnabled, false);
      old.onQuality(720);
      old.onAction(PlayerMenuAction.pip);
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0)]);
      expect(find.byType(PlayerMoreSheet), findsOneWidget);
      await route(false);
      expect(menu(tester).qualities, [720, 1080]);
      expect(menu(tester).pipEnabled, true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving with a pending menu refresh ignores late results and callbacks',
    (tester) async {
      final (_, provider, _, downloads) = await mount(tester);
      final old = menu(tester);
      final gate = provider.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      finish(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.resolved, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      old.onAction(PlayerMenuAction.download);
      old.onQuality(720);
      await tester.pumpAndSettle();
      expect(downloads.added, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
