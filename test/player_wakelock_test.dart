import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/player_transport.dart';
// Use the plugin's actual codec to check the native wakelock requests.
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/messages.g.dart';

import 'player_cast_handoff_test.dart' show LocalDownloads, NativeCastPlayer;
import 'support/cast_fakes.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wakelock = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    WakelockPlusApi.pigeonChannelCodec,
  );
  const airplay = MethodChannel('guoguo/airplay');
  final requests = <bool>[];
  var awake = false, failNext = false;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    requests.clear();
    awake = failNext = false;
    messenger.setMockDecodedMessageHandler(wakelock, (message) async {
      final enabled = ((message as List).single as ToggleMessage).enable!;
      requests.add(enabled);
      if (failNext) {
        failNext = false;
        return ['wakelock_failed', 'Screen policy unavailable', null];
      }
      awake = enabled;
      return [null];
    });
    messenger.setMockMethodCallHandler(airplay, (_) async => {'routed': false});
  });
  tearDown(() {
    messenger.setMockDecodedMessageHandler(wakelock, null);
    messenger.setMockMethodCallHandler(airplay, null);
  });

  Future<(NativeCastPlayer, BetterPlayerController, FakeCastReceiver)> mount(
    WidgetTester tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    final receiver = FakeCastReceiver(), relay = FakeCastRelay();
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..preferences.prefetch = false
      ..preferences.autoAdvance = false;
    final downloads = LocalDownloads(store);
    addTearDown(() {
      native.uninstall();
      downloads.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
          child: child!,
        ),
        home: PlayerPage(
          store: store,
          downloads: downloads,
          drama: const Drama(
            id: 'awake',
            source: DramaSource.hongguo,
            title: '保持亮屏',
          ),
          episodes: [
            Episode.fromJson({'id': 'one'}, 0),
            Episode.fromJson({'id': 'two'}, 1),
          ],
          initialIndex: 0,
          localOnly: true,
          castRelayFactory: () => relay,
          castDiscoveryFactory: () => FakeCastDiscovery(receiver),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      native,
      tester.widget<BetterPlayer>(find.byType(BetterPlayer)).controller,
      receiver,
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(awake, isFalse);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'app fullscreen owns wakelock across playback and source changes',
    (tester) async {
      final (native, player, _) = await mount(tester);
      expect(player.isFullScreen, isFalse);
      expect(awake, isTrue);
      await tester.pump(const Duration(minutes: 3));
      expect(requests, [true]);

      native.emit('bufferingStart');
      await tester.pump();
      expect(awake, isTrue);
      native.emit('bufferingEnd');
      await tester.pump();
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(awake, isFalse);
      await tester.tap(find.byTooltip('播放'));
      await tester.pumpAndSettle();
      expect(awake, isTrue);

      tester.widget<PlayerTransport>(find.byType(PlayerTransport)).onNext!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(awake, isFalse);
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(2));
      expect(awake, isTrue);
      native.emit('completed');
      await tester.pumpAndSettle();
      expect(awake, isFalse);
      await tester.tap(find.byTooltip('播放'));
      await tester.pumpAndSettle();
      expect(awake, isTrue);
      await unmount(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'background and PiP release wakelock despite native play events',
    (tester) async {
      final (native, _, _) = await mount(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(awake, isFalse);
        native.emit('play');
        await tester.pumpAndSettle();
        expect(awake, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(awake, isTrue);
      }
      native.emit('pipStart');
      await tester.pumpAndSettle();
      expect(awake, isFalse);
      native.emit('play');
      await tester.pumpAndSettle();
      expect(awake, isFalse);
      native.emit('pipStop');
      await tester.pumpAndSettle();
      expect(awake, isTrue);
      await unmount(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('casting releases phone wakelock until local playback returns', (
    tester,
  ) async {
    final (_, _, receiver) = await mount(tester);
    expect(awake, isTrue);
    await tester.tap(find.byTooltip('投屏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('电视设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客厅电视'));
    await tester.pumpAndSettle();
    expect(awake, isFalse);
    receiver.playback = const CastPlayback(state: CastPlaybackState.paused);
    await tester.tap(find.byKey(const Key('stopCasting')));
    await tester.pumpAndSettle();
    expect(awake, isFalse);
    await tester.tap(find.byTooltip('播放'));
    await tester.pumpAndSettle();
    expect(awake, isTrue);
    await unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('wakelock failure preserves playback and retries on next event', (
    tester,
  ) async {
    failNext = true;
    final (native, player, _) = await mount(tester);
    expect(player.isPlaying(), isTrue);
    native.emit('bufferingStart');
    await tester.pumpAndSettle();
    expect(awake, isTrue);
    expect(
      requests.where((enabled) => enabled).length,
      greaterThanOrEqualTo(2),
    );
    await unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a native video failure releases wakelock', (tester) async {
    await mount(tester);
    expect(awake, isTrue);
    messenger.handlePlatformMessage(
      NativeCastPlayer.events.name,
      const StandardMethodCodec().encodeErrorEnvelope(
        code: 'VideoError',
        message: 'Video failed',
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(awake, isFalse);
    await unmount(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
