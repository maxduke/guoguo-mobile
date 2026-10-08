import 'package:guoguo_mobile/ui/player_transport.dart';
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
import 'package:guoguo_mobile/platform/media_preparer.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/cast_sheet.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:guoguo_mobile/ui/player_page.dart';

import 'support/cast_fakes.dart';
import 'widget_test.dart' show NoNetwork;

class LocalDownloads extends DownloadStore {
  LocalDownloads(super.store);
  bool available = true;
  int lookups = 0;
  Completer<void>? fileGate;
  @override
  Future<String?> localFile(Drama drama, Episode episode) async {
    lookups++;
    await fileGate?.future;
    return available ? '/tmp/cast-${episode.id}.mp4' : null;
  }
}

class AirPlayFixtureProvider extends NoNetwork {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => method == 'resolve'
      ? {
          'url': 'https://fixture.test/video.mp4',
          'remoteUrl': 'https://fixture.test/video.mp4',
          'contentKey': 'fixture',
        }
      : {};
}

class AirPlayFixturePreparer extends MediaPreparer {
  AirPlayFixturePreparer(this.identity);
  final int identity;
  bool disposed = false;
  @override
  Future<String> prepare(
    ResolvedMedia media, {
    bool progressive = false,
  }) async => '/tmp/owned-$identity.mp4';
  @override
  Future<void> dispose() async {
    disposed = true;
  }
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
    ProviderClient? provider,
    MediaPreparer Function()? preparerFactory,
    bool downloaded = true,
    double playbackSpeed = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    configureNative?.call(native);
    final receiver = FakeCastReceiver(), relay = FakeCastRelay();
    final store =
        AppStore(storage: MemoryStorage(), provider: provider ?? NoNetwork())
          ..preferences.prefetch = false
          ..preferences.playbackSpeed = playbackSpeed
          ..preferences.autoAdvance = autoAdvance;
    final downloads = LocalDownloads(store)..available = downloaded;
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
          preparerFactory: preparerFactory,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    // Toggle chrome away from the centered playback notice and its actions.
    await tester.tapAt(const Offset(700, 150));
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
  final airPlayCalls = <MethodCall>[];
  bool external = false;
  bool failAirPlayClose = false;
  Completer<void>? airPlayRouteGate, airPlayCloseGate;
  String? airPlayIdentity;
  int airPlaySequence = 0;
  void installAirPlay({bool selected = false}) {
    airPlayCalls.clear();
    external = selected;
    failAirPlayClose = false;
    airPlayRouteGate = airPlayCloseGate = null;
    airPlayIdentity = null;
    airPlaySequence = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(airPlayChannel, (call) async {
      airPlayCalls.add(call);
      if (call.method == 'getState') return {'routed': external};
      if (call.method == 'showRoutes') await airPlayRouteGate?.future;
      if (call.method == 'close') await airPlayCloseGate?.future;
      if (call.method == 'close' && failAirPlayClose) {
        throw PlatformException(
          code: 'airplay_close',
          message: 'private failure',
        );
      }
      if (call.method == 'open') {
        airPlayIdentity = (call.arguments as Map)['sessionId'] as String;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(airPlayChannel, null));
  }

  Future<void> emitAirPlay({
    int index = 0,
    bool closed = false,
    bool playing = true,
    bool global = false,
    bool ended = false,
    int positionMs = 42000,
  }) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          airPlayChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('state', {
              'sessionId': global ? '' : airPlayIdentity,
              'sequence': ++airPlaySequence,
              'itemId': '$index',
              'positionMs': positionMs,
              'durationMs': 120000,
              'playing': playing && !closed,
              'routed': external,
              'active': external && !closed,
              'closed': closed,
              'ended': ended,
              'needsNext': true,
            }),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  for (final interruption in [
    'slider cancel',
    'background',
    'lock',
    'episode',
    'AirPlay',
    'overlap',
  ]) {
    testWidgets('player releases interaction after $interruption', (
      tester,
    ) async {
      installAirPlay();
      final (native, _, _, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
        playbackSpeed: 1.5,
      );
      final player = tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller;
      final initialSeeks = native.seeks.length;
      final slider = tester.getRect(find.byType(Slider));
      final gesture = await tester.startGesture(
        interruption == 'slider cancel'
            ? slider.centerLeft + const Offset(40, 0)
            : const Offset(400, 300),
      );
      if (interruption == 'slider cancel') {
        await gesture.moveBy(const Offset(120, 0));
        await tester.pump();
        await gesture.cancel();
      } else {
        await tester.pump(const Duration(milliseconds: 600));
        expect(player.videoPlayerController!.value.speed, 2);
        switch (interruption) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await tester.pump();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
          case 'lock':
            await tester.tap(find.byTooltip('更多播放设置'));
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(
              find.text('锁定手势'),
              180,
              scrollable: find
                  .descendant(
                    of: find.byType(BottomSheet),
                    matching: find.byType(Scrollable),
                  )
                  .last,
            );
            await tester.tap(find.text('锁定手势'));
            await tester.pumpAndSettle();
            expect(find.byTooltip('解锁手势'), findsOneWidget);
            await tester.tap(find.byTooltip('解锁手势'));
            await tester.pump();
          case 'episode':
            tester
                .widget<EpisodePager>(find.byType(EpisodePager))
                .controller
                .jumpToPage(1);
            await tester.pumpAndSettle();
            expect(native.sources.last['uri'], 'file:///tmp/cast-two.mp4');
            await tester.tapAt(const Offset(700, 150));
            await tester.pump();
          case 'AirPlay':
            await tester.tap(find.byTooltip('AirPlay'));
            await tester.pumpAndSettle();
          case 'overlap':
            final scrub = await tester.startGesture(
              slider.centerLeft + const Offset(40, 0),
            );
            await scrub.moveBy(const Offset(120, 0));
            await scrub.up();
            await tester.pump(const Duration(seconds: 4));
            expect(
              tester
                  .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
                  .opacity,
              1,
            );
            expect(player.videoPlayerController!.value.speed, 2);
            expect(native.seeks.length, initialSeeks + 1);
            await gesture.cancel();
        }
        if (interruption != 'overlap') {
          await gesture.moveBy(const Offset(100, 0));
          await gesture.up();
          await tester.pump();
          expect(native.seeks.length, initialSeeks);
        }
        if (interruption == 'AirPlay') {
          expect(player.videoPlayerController!.value.speed, 1.5);
          external = false;
          await emitAirPlay(closed: true);
          await tester.pumpAndSettle();
        }
      }
      expect(player.videoPlayerController!.value.speed, 1.5);
      if (interruption == 'slider cancel') {
        expect(native.seeks.length, initialSeeks);
      }
      await tester.pump(const Duration(seconds: 3));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  }

  testWidgets('AirPlay owns CENC files independently of phone cache trimming', (
    tester,
  ) async {
    installAirPlay();
    final jobs = <AirPlayFixturePreparer>[];
    await mount(
      tester,
      airPlayChannel: airPlayChannel,
      downloaded: false,
      provider: AirPlayFixtureProvider(),
      preparerFactory: () {
        final job = AirPlayFixturePreparer(jobs.length);
        jobs.add(job);
        return job;
      },
    );
    expect(jobs, hasLength(1));
    await tester.tap(find.byTooltip('AirPlay'));
    await tester.pumpAndSettle();
    // Phone current + native current + native upcoming have separate owners.
    expect(jobs, hasLength(3));
    expect(jobs.every((job) => !job.disposed), true);
    await emitAirPlay(index: 1);
    await tester.pumpAndSettle();
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          NativeCastPlayer.connectivityEvents.name,
          const StandardMethodCodec().encodeSuccessEnvelope(['mobile']),
          (_) => done.complete(),
        );
    await done.future;
    await tester.pumpAndSettle();
    expect(jobs[0].disposed, true);
    expect(jobs[1].disposed, false);
    expect(jobs[2].disposed, false);
    await unmount(tester);
    expect(jobs.every((job) => job.disposed), true);
  });

  for (final paused in [false, true]) {
    testWidgets(
      'AirPlay owns a separate native queue and preserves paused=$paused',
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
        final sourceCount = native.sources.length, plays = native.plays;
        await tester.tap(find.byTooltip('AirPlay'));
        await tester.pumpAndSettle();
        expect(native.sources.length, sourceCount);
        expect(native.sources.last['uri'], 'file:///tmp/cast-one.mp4');
        expect(native.plays, plays);
        expect(relay.starts, 2);
        final open =
            airPlayCalls.singleWhere((c) => c.method == 'open').arguments
                as Map;
        expect(open['playing'], !paused);
        expect(open['positionMs'], 10000);
        expect(open.containsKey('textureId'), false);
        expect(
          (open['item'] as Map)['url'],
          'http://192.168.1.2:8080/token/0.mp4',
        );
        expect(
          tester.widget<EpisodePager>(find.byType(EpisodePager)).locked,
          true,
        );
        native.emit('finished');
        native.emit('play');
        await tester.pumpAndSettle();
        expect(native.sources.length, sourceCount);
        // The upstream Dart SDK internally attempts play before delivering the
        // native event to listeners. The iOS ownership guard rejects it; here
        // verify the page also pauses and never changes the local source.
        expect(native.plays, plays + 1);
        expect(
          tester
              .widget<BetterPlayer>(find.byType(BetterPlayer))
              .controller
              .isPlaying(),
          false,
        );
        await unmount(tester);
        expect(relay.closes, 2);
      },
    );
  }

  testWidgets(
    'native item changes advance in background and close restores that episode',
    (tester) async {
      installAirPlay();
      final (native, _, relay, store, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      await tester.tap(find.byTooltip('AirPlay'));
      await tester.pumpAndSettle();
      final sourceCount = native.sources.length;
      external = true;
      await emitAirPlay();
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await emitAirPlay(index: 1);
      await tester.pumpAndSettle();
      expect(native.sources.length, sourceCount);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      external = false;
      await emitAirPlay(index: 1, closed: true);
      await tester.pumpAndSettle();
      expect(native.sources.last['uri'], 'file:///tmp/cast-two.mp4');
      expect(native.seeks.last, 42000);
      expect(store.records.history['hongguo:fixture']!.episodeId, 'two');
      expect(store.records.history['hongguo:fixture']!.episodeIndex, 9);
      expect(store.records.history['hongguo:fixture']!.episodeNumber, 2);
      expect(relay.closes, 2);
      await unmount(tester);
    },
  );

  testWidgets('native pause is preserved when returning to the phone', (
    tester,
  ) async {
    installAirPlay();
    final (native, _, _, _, _) = await mount(
      tester,
      airPlayChannel: airPlayChannel,
      autoAdvance: false,
    );
    await tester.tap(find.byTooltip('AirPlay'));
    await tester.pumpAndSettle();
    await emitAirPlay(playing: false);
    await tester.pumpAndSettle();
    final plays = native.plays;
    await emitAirPlay(playing: false, closed: true);
    await tester.pumpAndSettle();
    expect(native.plays, plays);
    expect(native.seeks.last, 42000);
    expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
    await unmount(tester);
  });

  for (final stage in ['preparing', 'seeking', 'failed']) {
    testWidgets(
      'background save during AirPlay return keeps the remote position: $stage',
      (tester) async {
        installAirPlay();
        final (native, _, _, store, downloads) = await mount(
          tester,
          airPlayChannel: airPlayChannel,
        );
        await tester.tap(find.byTooltip('AirPlay'));
        await tester.pumpAndSettle();
        await emitAirPlay(index: 1, playing: false);
        await tester.pumpAndSettle();
        final gate = Completer<void>();
        if (stage == 'seeking') {
          native.seekGate = gate;
        } else {
          downloads.fileGate = gate;
        }
        if (stage == 'failed') {
          downloads.available = false;
          store.offline = true;
        }
        await emitAirPlay(index: 1, playing: false, closed: true);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        final duringReturn = store.records.history['hongguo:fixture']!;
        gate.complete();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await unmount(tester);
        expect(duringReturn.episodeId, 'two');
        expect(duringReturn.episodeIndex, 9);
        expect(duringReturn.positionMs, 42000);
        expect(store.records.history['hongguo:fixture']!.positionMs, 42000);
      },
    );
  }

  for (final ended in [true, false]) {
    testWidgets(
      'AirPlay at full duration confirms completion only with ended=$ended',
      (tester) async {
        installAirPlay();
        final (native, _, _, store, _) = await mount(
          tester,
          airPlayChannel: airPlayChannel,
          autoAdvance: false,
        );
        await tester.tap(find.byTooltip('AirPlay'));
        await tester.pumpAndSettle();
        await emitAirPlay(playing: false, ended: ended, positionMs: 120000);
        await tester.pumpAndSettle();
        await emitAirPlay(
          playing: false,
          ended: ended,
          positionMs: 120000,
          closed: true,
        );
        await tester.pumpAndSettle();
        expect(
          store.records.history['hongguo:fixture']!.episodeCompleted,
          ended,
        );
        expect(native.seeks.last, 120000);
        await unmount(tester);
        expect(
          store.records.history['hongguo:fixture']!.episodeCompleted,
          ended,
        );
      },
    );
  }

  testWidgets('Cast stopped at full duration does not confirm completion', (
    tester,
  ) async {
    final (_, receiver, _, store, _) = await mount(tester);
    await connect(tester);
    receiver.playback = const CastPlayback(
      position: Duration(seconds: 120),
      duration: Duration(seconds: 120),
      state: CastPlaybackState.stopped,
    );
    await tester.tap(find.byKey(const Key('stopCasting')));
    await tester.pumpAndSettle();
    expect(store.records.history['hongguo:fixture']!.episodeCompleted, false);
    await unmount(tester);
  });

  testWidgets(
    'closing while TV route remains never restarts phone audio or video',
    (tester) async {
      installAirPlay();
      final (native, _, relay, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
        autoAdvance: false,
      );
      await tester.tap(find.byTooltip('AirPlay'));
      await tester.pumpAndSettle();
      external = true;
      await emitAirPlay();
      await tester.pumpAndSettle();
      final plays = native.plays, sources = native.sources.length;
      await emitAirPlay(closed: true);
      await tester.pumpAndSettle();
      expect(native.plays, plays);
      expect(native.sources.length, sources);
      expect(relay.closes, 1);
      expect(find.byKey(const Key('airPlayChooseRoute')), findsOneWidget);
      await tester.tap(find.byKey(const Key('airPlayChooseRoute')));
      await tester.pumpAndSettle();
      expect(airPlayCalls.last.method, 'showRoutes');
      external = false;
      await emitAirPlay(global: true);
      await tester.pumpAndSettle();
      expect(native.sources.length, sources + 1);
      expect(native.plays, plays + 1);
      expect(native.seeks.last, 42000);
      await unmount(tester);
    },
  );

  testWidgets(
    'inherited TV audio route blocks local play before any AirPlay session',
    (tester) async {
      installAirPlay(selected: true);
      final (native, _, _, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
      );
      expect(native.plays, 0);
      expect(native.sources.single['uri'], 'file:///tmp/cast-one.mp4');
      expect(find.byKey(const Key('airPlayChooseRoute')), findsOneWidget);
      external = false;
      await emitAirPlay(global: true);
      await tester.pumpAndSettle();
      expect(native.plays, 1);
      await unmount(tester);
    },
  );

  testWidgets(
    'native route rejection offers route selection and resumes after switching back',
    (tester) async {
      installAirPlay(selected: true);
      final (native, _, _, _, _) = await mount(
        tester,
        airPlayChannel: airPlayChannel,
        configureNative: (native) => native.beforeSource = (_) {
          if (external) {
            throw PlatformException(
              code: 'airplay_route',
              message: 'private native details',
            );
          }
        },
      );
      expect(native.plays, 0);
      expect(find.text('重试'), findsNothing);
      await tester.tap(find.byKey(const Key('airPlayChooseRoute')));
      await tester.pumpAndSettle();
      expect(airPlayCalls.last.method, 'showRoutes');
      external = false;
      await emitAirPlay(global: true);
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(1));
      expect(native.plays, 1);
      expect(find.byKey(const Key('airPlayChooseRoute')), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('failed AirPlay return offers an effective return retry', (
    tester,
  ) async {
    installAirPlay();
    final (native, _, relay, store, _) = await mount(
      tester,
      airPlayChannel: airPlayChannel,
      autoAdvance: false,
    );
    await tester.tap(find.byTooltip('AirPlay'));
    await tester.pumpAndSettle();
    failAirPlayClose = true;
    await emitAirPlay(closed: true, playing: false);
    await tester.pumpAndSettle();
    expect(relay.closes, 0);
    expect(find.text('重试'), findsNothing);
    expect(find.text('重试返回手机'), findsOneWidget);
    failAirPlayClose = false;
    final gate = airPlayCloseGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await tester.tap(find.text('重试返回手机'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '正在返回手机…'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('正在返回手机…'));
    await tester.pump();
    expect(airPlayCalls.where((call) => call.method == 'close'), hasLength(2));
    gate.complete();
    await tester.pumpAndSettle();
    expect(native.seeks.last, 42000);
    expect(store.records.history['hongguo:fixture']!.positionMs, 42000);
    expect(relay.closes, 1);
    await unmount(tester);
  });

  testWidgets(
    'route selection blocks duplicate opens and handles native failure',
    (tester) async {
      installAirPlay(selected: true);
      await mount(tester, airPlayChannel: airPlayChannel);
      final gate = airPlayRouteGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final choose = tester
          .widget<FilledButton>(find.byKey(const Key('airPlayChooseRoute')))
          .onPressed!;
      choose();
      choose();
      await tester.pump();
      expect(
        airPlayCalls.where((call) => call.method == 'showRoutes'),
        hasLength(1),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('airPlayChooseRoute')))
            .onPressed,
        isNull,
      );
      gate.completeError(
        PlatformException(
          code: 'airplay_busy',
          message: 'private native details',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法打开 AirPlay 设备选择，请稍后再试'), findsOneWidget);
      expect(find.textContaining('private native details'), findsNothing);
      airPlayRouteGate = null;
      await tester.tap(find.byKey(const Key('airPlayChooseRoute')));
      await tester.pumpAndSettle();
      expect(
        airPlayCalls.where((call) => call.method == 'showRoutes'),
        hasLength(2),
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
      final record = store.records.history['hongguo:fixture']!;
      expect(record.positionMs, 57000);
      expect(record.episodeId, 'one');
      expect(record.episodeIndex, 5);
      expect(record.episodeNumber, 1);
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
      expect(store.records.history['hongguo:fixture']!.positionMs, 57000);
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
