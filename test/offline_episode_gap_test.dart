import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/player_page.dart';

import 'player_cast_handoff_test.dart'
    show NativeCastPlayer, LocalDownloads, RelayLease;
import 'support/cast_fakes.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  const channel = MethodChannel('guoguo/offline-airplay-test');
  final calls = <MethodCall>[];
  String? identity;
  var sequence = 0;

  Future<(NativeCastPlayer, AppStore)> mount(
    WidgetTester tester, {
    List<int> indices = const [0, 2],
    List<Episode>? episodes,
    bool airPlay = false,
    bool autoAdvance = true,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..offline = true
      ..preferences.autoAdvance = autoAdvance
      ..preferences.prefetch = false;
    final downloads = LocalDownloads(store);
    final relay = FakeCastRelay();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    calls.clear();
    identity = null;
    sequence = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getState') return {'routed': false};
      if (call.method == 'open') {
        identity = (call.arguments as Map)['sessionId'] as String;
      }
      return null;
    });
    addTearDown(() {
      native.uninstall();
      messenger.setMockMethodCallHandler(channel, null);
      downloads.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          store: store,
          downloads: downloads,
          drama: const Drama(
            id: 'offline',
            source: DramaSource.hongguo,
            title: '离线播放',
          ),
          episodes:
              episodes ??
              [
                Episode.fromJson({'id': 'one', 'currentEpisode': 1}, 0),
                Episode.fromJson({'id': 'three', 'currentEpisode': 3}, 1),
              ],
          initialIndex: 0,
          episodeIndices: indices,
          localOnly: true,
          airPlayChannel: airPlay ? channel : null,
          castRelayFactory: () => RelayLease(relay),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    return (native, store);
  }

  Future<void> state({int index = 0, bool ended = false}) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('state', {
              'sessionId': identity,
              'sequence': ++sequence,
              'itemId': '$index',
              'positionMs': ended ? 120000 : 10000,
              'durationMs': 120000,
              'playing': !ended,
              'ended': ended,
              'needsNext': true,
              'retainedItemIds': ['$index'],
            }),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  for (final pip in [false, true]) {
    testWidgets('offline gap stops automatic playback, including PiP=$pip', (
      tester,
    ) async {
      final (native, store) = await mount(tester);
      if (pip) {
        native.emit('pipStart');
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      }
      native.emit('completed');
      native.emit('completed');
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(1));
      expect(store.records.history.values.single.episodeCompleted, true);
      expect(store.records.history.values.single.episodeId, 'one');
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        false,
      );
      if (pip) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        native.emit('pipStop');
        await tester.pumpAndSettle();
      }
      expect(find.text('下一集未下载，已停止连播'), findsOneWidget);
      await tester.tap(find.text('播放已下载的第 3 集'));
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(2));
      expect(native.sources.last['uri'], 'file:///tmp/cast-three.mp4');
      expect(find.text('下一集未下载，已停止连播'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final replay in [false, true]) {
    testWidgets(
      'offline gap notice clears after ${replay ? 'replay' : 'seeking back'}',
      (tester) async {
        final (native, store) = await mount(tester);
        native.emit('completed');
        await tester.pumpAndSettle();
        expect(find.text('下一集未下载，已停止连播'), findsOneWidget);
        if (replay) {
          await tester.tap(find.byTooltip('播放'));
        } else {
          final scrub = tester.widget<Slider>(find.byType(Slider));
          scrub.onChangeStart!(scrub.value);
          scrub.onChanged!(10000);
          scrub.onChangeEnd!(10000);
        }
        await tester.pumpAndSettle();
        expect(find.text('下一集未下载，已停止连播'), findsNothing);
        expect(store.records.history.values.single.episodeCompleted, false);
        expect(native.sources, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'consecutive downloads keep automatic playback despite irregular display numbers',
    (tester) async {
      final (native, _) = await mount(tester, indices: [4, 5]);
      native.emit('completed');
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(2));
      expect(native.sources.last['uri'], 'file:///tmp/cast-three.mp4');
      expect(find.text('下一集未下载，已停止连播'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'AirPlay keeps a gap out of its automatic queue and permits native manual Next',
    (tester) async {
      final (_, store) = await mount(tester, airPlay: true);
      await tester.tap(find.byTooltip('AirPlay'));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'append'), isEmpty);
      final item =
          (calls.firstWhere((call) => call.method == 'open').arguments
                  as Map)['item']
              as Map;
      expect(item['nextNotice'], '下一集未下载，不会自动跳集');
      expect(item['nextTitle'], '播放第 3 集');
      expect(item['hasNext'], true);
      await state(ended: true);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'append'), isEmpty);
      expect(store.records.history.values.single.episodeCompleted, true);
      final done = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('requestNext', {
                'sessionId': identity,
                'afterId': '0',
              }),
            ),
            (_) => done.complete(),
          );
      await done.future;
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'append'), hasLength(1));
      final next =
          (calls.firstWhere((call) => call.method == 'append').arguments
                  as Map)['item']
              as Map;
      expect(next['id'], '1');
      expect(next.containsKey('nextNotice'), false);
      await state(index: 1);
      await tester.pumpAndSettle();
      expect(store.records.history.values.single.episodeIndex, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final airPlay in [false, true]) {
    testWidgets(
      'a later gap stops after the consecutive successor, AirPlay=$airPlay',
      (tester) async {
        final (native, store) = await mount(
          tester,
          airPlay: airPlay,
          indices: [0, 1, 3],
          episodes: [
            Episode.fromJson({'id': 'one', 'currentEpisode': 1}, 0),
            Episode.fromJson({'id': 'two', 'currentEpisode': 2}, 1),
            Episode.fromJson({'id': 'three', 'currentEpisode': 4}, 2),
          ],
        );
        if (airPlay) {
          await tester.tap(find.byTooltip('AirPlay'));
          await tester.pumpAndSettle();
          final append = calls.where((call) => call.method == 'append').single;
          final item = (append.arguments as Map)['item'] as Map;
          expect(item['nextNotice'], '下一集未下载，不会自动跳集');
          expect(item['nextTitle'], '播放第 4 集');
          await state(index: 1);
          await tester.pumpAndSettle();
          await state(index: 1, ended: true);
          await tester.pumpAndSettle();
          expect(calls.where((call) => call.method == 'append'), hasLength(1));
        } else {
          native.emit('completed');
          await tester.pumpAndSettle();
          expect(native.sources, hasLength(2));
          native.emit('completed');
          await tester.pumpAndSettle();
          expect(native.sources, hasLength(2));
          expect(find.text('下一集未下载，已停止连播'), findsOneWidget);
          expect(find.text('播放已下载的第 4 集'), findsOneWidget);
        }
        expect(store.records.history.values.single.episodeId, 'two');
        expect(store.records.history.values.single.episodeCompleted, true);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('AirPlay automatically queues consecutive downloads', (
    tester,
  ) async {
    await mount(tester, indices: [4, 5], airPlay: true);
    await tester.tap(find.byTooltip('AirPlay'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'append'), hasLength(1));
    final item =
        (calls.firstWhere((call) => call.method == 'open').arguments
                as Map)['item']
            as Map;
    expect(item.containsKey('nextNotice'), false);
    await tester.pumpWidget(const SizedBox());
  });
}
