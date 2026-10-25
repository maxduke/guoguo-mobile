import 'dart:io';
import 'dart:ui' as ui;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/player_sheets.dart';
import 'package:guoguo_mobile/ui/player_transport.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/theme.dart';

import 'player_cast_handoff_test.dart' show NativeCastPlayer, LocalDownloads;
import 'widget_test.dart' show NoNetwork;

class _Fixture {
  _Fixture(this.native, this.store, this.downloads, this.accessible);
  final NativeCastPlayer native;
  final AppStore store;
  final LocalDownloads downloads;
  final ValueNotifier<bool> accessible;
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  bool accessible = false,
  bool downloaded = true,
  bool television = false,
  double textScale = 1,
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.dark,
  GlobalKey? previewKey,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final native = NativeCastPlayer()..install();
  final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
    ..offline = true
    ..preferences.prefetch = false
    ..preferences.autoAdvance = false;
  final downloads = LocalDownloads(store)..available = downloaded;
  final navigation = ValueNotifier(accessible);
  addTearDown(() {
    native.uninstall();
    downloads.dispose();
    store.dispose();
    navigation.dispose();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: previewKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: television
            ? guoguoTheme(brightness, television: true)
            : ThemeData(brightness: brightness, fontFamily: 'sans-serif'),
        builder: (context, child) =>
            television ? TelevisionScope(enabled: true, child: child!) : child!,
        home: ValueListenableBuilder<bool>(
          valueListenable: navigation,
          builder: (context, enabled, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              accessibleNavigation: enabled,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          child: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: 'accessibility',
              source: DramaSource.hongguo,
              title: '山海有归期 · 一段很长的标题用于播放器布局验证',
            ),
            episodes: [
              Episode.fromJson({'id': 'one', 'currentEpisode': 1}, 0),
              Episode.fromJson({'id': 'three', 'currentEpisode': 3}, 1),
            ],
            episodeIndices: const [0, 2],
            initialIndex: 0,
            localOnly: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(native, store, downloads, navigation);
}

double _opacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

SemanticsFinder _tooltip(String value) => find.semantics.byPredicate(
  (node) => node.getSemanticsData().tooltip == value,
);

void main() {
  testWidgets('semantic video action reveals controls hidden by the timer', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    tester.semantics.tap(find.semantics.byLabel('视频画面'));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
    expect(_tooltip('暂停'), findsOne);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 0);
    expect(_tooltip('暂停'), findsNothing);
    tester.semantics.tap(find.semantics.byLabel('视频画面'));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
    expect(_tooltip('下一集 · 第 3 集'), findsOne);
    await fixture.close(tester);
  });

  testWidgets(
    'assistive navigation reveals controls and cancels an armed hide',
    (tester) async {
      final fixture = await _mount(tester);
      await tester.tapAt(const Offset(350, 200));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      fixture.accessible.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(_opacity(tester), 1);
      await tester.tapAt(const Offset(350, 200));
      await tester.pump();
      expect(_opacity(tester), 1);
      fixture.accessible.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0);
      fixture.accessible.value = true;
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
      expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'assistive navigation starts with usable play and progress actions',
    (tester) async {
      final fixture = await _mount(tester, accessible: true);
      expect(_opacity(tester), 1);
      final progress = find.semantics.byLabel('播放进度');
      final before = progress.evaluate().single.getSemanticsData().value;
      expect(before, contains('/ 2:00'));
      final seeks = fixture.native.seeks.length;
      tester.semantics.increase(progress);
      await tester.pumpAndSettle();
      expect(fixture.native.seeks, hasLength(seeks + 1));
      expect(fixture.native.seeks.last, greaterThan(0));
      tester.semantics.tap(_tooltip('暂停'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        false,
      );
      tester.semantics.tap(_tooltip('播放'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller
            .isPlaying(),
        true,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(_opacity(tester), 1);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'explicit episode buttons preserve IDs, gaps, ends and old callbacks',
    (tester) async {
      final fixture = await _mount(tester, accessible: true);
      final first = tester.widget<PlayerTransport>(
        find.byType(PlayerTransport),
      );
      expect(first.onPrevious, isNull);
      expect(first.onNext, isNotNull);
      tester.semantics.tap(_tooltip('下一集 · 第 3 集'));
      await tester.pumpAndSettle();
      expect(fixture.native.sources.last['uri'], 'file:///tmp/cast-three.mp4');
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).controller.page,
        1,
      );
      final last = tester.widget<PlayerTransport>(find.byType(PlayerTransport));
      expect(last.onNext, isNull);
      expect(last.previousLabel, '上一集 · 第 1 集');
      await tester.tap(find.byTooltip('上一集 · 第 1 集'));
      await tester.pumpAndSettle();
      final count = fixture.native.sources.length;
      first.onNext!();
      await tester.pumpAndSettle();
      expect(fixture.native.sources, hasLength(count));
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).controller.page,
        0,
      );
      await tester.tap(find.byTooltip('下一集 · 第 3 集'));
      await tester.pumpAndSettle();
      await fixture.close(tester);
      expect(fixture.store.records.history.values.single.episodeId, 'three');
      expect(fixture.store.records.history.values.single.episodeIndex, 2);
      last.onPrevious!();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('episode buttons remain reachable after playback fails', (
    tester,
  ) async {
    final fixture = await _mount(tester, downloaded: false);
    expect(
      tester.widget<PlayerTransport>(find.byType(PlayerTransport)).enabled,
      false,
    );
    await tester.tap(find.byTooltip('下一集 · 第 3 集'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EpisodePager>(find.byType(EpisodePager)).controller.page,
      1,
    );
    expect(find.byTooltip('上一集 · 第 1 集').hitTestable(), findsOneWidget);
    expect(
      find
          .descendant(
            of: find.byType(PlayerTransport),
            matching: find.text('选集'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(fixture.native.sources, isEmpty);
    await fixture.close(tester);
  });

  testWidgets('paused, menu and scrubbing controls do not auto-hide', (
    tester,
  ) async {
    final fixture = await _mount(tester, accessible: true);
    fixture.accessible.value = false;
    await tester.pump();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(_opacity(tester), 1);
    await tester.tap(find.byTooltip('播放'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放倍速'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(_opacity(tester), 1);
    await tester.tap(find.text('1.5 倍速'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(slider.value);
    slider.onChanged!(20000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(_opacity(tester), 1);
    slider.onChangeEnd!(20000);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(_opacity(tester), 0);
    await fixture.close(tester);
  });

  for (final sample in [
    (const Size(320, 640), 2.0),
    (const Size(640, 320), 2.0),
    (const Size(1024, 768), 1.0),
  ]) {
    testWidgets('player controls fit ${sample.$1} at text scale ${sample.$2}', (
      tester,
    ) async {
      final fixture = await _mount(
        tester,
        accessible: true,
        size: sample.$1,
        textScale: sample.$2,
      );
      for (final tooltip in ['上一集', '暂停', '下一集 · 第 3 集', '播放倍速']) {
        final button = find.byTooltip(tooltip);
        final rect = tester.getRect(button);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(sample.$1.width));
        expect(rect.bottom, lessThanOrEqualTo(sample.$1.height));
      }
      expect(find.text('选集').hitTestable(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PlayerTransport),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('下一集 · 第 3 集'));
      await tester.pumpAndSettle();
      expect(fixture.native.sources.last['uri'], 'file:///tmp/cast-three.mp4');
      expect(tester.takeException(), isNull);
      await fixture.close(tester);
    });
  }

  testWidgets('background disables explicit episode and transport actions', (
    tester,
  ) async {
    final fixture = await _mount(tester, accessible: true);
    final old = tester.widget<PlayerTransport>(find.byType(PlayerTransport));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    old.onNext!();
    old.onEpisodes();
    final plays = fixture.native.plays;
    old.onPlay();
    await tester.pumpAndSettle();
    expect(
      tester.widget<EpisodePager>(find.byType(EpisodePager)).controller.page,
      0,
    );
    expect(find.byType(PlayerEpisodeSheet), findsNothing);
    expect(fixture.native.plays, plays);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一集 · 第 3 集'));
    await tester.pumpAndSettle();
    expect(fixture.native.sources.last['uri'], 'file:///tmp/cast-three.mp4');
    await fixture.close(tester);
  });

  testWidgets(
    'assistive navigation can unlock without applying locked callbacks',
    (tester) async {
      final fixture = await _mount(tester, accessible: true);
      final old = tester.widget<PlayerTransport>(find.byType(PlayerTransport));
      await tester.tap(find.byTooltip('更多播放设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('锁定手势'));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0);
      old.onNext!();
      old.onEpisodes();
      final pauses = fixture.native.pauses;
      old.onPlay();
      await tester.pumpAndSettle();
      expect(fixture.native.pauses, pauses);
      expect(
        tester.widget<EpisodePager>(find.byType(EpisodePager)).controller.page,
        0,
      );
      expect(find.byType(PlayerEpisodeSheet), findsNothing);
      final video = find.semantics.byLabel('视频画面').evaluate().single;
      expect(video.getSemanticsData().hasAction(ui.SemanticsAction.tap), false);
      tester.semantics.tap(_tooltip('解锁手势'));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
      expect(_tooltip('暂停'), findsOne);
      await fixture.close(tester);
    },
  );

  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture CJK player phone, landscape, tablet and TV controls', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (FontLoader('sans-serif')..addFont(
            Future.value(ByteData.sublistView(await File(font!).readAsBytes())),
          ))
          .load();
      final icons = Platform.environment['GUOGUO_ICON_FONT'];
      if (icons != null) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(icons).readAsBytes()),
              ),
            ))
            .load();
      }
      await Directory('build/player-previews').create(recursive: true);
    });
    for (final sample in [
      (const Size(390, 844), 1.0, 'phone'),
      (const Size(320, 640), 2.0, 'small-large-text'),
      (const Size(640, 320), 2.0, 'landscape-large-text'),
      (const Size(1024, 768), 1.0, 'tablet'),
      (const Size(1280, 720), 1.0, 'television'),
      (const Size(960, 540), 1.5, 'television-large-text'),
    ]) {
      for (final brightness in Brightness.values) {
        final key = GlobalKey();
        final fixture = await _mount(
          tester,
          accessible: true,
          television: sample.$3.startsWith('television'),
          size: sample.$1,
          textScale: sample.$2,
          brightness: brightness,
          previewKey: key,
        );
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/player-previews/${sample.$3}-${brightness.name}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        await fixture.close(tester);
      }
    }
  }, skip: font == null);
}
