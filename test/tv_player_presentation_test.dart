import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/player_sheets.dart';
import 'package:guoguo_mobile/ui/player_render_status.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/theme.dart';

import 'player_cast_handoff_test.dart' show LocalDownloads, NativeCastPlayer;
import 'widget_test.dart' show NoNetwork;

Future<NativeCastPlayer> _mount(
  WidgetTester tester, {
  int initialIndex = 0,
  Size size = const Size(1280, 720),
  double textScale = 1,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final native = NativeCastPlayer()..install();
  final app = AppStore(storage: MemoryStorage(), provider: NoNetwork())
    ..offline = true
    ..preferences.prefetch = false
    ..preferences.autoAdvance = false;
  final downloads = LocalDownloads(app);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    native.uninstall();
    downloads.dispose();
    app.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: guoguoTheme(Brightness.dark, television: true),
      builder: (context, page) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: TelevisionScope(
          enabled: true,
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            },
            child: page!,
          ),
        ),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              autofocus: true,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PlayerPage(
                    store: app,
                    downloads: downloads,
                    drama: const Drama(
                      id: 'fixture',
                      source: DramaSource.hongguo,
                      title: '电视播放样本',
                    ),
                    episodes: [
                      Episode.fromJson({'id': 'one'}, 0),
                      Episode.fromJson({'id': 'two'}, 1),
                    ],
                    initialIndex: initialIndex,
                    localOnly: true,
                  ),
                ),
              ),
              child: const Text('打开播放器'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
  return native;
}

