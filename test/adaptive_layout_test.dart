import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_startup.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/discovery_page.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/personal_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/search_page.dart';
import 'package:guoguo_mobile/ui/television_grid.dart';
import 'package:guoguo_mobile/ui/discovery_cache_status.dart';

import 'widget_test.dart' show NoNetwork;

class _Downloads extends DownloadStore {
  _Downloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}

void main() {
  late AppStore store;
  late DownloadStore downloads;
  AppStartup? startupOwner;
  setUp(() {
    store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
    downloads = _Downloads(store);
    startupOwner = null;
  });
  tearDown(() {
    if (startupOwner != null) {
      startupOwner!.dispose();
    } else {
      downloads.dispose();
      store.dispose();
    }
  });

  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> mount(
    WidgetTester tester, {
    AppStartup? startup,
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        theme: guoguoTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: HomePage(
          store: store,
          downloads: downloads,
          startup: startup,
          autoLoad: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'small large-text home shows content and can expand cache details',
    (tester) async {
      store.offline = true;
      const title = '一部需要两行显示的长剧名与它的后续故事';
      final savedAt = store.now();
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        const [
          Drama(
            id: 'large-text',
            source: DramaSource.hongguo,
            title: title,
            episodes: 80,
          ),
        ],
        savedAt,
      );
      await mount(tester, size: const Size(320, 640), scale: 2);
      final discovery = find.byType(DiscoveryPage);
      final grid = tester.widget<TelevisionGrid>(
        find.descendant(of: discovery, matching: find.byType(TelevisionGrid)),
      );
      expect(grid.columns, 1);
      final poster = find.descendant(
        of: find.byType(DramaCard),
        matching: find.byType(Poster),
      );
      final viewport = find.descendant(
        of: discovery,
        matching: find.byType(CustomScrollView),
      );
      expect(
        tester.getTopLeft(poster).dy,
        lessThan(tester.getBottomLeft(viewport).dy - 48),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == title && w.maxLines == 2,
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('完整剧库').hitTestable(), findsOneWidget);
      expect(find.text('来自红果的公开推荐'), findsNothing);
      final details = find.descendant(
        of: find.byType(DiscoveryCacheStatus),
        matching: find.byType(ExpansionTile),
      );
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('来自红果的公开推荐'), findsOneWidget);
      expect(
        find.text('上次获取 ${formatDiscoveryTimestamp(savedAt)}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide and split windows keep selected navigation and page state',
    (tester) async {
      store.offline = true;
      store.catalog.source = DramaSource.huangdou;
      store.records.restore(
        RecordBackup(
          List.generate(
            20,
            (i) => Drama(
              id: '$i',
              source: DramaSource.hongguo,
              title: '很长的故事剧名 $i',
            ),
          ),
          [],
        ),
        {},
      );
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        store.records.favorites.values.take(6).toList(),
        store.now(),
      );
      await mount(tester);
      final downloadPage = tester.state(
        find.byType(DownloadsPage, skipOffstage: false),
      );
      await tester.tap(find.text('追剧').last);
      await tester.pumpAndSettle();
      final personal = tester.state(find.byType(PersonalPage));
      final discovery = tester.state(
        find.byType(DiscoveryPage, skipOffstage: false),
      );
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(PersonalPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      scroll.jumpTo(200);
      await tester.pump();
      await resize(tester, const Size(1024, 768));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        1,
      );
      expect(tester.state(find.byType(PersonalPage)), same(personal));
      expect(
        tester.state(find.byType(DiscoveryPage, skipOffstage: false)),
        same(discovery),
      );
      expect(scroll.pixels, 200);
      expect(store.catalog.source, DramaSource.huangdou);
      expect(
        tester
            .widget<DiscoveryPage>(
              find.byType(DiscoveryPage, skipOffstage: false),
            )
            .source,
        DramaSource.huangdou,
      );
      await resize(tester, const Size(500, 768));
      expect(find.byType(NavigationRail), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      expect(tester.state(find.byType(PersonalPage)), same(personal));
      expect(scroll.pixels, 200);
      expect(store.catalog.source, DramaSource.huangdou);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('下载').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成 0'));
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('全部站源 · 已完成 · 最近添加'), findsOneWidget);
      for (final size in [const Size(1024, 768), const Size(500, 768)]) {
        await resize(tester, size);
        expect(tester.state(find.byType(DownloadsPage)), same(downloadPage));
        expect(find.text('全部站源 · 已完成 · 最近添加'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'concurrent startup and persistence notices leave a usable short landscape body',
    (tester) async {
      store.offline = true;
      store.persistenceError = '记录暂未保存，请检查可用空间后重试';
      store.cachePersistenceError = '目录缓存暂未保存，请检查可用空间后重试';
      final startup =
          AppStartup(
              store: store,
              downloads: downloads,
              initializeCore: () async {},
              checkOffline: () async => true,
              offlineChanges: const Stream.empty(),
            )
            ..coreError = '站源连接暂未就绪，可浏览已有记录，请重试'
            ..networkError = '网络状态暂时无法获取，可继续浏览，请重试';
      startupOwner = startup;
      await mount(
        tester,
        startup: startup,
        size: const Size(740, 320),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(IndexedStack).hitTestable(), findsOneWidget);
      final notices = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text(store.cachePersistenceError!).hitTestable(),
        60,
        scrollable: notices,
      );
      expect(
        find.text(store.cachePersistenceError!).hitTestable(),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('重试网络').hitTestable(),
        -60,
        scrollable: notices,
      );
      expect(find.text('重试网络').hitTestable(), findsOneWidget);
      await tester.tap(find.text('追剧').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(PersonalPage).hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'card actions announce the full drama without decorative poster text',
    (tester) async {
      const drama = Drama(
        id: 'long',
        source: DramaSource.hongguo,
        title: '很长的故事名称用于确认读屏能识别完整作品',
        episodes: 120,
        vip: true,
      );
      var opened = 0, favorited = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 180,
              height: 300,
              child: DramaCard(
                drama: drama,
                favorite: false,
                onTap: () => opened++,
                onFavorite: () => favorited++,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final details = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '${drama.title}，打开详情',
      );
      expect(
        tester.getSemantics(details),
        isSemantics(
          label: '${drama.title}，打开详情',
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byTooltip('收藏 ${drama.title}')),
        isSemantics(
          tooltip: '收藏 ${drama.title}',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(details);
      await tester.tap(find.byTooltip('收藏 ${drama.title}'));
      expect(opened, 1);
      expect(favorited, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search empty content remains reachable above a large keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.offline = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: guoguoTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            viewInsets: const EdgeInsets.only(bottom: 280),
          ),
          child: child!,
        ),
        home: SearchPage(store: store, onOpen: (_) {}, autofocus: false),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '一个很长的查询词');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.byTooltip('清空搜索').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('暂时没有找到').hitTestable(),
      100,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('暂时没有找到').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 640),
    const Size(1024, 768),
    const Size(1024, 320),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('navigation targets fit $size at 2x in $brightness', (
        tester,
      ) async {
        await mount(tester, size: size, scale: 2, brightness: brightness);
        expect(
          find.byType(NavigationRail),
          size.height >= 480 && size.width >= 900
              ? findsOneWidget
              : findsNothing,
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await tester.tap(find.text('下载').last);
        await tester.pumpAndSettle();
        expect(find.text('我的下载'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
