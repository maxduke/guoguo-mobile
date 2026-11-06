import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/catalog_topic.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/search_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'package:guoguo_mobile/ui/topic_browser.dart';

class _Request {
  _Request(this.method, this.args);
  final String method;
  final Map<String, dynamic> args;
  final result = Completer<Map<String, dynamic>>();
}

class _Provider implements ProviderClient {
  final requests = <_Request>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    final request = _Request(method, Map.of(args));
    requests.add(request);
    if (method == 'cancelCatalog') request.result.complete({});
    return request.result.future;
  }
}

Map<String, dynamic> _page(List<Drama> rows, {bool more = false}) => {
  'items': rows.map((row) => row.toJson()).toList(),
  'hasMore': more,
};

void main() {
  Future<({AppStore store, _Provider provider})> fixture(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      for (final request in provider.requests) {
        if (!request.result.isCompleted) request.result.complete({'items': []});
      }
      await tester.pump();
      store.dispose();
    });
    return (store: store, provider: provider);
  }

  Widget app(Widget home) =>
      MaterialApp(theme: guoguoTheme(Brightness.light), home: home);

  testWidgets(
    'search topics browse saved tags without issuing title searches or changing source',
    (tester) async {
      final f = await fixture(tester);
      await f.store.catalog.selectSource(DramaSource.huangguo);
      f.store.catalog.sourceCategories[DramaSource.huangguo] = const [
        SourceCategory('ai-duanju', 'AI成人短剧'),
      ];
      f.store.catalog.catalogs[DramaSource.huangguo] = const [
        Drama(
          id: '1',
          source: DramaSource.huangguo,
          title: '故乡来信',
          tags: ['治愈'],
        ),
        Drama(
          id: '2',
          source: DramaSource.huangguo,
          title: '治愈之旅',
          tags: ['都市'],
        ),
      ];
      await tester.pumpWidget(
        app(SearchPage(store: f.store, onOpen: (_) {}, autofocus: false)),
      );
      await tester.pumpAndSettle();
      expect(f.provider.requests, isEmpty);
      await tester.tap(find.widgetWithText(ActionChip, '治愈'));
      await tester.pumpAndSettle();
      expect(find.byType(TopicBrowserPage), findsOneWidget);
      expect(find.text('已保存资料 · 1 部'), findsOneWidget);
      expect(
        tester
            .widgetList<DramaCard>(find.byType(DramaCard))
            .map((card) => card.drama.title),
        ['故乡来信'],
      );
      expect(f.provider.requests, isEmpty);
      expect(f.store.catalog.source, DramaSource.huangguo);
    },
  );

  testWidgets(
    'real category navigation pages and retries in its own source without touching global filters',
    (tester) async {
      final f = await fixture(tester);
      f.store.catalog.sourceCategories[DramaSource.yeguo] = const [
        SourceCategory('city', '都市'),
      ];
      const first = Drama(id: '1', source: DramaSource.yeguo, title: '山海');
      const second = Drama(id: '2', source: DramaSource.yeguo, title: '归期');
      await tester.pumpWidget(
        app(
          TopicBrowserPage(
            store: f.store,
            source: DramaSource.yeguo,
            topic: const CatalogTopic('都市', categoryId: 'city'),
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(f.provider.requests.single.args['source'], 'yeguo');
      expect(f.provider.requests.single.args['category'], 'city');
      f.provider.requests.single.result.complete(_page([first], more: true));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('加载更多'), 180);
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      final failed = f.provider.requests.last;
      expect(failed.args['page'], 2);
      failed.result.completeError(
        const ProviderException('private-token must not be shown'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('private-token'), findsNothing);
      await tester.ensureVisible(find.text('重试分类'));
      await tester.tap(find.text('重试分类'));
      await tester.pump();
      expect(f.provider.requests.last.args['page'], 2);
      f.provider.requests.last.result.complete(_page([first, second]));
      await tester.pumpAndSettle();
      expect(find.text('站源分类 · 已加载 2 部'), findsOneWidget);
      expect(f.store.catalog.source, DramaSource.hongguo);
      expect(f.store.catalog.selectedCategories, isEmpty);
      expect(
        f.store.catalog.cachedDramas(DramaSource.yeguo).map((row) => row.id),
        ['1', '2'],
      );
    },
  );

  testWidgets(
    'Huangguo exposes real online channels and remembers browsed metadata',
    (tester) async {
      final f = await fixture(tester);
      await f.store.catalog.selectSource(DramaSource.huangguo);
      await tester.pumpWidget(
        app(SearchPage(store: f.store, onOpen: (_) {}, autofocus: false)),
      );
      await tester.pumpAndSettle();
      expect(f.provider.requests, isEmpty);
      await tester.tap(find.text('浏览站源分类'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final categories = f.provider.requests.single;
      expect(categories.method, 'categories');
      expect(categories.args['source'], 'huangguo');
      categories.result.complete({
        'items': [
          {'id': '', 'name': '全部'},
          {'id': 'ai-manju', 'name': 'AI成人漫剧'},
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'AI成人漫剧'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final catalog = f.provider.requests.last;
      expect(catalog.method, 'catalog');
      expect(catalog.args['source'], 'huangguo');
      expect(catalog.args['category'], 'ai-manju');
      expect(catalog.args['page'], 1);
      const drama = Drama(
        id: 'huangguoai:501',
        source: DramaSource.huangguo,
        title: '山海来信',
        category: 'AI成人漫剧',
        tags: ['都市'],
      );
      catalog.result.complete(_page([drama], more: true));
      await tester.pumpAndSettle();
      expect(find.text('站源分类 · 已加载 1 部'), findsOneWidget);
      expect(f.store.catalog.source, DramaSource.huangguo);
      expect(f.store.catalog.selectedCategories, isEmpty);
      expect(
        f.store.catalog.cachedDramas(DramaSource.huangguo).single.id,
        drama.id,
      );
      expect(f.store.catalog.cacheSnapshot()['catalogs'], contains('huangguo'));
      f.store.offline = true;
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, 'AI成人漫剧'));
      await tester.pumpAndSettle();
      expect(find.text('已保存资料 · 1 部'), findsOneWidget);
      expect(
        f.provider.requests.where((r) => r.method == 'catalog'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'leaving a pending topic cancels the matching request and ignores late rows',
    (tester) async {
      final f = await fixture(tester);
      await tester.pumpWidget(
        app(
          TopicBrowserPage(
            store: f.store,
            source: DramaSource.yeguo,
            topic: const CatalogTopic('都市', categoryId: 'city'),
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pump();
      final pending = f.provider.requests.single;
      await tester.pumpWidget(app(const Scaffold(body: Text('离开了'))));
      await tester.pump();
      final cancel = f.provider.requests.last;
      expect(cancel.method, 'cancelCatalog');
      expect(cancel.args['requestId'], pending.args['requestId']);
      expect(cancel.args['category'], 'city');
      expect(cancel.args['source'], 'yeguo');
      pending.result.complete(
        _page(const [
          Drama(id: 'late', source: DramaSource.yeguo, title: '迟到内容'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('离开了'), findsOneWidget);
      expect(f.store.catalog.catalogs[DramaSource.yeguo], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'category picker reads real source IDs only after opening and handles keyboard with large text',
    (tester) async {
      final f = await fixture(tester);
      tester.view.physicalSize = const Size(320, 568);
      await f.store.catalog.selectSource(DramaSource.yeguo);
      await tester.pumpWidget(
        MaterialApp(
          theme: guoguoTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 200),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TopicShortcuts(
                store: f.store,
                source: DramaSource.yeguo,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.provider.requests, isEmpty);
      await tester.ensureVisible(find.text('浏览站源分类'));
      await tester.tap(find.text('浏览站源分类'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final request = f.provider.requests.single;
      expect(request.method, 'categories');
      request.result.complete({
        'items': [
          {'id': 'real-cat-id', 'name': '古风'},
        ],
      });
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('古风'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('古风'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final catalog = f.provider.requests.last;
      expect(catalog.method, 'catalog');
      expect(catalog.args['category'], 'real-cat-id');
      catalog.result.complete(_page([]));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail tags open the drama source and preserve an unrelated browsing source',
    (tester) async {
      final f = await fixture(tester);
      f.store.offline = true;
      const drama = Drama(
        id: 'saved',
        source: DramaSource.huangguo,
        title: '故乡来信',
        tags: ['治愈'],
      );
      f.store.catalog.catalogs[DramaSource.huangguo] = [drama];
      final downloads = DownloadStore(f.store)..manifestLoaded = true;
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        app(DetailPage(store: f.store, downloads: downloads, drama: drama)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('浏览题材：治愈'));
      await tester.tap(find.byTooltip('浏览题材：治愈'));
      await tester.pumpAndSettle();
      expect(find.byType(TopicBrowserPage), findsOneWidget);
      expect(find.text('黄果'), findsWidgets);
      expect(f.store.catalog.source, DramaSource.hongguo);
      expect(f.provider.requests, isEmpty);
    },
  );

  testWidgets(
    'opening a tag waits for an existing category read before resolving its real ID',
    (tester) async {
      final f = await fixture(tester);
      final existing = f.store.catalog.loadCategories(DramaSource.yeguo);
      final categories = f.provider.requests.single;
      await tester.pumpWidget(
        app(
          TopicBrowserPage(
            store: f.store,
            source: DramaSource.yeguo,
            topic: const CatalogTopic('都市'),
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(f.provider.requests, hasLength(1));
      categories.result.complete({
        'items': [
          {'id': 'city-shared', 'name': '都市'},
        ],
      });
      await existing;
      await tester.pump();
      expect(f.provider.requests, hasLength(2));
      expect(f.provider.requests.last.args['category'], 'city-shared');
      f.provider.requests.last.result.complete(_page([]));
      await tester.pumpAndSettle();
      expect(f.store.catalog.source, DramaSource.hongguo);
    },
  );

  testWidgets(
    'a warning after refreshing clears the previous next-page retry intent',
    (tester) async {
      final f = await fixture(tester);
      const first = Drama(id: '1', source: DramaSource.yeguo, title: '归期');
      await tester.pumpWidget(
        app(
          TopicBrowserPage(
            store: f.store,
            source: DramaSource.yeguo,
            topic: const CatalogTopic('都市', categoryId: 'city'),
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pump();
      f.provider.requests.last.result.complete(_page([first], more: true));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('加载更多'));
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      f.provider.requests.last.result.completeError(
        const ProviderException('failed'),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('刷新分类'));
      await tester.tap(find.text('刷新分类'));
      await tester.pump();
      f.provider.requests.last.result.complete({
        ..._page([first]),
        'warning': '部分结果',
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重试分类'));
      await tester.tap(find.text('重试分类'));
      await tester.pump();
      expect(f.provider.requests.last.args['page'], 1);
      f.provider.requests.last.result.complete(_page([first]));
      await tester.pumpAndSettle();
    },
  );
}
