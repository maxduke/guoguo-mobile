import 'package:guoguo_mobile/ui/player_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/player_gestures.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  testWidgets(
    'failed player keeps exit and episode controls visible within safe areas',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(
              'dev.fluttercommunity.plus/connectivity_status',
            ),
            (_) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'dev.fluttercommunity.plus/connectivity_status',
              ),
              null,
            ),
      );
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      final downloads = DownloadStore(store);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44, bottom: 34),
            ),
            child: PlayerPage(
              store: store,
              downloads: downloads,
              drama: const Drama(
                id: '1',
                source: DramaSource.hongguo,
                title: '一部长标题短剧用于检查安全区域与控制条',
              ),
              episodes: [
                Episode.fromJson({'id': '1'}, 0),
              ],
              initialIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
      await tester.tapAt(const Offset(195, 300));
      // A single tap responds without waiting for a possible double tap.
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.byTooltip('返回')).dy,
        greaterThanOrEqualTo(44),
      );
      expect(tester.getTopLeft(find.byKey(const Key('playerTopChrome'))).dy, 0);
      expect(
        tester.getBottomRight(find.byKey(const Key('playerBottomChrome'))).dy,
        844,
      );
      expect(
        tester.getBottomRight(find.byType(PlayerTransport)).dy,
        lessThanOrEqualTo(810),
      );
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(195, 300));
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
  testWidgets('landscape chrome fills edges while controls respect insets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const status = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(status, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(status, null));
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..offline = true;
    final downloads = DownloadStore(store);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(844, 390),
            padding: EdgeInsets.only(left: 44, right: 44, bottom: 21),
            viewPadding: EdgeInsets.only(left: 44, right: 44, bottom: 21),
          ),
          child: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: '1',
              source: DramaSource.hongguo,
              title: '横屏',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
            ],
            initialIndex: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(420, 180));
    await tester.pump();
    expect(tester.getRect(find.byKey(const Key('playerTopChrome'))).top, 0);
    expect(
      tester.getRect(find.byKey(const Key('playerBottomChrome'))).bottom,
      390,
    );
    expect(tester.getRect(find.byKey(const Key('playerBottomChrome'))).left, 0);
    expect(
      tester.getTopLeft(find.byTooltip('返回')).dx,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getBottomRight(find.byType(PlayerTransport)).dy,
      lessThanOrEqualTo(369),
    );
    expect(
      tester.getBottomRight(find.byType(PlayerTransport)).dx,
      lessThanOrEqualTo(800),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    store.dispose();
  });
  testWidgets('home gesture origin cannot turn an episode', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const status = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(status, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(status, null));
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..offline = true;
    final downloads = DownloadStore(store);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(bottom: 34),
            viewPadding: EdgeInsets.only(bottom: 34),
            systemGestureInsets: EdgeInsets.only(bottom: 34),
          ),
          child: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: '1',
              source: DramaSource.hongguo,
              title: '滑动',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
              Episode.fromJson({'id': '2'}, 1),
            ],
            initialIndex: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pager = tester
        .widget<EpisodePager>(find.byType(EpisodePager))
        .controller;
    expect(
      tester.getRect(find.byKey(const Key('playerHomeGestureGuard'))),
      const Rect.fromLTWH(0, 810, 390, 34),
    );
    final homeSwipe = await tester.startGesture(const Offset(195, 830));
    await homeSwipe.moveBy(const Offset(0, -500));
    await homeSwipe.up();
    await tester.pumpAndSettle();
    expect(pager.page, 0);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    final normalSwipe = await tester.startGesture(const Offset(350, 600));
    await normalSwipe.moveBy(const Offset(0, -220));
    await tester.pump();
    await normalSwipe.moveBy(const Offset(0, -220));
    await tester.pump();
    expect(pager.page, greaterThan(0));
    await normalSwipe.moveBy(const Offset(0, -300));
    await normalSwipe.up();
    await tester.pumpAndSettle();
    expect(pager.page, 1);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    store.dispose();
  });
  testWidgets(
    'holding accelerates without seeking on movement; release and cancel restore speed',
    (tester) async {
      final seeks = <double>[];
      final boosts = <bool>[];
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerGestures(
            position: () => 50000,
            duration: () => 100000,
            onSeek: seeks.add,
            onBoost: boosts.add,
            onScrub: (_) {},
            onTap: () => taps++,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 600));
      expect(boosts, [true]);
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump();
      expect(boosts, [true]);
      expect(seeks, isEmpty);
      expect(find.text('2 倍速 · 松手恢复'), findsOneWidget);
      expect(find.textContaining('松手跳转'), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(boosts, [true, false]);
      expect(seeks, isEmpty);
      expect(taps, 0);
      final cancelled = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 600));
      await cancelled.cancel();
      await tester.pump();
      expect(boosts.last, false);
      expect(seeks, isEmpty);
      await tester.drag(find.byType(PlayerGestures), const Offset(2000, 0));
      await tester.pump();
      expect(seeks.last, 100000);
      expect(seeks, hasLength(1));
      expect(taps, 0);
    },
  );
  testWidgets(
    'vertical paging tracks the finger and settles onto the next episode',
    (tester) async {
      final pages = PageController();
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerGestures(
            position: () => 10000,
            duration: () => 100000,
            onSeek: (_) => fail('vertical swiping must not seek'),
            onBoost: (_) => fail('vertical swiping must not boost'),
            onScrub: (_) {},
            onTap: () => fail('vertical swiping must not toggle controls'),
            child: EpisodePager(
              controller: pages,
              count: 3,
              onChanged: (index) => selected = index,
              builder: (context, index) => ColoredBox(
                color: Colors.black,
                child: Center(child: Text('episode$index')),
              ),
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(const Offset(400, 450));
      await drag.moveBy(const Offset(0, -150));
      await tester.pump();
      await drag.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(pages.page, greaterThan(0));
      expect(pages.page, lessThan(1));
      await drag.moveBy(const Offset(0, -200));
      await drag.up();
      await tester.pumpAndSettle();
      expect(selected, 1);
      await tester.pumpWidget(const SizedBox());
      pages.dispose();
    },
  );
  testWidgets(
    'transport fits a small phone and seeks only after scrub release',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final seeks = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PlayerTransport(
                duration: 100000,
                position: 1000,
                playing: true,
                enabled: true,
                speed: 1,
                onPlay: () {},
                onEpisodes: () {},
                onSpeed: (_) {},
                onScrub: (_) {},
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + 40, rect.center.dy),
      );
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(seeks, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(seeks, hasLength(1));
      expect(seeks.single, greaterThan(1000));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('horizontal video swipe previews and seeks once', (tester) async {
    final seeks = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerGestures(
          position: () => 50000,
          duration: () => 100000,
          onSeek: seeks.add,
          onBoost: (_) {},
          onScrub: (_) {},
          onTap: () {},
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(seeks, isEmpty);
    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(50000));
  });
}
