import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';
import 'package:guoguo_mobile/ui/cast_sheet.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:guoguo_mobile/ui/player_page.dart';

import 'support/cast_fakes.dart';
import 'widget_test.dart' show NoNetwork;

class LocalDownloads extends DownloadStore {
  LocalDownloads(super.store);
  @override
  Future<String?> localFile(Drama drama, Episode episode) async =>
      '/tmp/cast-${episode.id}.mp4';
}

class RelayLease implements CastRelayHandle {
  RelayLease(this.counters);
  final FakeCastRelay counters;
  @override
  Future<String> start(
    ResolvedMedia media,
    String? localPath, {
    Uri? receiver,
  }) => counters.start(media, localPath, receiver: receiver);
  @override
  Future<void> close() => counters.close();
}

class NativeCastPlayer {
  static const channel = MethodChannel('better_player_channel');
  static const events = MethodChannel('better_player_channel/videoEvents7');
  static const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity',
  );
  static const connectivityEvents = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  int position = 10000, plays = 0, pauses = 0;
  bool detached = false;
  int releases = 0;
  final seeks = <int>[];
  final sources = <Map>[];
  void Function(Map)? beforeSource;
  Completer<void>? seekGate;
  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') return {'textureId': 7};
      if (call.method == 'setDataSource') {
        beforeSource?.call((call.arguments as Map)['dataSource'] as Map);
        detached = false;
        sources.add((call.arguments as Map)['dataSource'] as Map);
        scheduleMicrotask(
          () => emit('initialized', {
            'duration': 120000,
            'width': 320.0,
            'height': 180.0,
          }),
        );
      }
      if (call.method == 'play') plays++;
      if (call.method == 'pause') pauses++;
      if (call.method == 'seekTo') {
        final target = (call.arguments as Map)['location'] as int;
        seeks.add(target);
        await seekGate?.future;
        position = target;
      }
      if (call.method == 'position') return position;
      if (call.method == 'isPictureInPictureSupported') return true;
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
  }

  void emit(String event, [Map<String, Object?> values = const {}]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': event,
            ...values,
          }),
          (_) {},
        );
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [channel, events, connectivity, connectivityEvents]) {
      messenger.setMockMethodCallHandler(name, null);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  NativeCastPlayer? airPlayNative;
  Future<
    (
      NativeCastPlayer,
      FakeCastReceiver,
      FakeCastRelay,
      AppStore,
      LocalDownloads,
    )
  >
  mount(
    WidgetTester tester, {
    MethodChannel? airPlayChannel,
    bool autoAdvance = true,
    int initialIndex = 0,
    void Function(NativeCastPlayer)? configureNative,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    configureNative?.call(native);
    airPlayNative = native;
    final receiver = FakeCastReceiver(), relay = FakeCastRelay();
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..prefetch = false
      ..autoAdvance = autoAdvance;
    final downloads = LocalDownloads(store);
    addTearDown(() {
      native.uninstall();
      downloads.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          store: store,
          downloads: downloads,
          drama: const Drama(
            id: 'fixture',
            source: DramaSource.hongguo,
            title: '投屏作品',
          ),
          episodes: [
            Episode.fromJson({'id': 'one'}, 0),
            Episode.fromJson({'id': 'two'}, 1),
          ],
          initialIndex: initialIndex,
          episodeIndices: const [5, 9],
          castRelayFactory: () => RelayLease(relay),
          castDiscoveryFactory: () => FakeCastDiscovery(receiver),
          airPlayChannel: airPlayChannel,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    return (native, receiver, relay, store, downloads);
  }

  Future<void> connect(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多播放设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投屏到电视'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅电视'));
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  const airPlayChannel = MethodChannel('guoguo/airplay');
  final airPlayCalls = <String>[];
  bool external = false;
  bool videoExternal = true;
  void installAirPlay({bool selected = false}) {
    airPlayCalls.clear();
    external = selected;
    videoExternal = true;
    airPlayNative = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(airPlayChannel, (call) async {
      airPlayCalls.add(call.method);
      if (call.method == 'prepareAirPlay' || call.method == 'getAirPlayState') {
        final native = airPlayNative;
        return {
          'active': external && videoExternal && native?.detached == false,
          'routed': external,
          'sourceUrl': native?.detached == false && native!.sources.isNotEmpty
              ? native.sources.last['uri']
              : null,
          'sourceRevision': native?.sources.length ?? 0,
        };
      }
      if (call.method == 'releaseAirPlay') {
        airPlayNative?.detached = true;
        airPlayNative?.releases++;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(airPlayChannel, null));
  }

  Future<void> emitAirPlay(bool active) async {
    external = active;
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          airPlayChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('externalPlaybackChanged', {
              'textureId': 7,
              'active': active,
              'routed': active,
              'sourceUrl': airPlayNative?.sources.last['uri'],
              'sourceRevision': airPlayNative?.sources.length,
            }),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  for (final paused in [false, true]) {
    testWidgets(
      'AirPlay replaces local media with reachable URL and preserves paused=$paused',
      (tester) async {
        installAirPlay();
        final (native, _, relay, _, _) = await mount(
          tester,
          airPlayChannel: airPlayChannel,
        );
        if (paused) {
          await tester.tap(find.byTooltip('暂停'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('AirPlay'));
        await tester.pumpAndSettle();
        expect(
          native.sources.last['uri'],
          'http://192.168.1.2:8080/token/0.mp4',
        );
        expect(native.seeks.last, 10000);
        expect(airPlayCalls, [
          'getAirPlayState',
          'prepareAirPlay',
          'showAirPlayRoutes',
        ]);
        final player = tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller;
        expect(player.isPlaying(), !paused);
        await emitAirPlay(true);
        await tester.pumpAndSettle();
        expect(find.byTooltip('AirPlay · 已连接'), findsOneWidget);
        final before = native.pauses;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(const Duration(seconds: 1));
        expect(native.pauses, before);
        await emitAirPlay(false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        if (find.byTooltip('AirPlay').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(const Offset(400, 300));
          await tester.pumpAndSettle();
        }
        // Returning to iPhone reinstalls the original local source at the
        // current position. Reopening can prepare a new relay for that source.
        expect(native.sources.last['uri'], 'file:///tmp/cast-one.mp4');
        final seeks = native.seeks.length;
        await tester.tap(find.byTooltip('AirPlay'));
        await tester.pumpAndSettle();
        expect(native.seeks.length, seeks + 1);
        expect(relay.starts, 2);
        expect(relay.closes, 1);
        await unmount(tester);
        expect(relay.closes, 2);
      },
    );
  }

  testWidgets(
    'AirPlay completion advances in background without a PageView animation',
    (tester) async {
      installAirPlay();
      final (native, _, relay, store, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      await tester.tap(find.byTooltip('AirPlay'));
      await tester.pumpAndSettle();
      await emitAirPlay(true);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      native.position = 120000;
      native.emit('completed');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(native.sources.length, 3);
      expect(native.sources.last['author'], '果果 · 第 2 集');
      expect(
        native.sources.last['uri'],
        startsWith('http://192.168.1.2:8080/'),
      );
      expect(relay.starts, 2);
      expect(store.history.values.single.episodeIndex, 5);
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        true,
      );
      expect(
        airPlayCalls.where((call) => call == 'showAirPlayRoutes').length,
        1,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).controller.page,
        1,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'reentering with selected TV routes the first asset as video instead of playing local picture with TV audio',
    (tester) async {
      installAirPlay(selected: true);
      final (native, _, relay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      expect(native.sources, hasLength(1));
      expect(
        native.sources.single['uri'],
        startsWith('http://192.168.1.2:8080/'),
      );
      expect(relay.starts, 1);
      expect(airPlayCalls, ['getAirPlayState', 'prepareAirPlay']);
      expect(find.text('正在电视上播放'), findsOneWidget);
      expect(find.textContaining('恢复'), findsNothing);
      await unmount(tester);
      expect(native.detached, true);
      expect(native.releases, 1);
      expect(relay.closes, 1);
      // The selected system route survives exit; new entry must adopt it again.
      final (reopened, _, reopenedRelay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      expect(
        reopened.sources.single['uri'],
        startsWith('http://192.168.1.2:8080/'),
      );
      expect(reopenedRelay.starts, 1);
      await unmount(tester);
    },
  );

  testWidgets(
    'selecting TV during first native installation prepares video once instead of entering phone recovery',
    (tester) async {
      installAirPlay();
      var rejected = false;
      final (native, _, relay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
        configureNative: (native) => native.beforeSource = (source) {
          if (!rejected && (source['uri'] as String).startsWith('file:')) {
            rejected = true;
            external = true;
            throw PlatformException(code: 'airplay_source');
          }
        },
      );
      expect(rejected, true);
      expect(native.sources, hasLength(1));
      expect(
        native.sources.single['uri'],
        startsWith('http://192.168.1.2:8080/'),
      );
      expect(relay.starts, 1);
      expect(find.textContaining('恢复'), findsNothing);
      expect(find.byTooltip('AirPlay · 已连接'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'switching to iPhone during episode installation restores the new episode locally',
    (tester) async {
      installAirPlay(selected: true);
      final (native, _, relay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      native.beforeSource = (_) {
        external = false;
        native.beforeSource = null;
      };
      tester
          .widget<EpisodePager>(find.byType(EpisodePager))
          .controller
          .jumpToPage(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(native.sources.last['uri'], 'file:///tmp/cast-two.mp4');
      expect(native.sources.last['author'], '果果 · 第 2 集');
      expect(relay.starts, 2);
      expect(relay.closes, 2);
      expect(find.byTooltip('AirPlay'), findsOneWidget);
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        true,
      );
      expect(find.textContaining('恢复'), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'audio-only route shows waiting and fails explicitly without phone video or generic recovery',
    (tester) async {
      installAirPlay(selected: true);
      videoExternal = false;
      final (native, _, relay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      expect(find.byTooltip('AirPlay · 等待视频连接'), findsOneWidget);
      expect(find.text('等待电视接通 AirPlay 视频…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(find.textContaining('电视未接通 AirPlay 视频'), findsOneWidget);
      expect(native.sources, hasLength(1));
      expect(relay.starts, 1);
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        false,
      );
      expect(find.textContaining('自动恢复'), findsNothing);
      await unmount(tester);
    },
  );

  for (final lastEpisode in [false, true]) {
    testWidgets(
      'AirPlay completion stays on current episode when advance disabled or last=$lastEpisode',
      (tester) async {
        installAirPlay();
        final (native, _, relay, _, _) = await mount(
          tester,
          airPlayChannel: airPlayChannel,
          autoAdvance: lastEpisode,
          initialIndex: lastEpisode ? 1 : 0,
        );
        await tester.tap(find.byTooltip('AirPlay'));
        await tester.pumpAndSettle();
        await emitAirPlay(true);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        native.position = 120000;
        native.emit('completed');
        await tester.pumpAndSettle();
        expect(native.sources.length, 2);
        expect(relay.starts, 1);
        expect(
          tester
              .widget<BetterPlayer>(find.byType(BetterPlayer))
              .controller
              .isPlaying(),
          false,
        );
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'AirPlay episode change retains reachable media and existing route',
    (tester) async {
      installAirPlay();
      final (native, _, relay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      await tester.tap(find.byTooltip('AirPlay'));
      await tester.pumpAndSettle();
      await emitAirPlay(true);
      await tester.pumpAndSettle();
      final pager = tester.widget<EpisodePager>(find.byType(EpisodePager));
      videoExternal = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      pager.controller.jumpToPage(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        native.sources.length,
        3,
        reason:
            'relay starts=${relay.starts}, native calls=$airPlayCalls, texts=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(', ')}',
      );
      expect(
        native.sources.last['uri'],
        startsWith('http://192.168.1.2:8080/'),
      );
      expect(
        native.sources.any(
          (source) => source['uri'] == 'file:///tmp/cast-two.mp4',
        ),
        false,
      );
      expect(
        airPlayCalls.where((call) => call == 'showAirPlayRoutes').length,
        1,
      );
      expect(relay.starts, 2);
      expect(relay.closes, 1);
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        true,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'dismissing and reopening cast controls preserves session, relay and phone pause',
    (tester) async {
      final (native, receiver, relay, _, _) = await mount(tester);
      final pager = tester.widget<EpisodePager>(find.byType(EpisodePager));
      await connect(tester);
      expect(receiver.loadedSource!.position, const Duration(seconds: 10));
      expect(receiver.loadedSource!.playing, true);
      final player = tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller;
      expect(player.isPlaying(), false);
      await tester.tap(find.byKey(const Key('closeCastControls')));
      await tester.pumpAndSettle();
      expect(find.byType(CastSheet), findsNothing);
      expect(relay.closes, 0);
      expect(receiver.calls, isNot(contains('stop')));
      expect(find.byType(PlayerTransport), findsNothing);
      expect(find.bySemanticsLabel('打开投屏控制'), findsOneWidget);
      expect(pager.controller.positions, hasLength(1));
      await tester.dragFrom(const Offset(50, 300), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(pager.controller.page, 0);
      expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('更多播放设置'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '画中画')).enabled,
        false,
      );
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).locked,
        true,
      );
      native.emit('play');
      native.emit('finished');
      await tester.pump(const Duration(seconds: 1));
      expect(player.isPlaying(), false);
      await tester.tap(find.byKey(const Key('reopenCastControls')));
      await tester.pumpAndSettle();
      expect(find.text('投屏到 客厅电视'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '暂停'));
      await tester.pumpAndSettle();
      expect(receiver.calls.last, 'status');
      expect(receiver.calls, contains('pause'));
      expect(find.text('已暂停'), findsOneWidget);
      expect(player.isPlaying(), false);
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pumpAndSettle();
      expect(receiver.calls, contains('play'));
      expect(find.text('正在播放'), findsOneWidget);
      expect(player.isPlaying(), false);
      expect(relay.starts, 1);
      expect(receiver.calls.where((call) => call == 'load'), hasLength(1));
      await unmount(tester);
      expect(relay.closes, 1);
      expect(receiver.calls.where((call) => call == 'stop'), hasLength(1));
      expect(receiver.closes, 1);
    },
  );
  testWidgets(
    'ending paused TV playback seeks to its final actual position and saves original episode index',
    (tester) async {
      final (native, receiver, _, store, _) = await mount(tester);
      await connect(tester);
      receiver.playback = const CastPlayback(
        position: Duration(seconds: 57),
        duration: Duration(seconds: 120),
        state: CastPlaybackState.paused,
      );
      await tester.tap(find.byKey(const Key('stopCasting')));
      await tester.pumpAndSettle();
      final player = tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller;
      expect(native.seeks.last, 57000);
      expect(player.isPlaying(), false);
      final record = store.history['hongguo:fixture']!;
      expect(record.positionMs, 57000);
      expect(record.episodeId, 'one');
      expect(record.episodeIndex, 5);
      expect(find.byType(CastSheet), findsNothing);
      expect(
        tester.widget<PlayerTransport>(find.byType(PlayerTransport)).enabled,
        true,
      );
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).locked,
        false,
      );
      expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
      await unmount(tester);
      expect(store.history['hongguo:fixture']!.positionMs, 57000);
    },
  );
  testWidgets(
    'playing TV returns playback intent to phone and background transfer defers play',
    (tester) async {
      final (native, receiver, _, _, _) = await mount(tester);
      await connect(tester);
      receiver.playback = const CastPlayback(
        position: Duration(seconds: 35),
        state: CastPlaybackState.playing,
      );
      native.seekGate = Completer();
      final before = native.plays;
      await tester.tap(find.byKey(const Key('stopCasting')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      native.seekGate!.complete();
      await tester.pumpAndSettle();
      expect(native.plays, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(native.plays, before + 1);
      expect(native.seeks.last, 35000);
      expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
      await unmount(tester);
    },
  );
  testWidgets(
    'failed TV stop preserves casting and does not restart the phone',
    (tester) async {
      final (native, receiver, relay, _, _) = await mount(tester);
      await connect(tester);
      receiver.failStop = true;
      final before = native.plays;
      await tester.tap(find.byKey(const Key('stopCasting')));
      await tester.pumpAndSettle();
      expect(find.textContaining('电视未确认结束'), findsOneWidget);
      expect(relay.closes, 0);
      expect(native.plays, before);
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        false,
      );
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).locked,
        true,
      );
      expect(find.byType(PlayerTransport), findsNothing);
      receiver.failStop = false;
      await tester.tap(find.byKey(const Key('stopCasting')));
      await tester.pumpAndSettle();
      expect(relay.closes, 1);
      await unmount(tester);
    },
  );
  testWidgets(
    'large text cast panel can scroll to stop and close without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final receiver = FakeCastReceiver(), relay = FakeCastRelay();
      final session = CastSessionController(
        captureSource: castSource,
        pauseLocal: () async {},
        returnLocal: (_) async {},
        relayFactory: () => relay,
      );
      addTearDown(session.dispose);
      await session.start(receiver.target);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCastSheet(
                  context,
                  session,
                  discoveryFactory: () => FakeCastDiscovery(receiver),
                ),
                child: const Text('投屏'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('投屏'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('stopCasting')));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('closeCastControls')));
      await tester.tap(find.byKey(const Key('closeCastControls')));
      await tester.pumpAndSettle();
      expect(session.phase, CastPhase.connected);
      session.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
