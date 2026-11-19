import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/playback_diagnostic.dart';
import 'package:guoguo_mobile/platform/episode_buffer.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/player_notice.dart';
import 'package:guoguo_mobile/ui/player_transport.dart';

import 'player_cast_handoff_test.dart' show NativeCastPlayer, LocalDownloads;
import 'widget_test.dart' show NoNetwork;

class _Provider extends NoNetwork {
  Object? failure;
  int resolves = 0;
  int fallbacks = 0;
  int expiresAt = 0;
  Completer<void>? gate;
  int? gatedResolve;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'fallback') fallbacks++;
    if (method != 'resolve') return {};
    resolves++;
    if (gatedResolve == null || resolves == gatedResolve) await gate?.future;
    if (failure case final error?) throw error;
    return {
      'url': 'https://fixture.test/video.mp4',
      'remoteUrl': 'https://fixture.test/video.mp4',
      'expiresAt': expiresAt,
      'session': expiresAt == 0 ? '' : 'fixture-$resolves',
      'routeCount': expiresAt == 0 ? 1 : 2,
    };
  }
}

void main() {
  Future<(NativeCastPlayer, LocalDownloads, AppStore)> mount(
    WidgetTester tester,
    _Provider provider, {
    bool offline = false,
    bool settle = true,
    bool autoAdvance = true,
    DateTime Function()? clock,
    DramaSource source = DramaSource.hongguo,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    final store = AppStore(storage: MemoryStorage(), provider: provider)
      ..offline = offline
      ..preferences.prefetch = false
      ..preferences.autoAdvance = autoAdvance;
    final downloads = LocalDownloads(store)..available = false;
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
          drama: Drama(id: 'fixture', source: source, title: '失败恢复'),
          episodes: [
            Episode.fromJson({'id': 'one'}, 0),
            Episode.fromJson({'id': 'two'}, 1),
          ],
          initialIndex: 0,
          playbackClock: clock,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
    return (native, downloads, store);
  }

  Future<void> togglePlayback(WidgetTester tester) async {
    tester.widget<PlayerTransport>(find.byType(PlayerTransport)).onPlay();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'resume refreshes an expired link and seeks in the same episode',
    (tester) async {
      var now = DateTime(2026, 11, 19);
      final provider = _Provider()
        ..expiresAt = now
            .add(const Duration(minutes: 1))
            .millisecondsSinceEpoch;
      final (native, _, _) = await mount(
        tester,
        provider,
        clock: () => now,
        source: DramaSource.huangguo,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await togglePlayback(tester);
      await togglePlayback(tester);
      expect(provider.resolves, 1);
      expect(native.plays, 2);
      await togglePlayback(tester);

      now = now.add(const Duration(minutes: 2));
      provider.expiresAt = now
          .add(const Duration(minutes: 1))
          .millisecondsSinceEpoch;
      await togglePlayback(tester);
      expect(provider.resolves, 2);
      expect(provider.fallbacks, 0);
      expect(native.sources.map((source) => source['author']), [
        '果果 · 第 1 集',
        '果果 · 第 1 集',
      ]);
      expect(native.seeks, [10000]);
      expect(native.plays, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('replay refreshes an expired link before seeking to zero', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 19);
    final provider = _Provider()
      ..expiresAt = now.add(const Duration(minutes: 1)).millisecondsSinceEpoch;
    final (native, _, _) = await mount(
      tester,
      provider,
      autoAdvance: false,
      clock: () => now,
      source: DramaSource.huangguo,
    );
    native.emit('completed');
    await tester.pumpAndSettle();
    now = now.add(const Duration(minutes: 2));
    provider.expiresAt = now
        .add(const Duration(minutes: 1))
        .millisecondsSinceEpoch;
    final sourceCountsAtSeek = <int>[];
    native.beforeSeek = (_) => sourceCountsAtSeek.add(native.sources.length);

    await togglePlayback(tester);

    expect(
      provider.resolves,
      2,
      reason: 'seeks on sources $sourceCountsAtSeek',
    );
    expect(sourceCountsAtSeek, [2]);
    expect(native.seeks, [0]);
    expect(native.plays, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed resume seek retains the target for manual retry', (
    tester,
  ) async {
    final provider = _Provider();
    final (native, _, _) = await mount(tester, provider);
    await tester.pump(const Duration(milliseconds: 400));
    await togglePlayback(tester);
    native.beforeSeek = (_) {
      native.beforeSeek = null;
      throw PlatformException(code: 'seek_failed');
    };
    native.emitFailure();
    await tester.pumpAndSettle();
    expect(provider.resolves, 2);
    expect(native.seeks, [10000]);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(provider.resolves, 3);
    expect(native.seeks, [10000, 10000]);
    expect(native.plays, 2);
    expect(find.byType(PlayerNotice), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed resume reloads even when the old player cannot pause', (
    tester,
  ) async {
    final provider = _Provider();
    final (native, _, _) = await mount(tester, provider);
    await tester.pump(const Duration(milliseconds: 400));
    await togglePlayback(tester);
    native.beforePlay = () {
      native.beforePlay = null;
      native.beforePause = () => throw PlatformException(code: 'pause_failed');
      throw PlatformException(code: 'play_failed');
    };
    native.beforeSource = (_) => native.beforePause = null;
    await togglePlayback(tester);

    expect(provider.resolves, 2);
    expect(native.seeks, [10000]);
    expect(native.plays, 2);
    expect(find.byType(PlayerNotice), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final paused in [false, true]) {
    testWidgets('foreground handles a background error with paused=$paused', (
      tester,
    ) async {
      final provider = _Provider();
      final (native, _, _) = await mount(tester, provider);
      await tester.pump(const Duration(milliseconds: 400));
      if (paused) await togglePlayback(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      native.emit('pause');
      native.emitFailure();
      await tester.pump();
      expect(provider.resolves, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      if (paused) {
        expect(provider.resolves, 1);
        expect(native.plays, 1);
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
      }
      expect(provider.resolves, 2);
      expect(native.seeks, [10000]);
      expect(native.plays, 2);
      expect(find.byType(PlayerNotice), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'automatic retry keeps the safe cause visible and clears it on success',
    (tester) async {
      final gate = Completer<void>();
      final provider = _Provider()
        ..failure = const ProviderException('红果 App 接口未返回有效数据 private-secret')
        ..gate = gate
        ..gatedResolve = 2;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final (native, _, _) = await mount(tester, provider, settle: false);
      for (var index = 0; index < 5; index++) {
        await tester.pump();
      }
      expect(provider.resolves, 2);
      expect(find.textContaining('红果暂未返回播放资源，请稍后重试'), findsOneWidget);
      expect(find.textContaining('private-secret'), findsNothing);
      provider.failure = null;
      gate.complete();
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(1));
      expect(find.textContaining('红果暂未返回播放资源'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline file failure offers one manual recheck and episode selection',
    (tester) async {
      final provider = _Provider();
      final (native, downloads, _) = await mount(
        tester,
        provider,
        offline: true,
      );
      expect(find.text('此分集未下载或文件已不存在，请下载后再播放'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.text('重新检查'), findsOneWidget);
      expect(downloads.lookups, 1);
      expect(provider.resolves, 0);
      await tester.tap(find.text('重新检查'));
      await tester.pumpAndSettle();
      expect(downloads.lookups, 2);
      expect(provider.resolves, 0);
      downloads.available = true;
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerNotice),
          matching: find.text('选集'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(native.sources.single['uri'], 'file:///tmp/cast-two.mp4');
      expect(find.text('重新检查'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'network retry is bounded, suppresses duplicate clicks and can recover',
    (tester) async {
      final provider = _Provider()
        ..failure = const SocketException('private host');
      final (native, _, _) = await mount(tester, provider);
      expect(provider.resolves, 2);
      expect(find.text('视频连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.textContaining('private host'), findsNothing);
      final gate = provider.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      provider.failure = null;
      final retry = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '重试'))
          .onPressed!;
      retry();
      retry();
      await tester.pump();
      expect(provider.resolves, 3);
      gate.complete();
      await tester.pumpAndSettle();
      expect(native.sources, hasLength(1));
      expect(native.plays, 1);
      expect(find.text('视频连接失败，请检查网络后重试'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancelled preparation stays cancelled until explicit retry', (
    tester,
  ) async {
    final provider = _Provider()..failure = EpisodeCancelled();
    final (native, _, store) = await mount(tester, provider);
    expect(provider.resolves, 1);
    expect(find.text('准备已取消，请重试或选择其他分集'), findsOneWidget);
    expect(store.playbackDiagnostics.single.result, PlaybackResult.cancelled);
    provider.failure = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(provider.resolves, 2);
    expect(native.plays, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