double _opacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
bool _focused(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;
Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  if (key == LogicalKeyboardKey.goBack) {
    // Android's system Back arrives through the Navigator platform route.
    await tester.binding.handlePopRoute();
  } else {
    await tester.sendKeyEvent(key);
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in [1.0, 1.8]) {
    testWidgets(
      'narrow TV player preserves visual directions and video at scale $scale',
      (tester) async {
        final native = await _mount(
          tester,
          size: const Size(720, 480),
          textScale: scale,
        );
        final surface = tester.state(find.byType(BetterPlayer));
        await _key(tester, LogicalKeyboardKey.arrowRight);
        await _key(tester, LogicalKeyboardKey.arrowRight);
        expect(_focused(tester, '1.0x'), true);
        expect(
          tester.getCenter(find.text('选集')).dy,
          greaterThan(tester.getCenter(find.text('1.0x')).dy + 30),
        );
        await _key(tester, LogicalKeyboardKey.arrowRight);
        expect(_focused(tester, '1.0x'), true);
        await _key(tester, LogicalKeyboardKey.arrowDown);
        expect(_focused(tester, '选集'), true);
        await _key(tester, LogicalKeyboardKey.select);
        expect(find.byType(PlayerEpisodeSheet), findsOneWidget);
        await _key(tester, LogicalKeyboardKey.goBack);
        expect(find.byType(PlayerEpisodeSheet), findsNothing);
        expect(tester.state(find.byType(BetterPlayer)), same(surface));
        expect(native.sources, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'TV exposes a device snapshot without replacing the video surface',
    (tester) async {
      final native = await _mount(tester);
      final surface = tester.state(find.byType(BetterPlayer));
      const channel = MethodChannel('guoguo/device');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'playbackDeviceInfo');
        return {
          'manufacturer': 'Fixture',
          'model': 'TV 9',
          'androidVersion': '10',
          'apiLevel': 29,
          'version': '0.20.3-dev',
          'build': 55,
          'abis': ['armeabi-v7a'],
          'renderingPolicy': 'legacy-opengl',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.select);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(Focus.of(tester.element(find.text('画面状态'))).hasPrimaryFocus, true);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.byType(PlayerRenderStatus), findsOneWidget);
      final status = tester.widget<PlayerRenderStatus>(
        find.byType(PlayerRenderStatus),
      );
      expect(status.playback['prepared'], true);
      expect(status.playback['playing'], true);
      expect(status.playback['coverVisible'], false);
      expect(status.playback['viewWidth'], 1280);
      expect(status.playback['viewHeight'], 720);
      expect(status.playback['fit'], 'contain');
      expect(find.textContaining('Fixture TV 9'), findsOneWidget);
      expect(identical(tester.state(find.byType(BetterPlayer)), surface), true);
      expect(native.sources, hasLength(1));
      await _key(tester, LogicalKeyboardKey.goBack);
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(Poster), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV playback exposes one texture, clears cover and focuses play',
    (tester) async {
      final native = await _mount(tester);
      expect(native.plays, greaterThan(0));
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        true,
      );
      expect(find.byType(Poster), findsNothing);
      expect(find.byType(EpisodePager), findsNothing);
      expect(find.byType(Texture), findsOneWidget);
      expect(
        tester.getSize(find.byType(Texture)).shortestSide,
        greaterThan(100),
      );
      expect(_opacity(tester), 1);
      expect(_focused(tester, '暂停'), true);
      expect(
        tester.getSize(find.byType(FilledButton).hitTestable().first).height,
        greaterThanOrEqualTo(56),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV center, direction and back preserve video and then exit', (
    tester,
  ) async {
    final native = await _mount(tester);
    await _key(tester, LogicalKeyboardKey.select);
    expect(native.pauses, greaterThan(0));
    expect(_focused(tester, '播放'), true);
    await _key(tester, LogicalKeyboardKey.select);
    expect(
      tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller
          .isPlaying(),
      true,
    );
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, '下一集'), true);
    await _key(tester, LogicalKeyboardKey.select);
    expect(native.sources, hasLength(2));
    expect(native.sources.last['uri'], contains('cast-two.mp4'));
    expect(find.byType(Poster), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(_focused(tester, '暂停'), true);
    await _key(tester, LogicalKeyboardKey.goBack);
    expect(_opacity(tester), 0);
    expect(find.byType(Texture), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.select);
    expect(_opacity(tester), 1);
    expect(_focused(tester, '暂停'), true);
    await _key(tester, LogicalKeyboardKey.goBack);
    await _key(tester, LogicalKeyboardKey.goBack);
    expect(find.byType(BetterPlayer), findsNothing);
    expect(find.text('打开播放器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV episode dialog starts at current episode with remote focus', (
    tester,
  ) async {
    final native = await _mount(tester);
    for (var i = 0; i < 3; i++) {
      await _key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(_focused(tester, '选集'), true);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(PlayerEpisodeSheet), findsOneWidget);
    expect(_focused(tester, '1'), true);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, '2'), true);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byType(Dialog), findsNothing);
    expect(native.sources.last['uri'], contains('cast-two.mp4'));
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(Poster), findsNothing);
    expect(_focused(tester, '暂停'), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TV transport keeps arrows in the row and returns from the timeline',
    (tester) async {
      await _mount(tester);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(tester, '暂停'), true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, '1.0x'), true);
      expect(find.byKey(const Key('television-focus-outline')), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, '选集'), true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester, '选集'), true);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester, '选集'), true);
      expect(find.byType(Texture), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV options retain the video and use remote-specific actions', (
    tester,
  ) async {
    final native = await _mount(tester);
    final surface = tester.state(find.byType(BetterPlayer));
    await _key(tester, LogicalKeyboardKey.arrowUp);
    // Up leaves the controls for the timeline; another Up leaves the timeline.
    final seeks = native.seeks.length;
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(native.seeks, hasLength(seeks));
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(
      Focus.of(tester.element(find.byIcon(Icons.more_horiz))).hasPrimaryFocus,
      true,
    );
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(PlayerMoreSheet), findsOneWidget);
    expect(find.text('遥控器操作'), findsOneWidget);
    expect(find.text('切换横竖屏'), findsNothing);
    expect(find.text('锁定手势'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(identical(tester.state(find.byType(BetterPlayer)), surface), true);
    expect(native.sources, hasLength(1));
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(Poster), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
