import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/discovery_cache.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/search_page.dart';
import 'package:guoguo_mobile/ui/source_selector.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';

Drama _drama(
  String id, {
  DramaSource source = DramaSource.hongguo,
  String? title,
  String category = '',
}) =>
    Drama(id: id, source: source, title: title ?? '结果$id', category: category);

Map<String, dynamic> _page(List<Drama> items, {bool more = false}) => {
  'items': items.map((item) => item.toJson()).toList(),
  'hasMore': more,
};

class _Request {
  _Request(this.args);
  final Map<String, dynamic> args;
  final result = Completer<Map<String, dynamic>>();
}

class _Provider implements ProviderClient {
  final searches = <_Request>[];
  final suggestions = <_Request>[];
  final cancellations = <Map<String, dynamic>>[];
  List<Drama> partial = [];
  final catalogs = <DramaSource, List<Drama>>{};
  int polls = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (method == 'search' || method == 'suggestions') {
      final request = _Request(args);
      (method == 'search' ? searches : suggestions).add(request);
      return request.result.future;
    }
    if (method == 'searchProgress') {
      polls++;
      return Future.value({
        ..._page(partial),
        'source': args['source'],
        'query': args['query'],
      });
    }
    if (method == 'catalog') {
      return Future.value(
        _page(catalogs[DramaSource.parse(args['source'])] ?? []),
      );
    }
    if (method == 'cancelSearch') cancellations.add(args);
    return Future.value({'items': []});
  }
}

class _FailingStorage extends MemoryStorage implements PartitionedStorage {
  bool failRecords = false, failCache = false;
  @override
  String? get cacheReadError => null;
  @override
  Future<void> writeRecords(Map<String, dynamic> value) async {
    if (failRecords) throw StateError('disk full');
    await super.write(value);
  }

  @override
  Future<void> writeCache(Map<String, dynamic> value) async {
    if (failCache) throw StateError('disk full');
  }
}

Future<({AppStore store, _Provider provider})> _mount(
  WidgetTester tester, {
  DramaSource source = DramaSource.hongguo,
  bool offline = false,
  Size size = const Size(1400, 1800),
  LocalStorage? storage,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = _Provider();
  final store = AppStore(
    storage: storage ?? MemoryStorage(),
    provider: provider,
  )..offline = offline;
  await store.catalog.selectSource(source);
  store.catalog.catalogs[source] = [
    _drama('local', source: source, title: '目标缓存', category: '分类'),
  ];
  provider.catalogs[source] = store.catalog.catalogs[source]!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final request in [...provider.searches, ...provider.suggestions]) {
      if (!request.result.isCompleted) request.result.complete({'items': []});
    }
    await tester.pump();
    store.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: SearchPage(store: store, onOpen: (_) {}, autofocus: false),
    ),
  );
  await tester.pumpAndSettle();
  return (store: store, provider: provider);
}

Future<void> _submit(WidgetTester tester, [String query = '故事']) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

Future<void> _finish(
  WidgetTester tester,
  _Request request,
  List<Drama> items, {
  bool more = false,
}) async {
  request.result.complete(_page(items, more: more));
  await tester.pumpAndSettle();
}

List<String> _ids(WidgetTester tester) => tester
    .widgetList<DramaCard>(find.byType(DramaCard))
    .map((card) => card.drama.id)
    .toList();

void main() {
  testWidgets(
    'online input waits for submission and distinguishes failure from no results',
    (tester) async {
      final (:provider, store: _) = await _mount(tester);
      await tester.enterText(find.byType(TextField), '没有本地匹配的故事');
      await tester.pump(const Duration(milliseconds: 300));
      expect(provider.searches, isEmpty);
      expect(find.text('搜索当前站源'), findsOneWidget);
      expect(find.text('暂时没有找到'), findsNothing);
      provider.suggestions.single.result.completeError(
        StateError('suggestion unavailable'),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索当前站源'), findsOneWidget);
      await tester.tap(find.byTooltip('联网搜索'));
      await tester.pump();
      expect(find.text('正在搜索…'), findsOneWidget);
      expect(find.text('暂时没有找到'), findsNothing);
      provider.searches.single.result.completeError(
        StateError('search unavailable'),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索未完成'), findsOneWidget);
      expect(find.text('暂时没有找到'), findsNothing);
      await tester.tap(find.text('重试搜索'));
      await tester.pump();
      await _finish(tester, provider.searches.last, []);
      expect(find.text('暂时没有找到'), findsOneWidget);
      expect(find.text('搜索未完成'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('expired continuation preserves results and restarts on retry', (
    tester,
  ) async {
    final (:provider, :store) = await _mount(tester);
    await _submit(tester);
    provider.searches.single.result.complete({
      ..._page([_drama('A')], more: true),
      'limited': true,
      'continuation': 'cursor-first',
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多结果'));
    await tester.pump();
    expect(provider.searches.last.args['continuation'], 'cursor-first');
    provider.searches.last.result.complete({
      'items': [],
      'limited': true,
      'restartRequired': true,
      'warning': '续搜已过期，请重新搜索',
    });
    await tester.pumpAndSettle();
    expect(_ids(tester), ['A']);
    expect(find.text('续搜已过期，请重新搜索'), findsOneWidget);
    await tester.tap(find.text('重试搜索'));
    await tester.pump();
    expect(provider.searches.last.args['page'], 1);
    expect(provider.searches.last.args['continuation'], isNull);
    await _finish(tester, provider.searches.last, [_drama('B')]);
    expect(_ids(tester), ['B']);
    expect(store.catalog.searchCache.dramas.map((d) => d.id), ['B']);
  });

  testWidgets('empty season page keeps its next cursor and prior results', (
    tester,
  ) async {
    final (:provider, :store) = await _mount(tester);
    await _submit(tester);
    provider.searches.single.result.complete({
      ..._page([_drama('A')], more: true),
      'continuation': 'cursor-first',
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多结果'));
    await tester.pump();
    provider.searches.last.result.complete({
      ..._page([], more: true),
      'limited': true,
      'continuation': 'cursor-second',
    });
    await tester.pumpAndSettle();
    expect(_ids(tester), ['A']);
    expect(find.text('加载更多结果'), findsOneWidget);
    await tester.tap(find.text('加载更多结果'));
    await tester.pump();
    expect(provider.searches.last.args['continuation'], 'cursor-second');
    expect(provider.searches.last.args['page'], 3);
    await _finish(tester, provider.searches.last, [_drama('B')]);
    expect(_ids(tester), ['A', 'B']);
    expect(
      store.catalog.searchCache.toJson().toString(),
      isNot(contains('cursor-second')),
    );
  });

  for (final recordFailure in [true, false]) {
    testWidgets(
      '${recordFailure ? 'record' : 'cache'} saving failure preserves search results and the next-page cursor',
      (tester) async {
        final storage = _FailingStorage();
        final (:provider, :store) = await _mount(tester, storage: storage);
        storage.failRecords = recordFailure;
        storage.failCache = !recordFailure;
        await _submit(tester);
        await _finish(tester, provider.searches.single, [
          _drama('A'),
        ], more: true);
        expect(_ids(tester), ['A']);
        expect(find.text('搜索暂时失败，请检查网络后重试'), findsNothing);
        expect(find.text('重试搜索'), findsNothing);
        expect(
          find.text(
            recordFailure
                ? store.persistenceError!
                : store.cachePersistenceError!,
          ),
          findsOneWidget,
        );
        storage.failRecords = storage.failCache = false;
        await tester.tap(find.text('加载更多结果'));
        await tester.pump();
        expect(provider.searches.last.args['page'], 2);
        await _finish(tester, provider.searches.last, [_drama('B')]);
        expect(_ids(tester), ['A', 'B']);
        expect(store.persistenceError, isNull);
        expect(store.cachePersistenceError, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'fresh cached results are identified and remember the query again after clearing history',
    (tester) async {
      final (:provider, :store) = await _mount(tester);
      store.catalog.searchCache.put(
        'hongguo|缓存|1',
        CatalogSearchResult([_drama('cached', title: '缓存故事')]),
        store.now(),
      );
      await _submit(tester, '缓存');
      await tester.pumpAndSettle();
      expect(_ids(tester), ['cached']);
      expect(find.text('本页来自缓存'), findsOneWidget);
      expect(provider.searches, isEmpty);
      expect(store.catalog.recentSearches, ['缓存']);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(find.text('最近搜索'), findsOneWidget);
      await tester.tap(find.byTooltip('清除搜索记录'));
      await tester.pumpAndSettle();
      expect(store.catalog.recentSearches, isEmpty);
      await _submit(tester, '缓存');
      await tester.pumpAndSettle();
      expect(store.catalog.recentSearches, ['缓存']);
      expect(provider.searches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline search includes saved source-scoped catalog, search, column and record metadata',
    (tester) async {
      final (:provider, :store) = await _mount(tester, offline: true);
      store.catalog.searchCache.put(
        'hongguo|旧词|1',
        CatalogSearchResult([
          store.catalog.library.single,
          _drama('search', title: '目标搜索缓存'),
        ]),
        store.now(),
      );
      for (final source in [DramaSource.hongguo, DramaSource.huangguo]) {
        store.catalog.discoveryCache.putRanking(
          source,
          'a',
          CachedDiscoveryColumn(
            [
              DiscoveryRow(
                _drama(
                  source == DramaSource.hongguo ? 'column' : 'foreign',
                  source: source,
                  title: '目标栏目',
                ),
              ),
            ],
            savedAt: store.now(),
            kind: DiscoveryKind.catalog,
          ),
        );
      }
      await store.records.toggleFavorite(_drama('favorite', title: '目标收藏'));
      await store.records.saveWatch(
        WatchRecord(
          drama: _drama('history', title: '目标历史'),
          episodeId: 'e1',
          episodeIndex: 0,
          positionMs: 1000,
          durationMs: 10000,
          updatedAt: store.now(),
        ),
      );
      await _submit(tester, '目标');
      await tester.pumpAndSettle();
      expect(_ids(tester), [
        'local',
        'search',
        'column',
        'favorite',
        'history',
      ]);
      expect(provider.searches, isEmpty);
      expect(store.catalog.recentSearches.first, '目标');
      await store.catalog.selectSource(DramaSource.huangguo);
      await _submit(tester, '目标');
      await tester.pumpAndSettle();
      expect(_ids(tester), ['foreign']);
      expect(provider.searches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacing the search store cancels old work and binds the new source',
    (tester) async {
      final (:provider, :store) = await _mount(tester);
      await _submit(tester);
      final previousInput = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      final replacementProvider = _Provider();
      final replacement = AppStore(
        storage: MemoryStorage(),
        provider: replacementProvider,
      );
      addTearDown(replacement.dispose);
      replacement.catalog.source = DramaSource.huangdou;
      replacement.catalog.catalogs[DramaSource.huangdou] = [
        _drama('new', source: DramaSource.huangdou, title: '目标'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            store: replacement,
            onOpen: (_) {},
            autofocus: false,
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        isNot(same(previousInput)),
      );
      provider.searches.single.result.complete(_page([_drama('late')]));
      await tester.pump(const Duration(seconds: 2));
      expect(provider.cancellations, isNotEmpty);
      expect(provider.polls, 0);
      expect(store.catalog.library.map((row) => row.id), ['local']);
      await _submit(tester, '目标');
      await tester.pumpAndSettle();
      expect(_ids(tester), ['new']);
      expect(replacementProvider.searches, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'split windows and actual details preserve search input, results and position',
    (tester) async {
      final (:provider, :store) = await _mount(
        tester,
        size: const Size(390, 844),
      );
      final downloads = DownloadStore(store);
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索剧名'));
      await tester.pumpAndSettle();
      await _submit(tester);
      await _finish(
        tester,
        provider.searches.single,
        List.generate(40, (index) => _drama('$index', title: '故事$index')),
      );
      final input = tester.widget<TextField>(find.byType(TextField)).controller;
      final page = tester.state(find.byType(SearchPage));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      scroll.jumpTo(200);
      await tester.pump();
      final position = scroll.pixels;
      expect(position, greaterThan(0));
      for (final size in [
        const Size(1024, 768),
        const Size(500, 768),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(SearchPage)), same(page));
        expect(
          tester
              .widget<TextField>(find.byType(TextField, skipOffstage: false))
              .controller,
          same(input),
        );
        expect(input!.text, '故事');
        expect(store.catalog.source, DramaSource.hongguo);
        expect(scroll.pixels, closeTo(position, .1));
        expect(_ids(tester), isNotEmpty);
        expect(provider.searches, hasLength(1));
      }
      final card = tester.widget<DramaCard>(
        find.byType(DramaCard).hitTestable().first,
      );
      card.onTap();
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      expect(input!.text, '故事');
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        closeTo(position, .1),
      );
      expect(_ids(tester), contains(card.drama.id));
      expect(provider.searches, hasLength(1));
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(input),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small search page stays usable with a keyboard, large text and long recent queries',
    (tester) async {
      final (:provider, :store) = await _mount(
        tester,
        size: const Size(320, 640),
      );
      store.catalog.recentSearches.add('用来检查较长剧名在大字号下仍然能正常显示的最近搜索');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 300),
            ),
            child: child!,
          ),
          home: SearchPage(store: store, onOpen: (_) {}, autofocus: false),
        ),
      );
      await tester.pumpAndSettle();
      await _submit(tester, '长标题');
      await _finish(tester, provider.searches.single, [
        _drama('long', title: '很长的剧名在小屏大字号下依旧可用'),
      ]);
      expect(find.byTooltip('清空搜索').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small keyboard search keeps failure and retry reachable without updating catalog',
    (tester) async {
      final (:provider, :store) = await _mount(
        tester,
        size: const Size(320, 640),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
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
      await _submit(tester);
      expect(find.text('正在搜索…'), findsOneWidget);
      expect(find.text('暂时没有找到'), findsNothing);
      expect(find.text('更新剧库'), findsNothing);
      provider.searches.single.result.completeError(
        StateError('first-page-error'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('first-page-error'), findsNothing);
      expect(find.text('更新剧库'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('重试搜索').hitTestable(),
        150,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('重试搜索').hitTestable(), findsOneWidget);
      await tester.tap(find.text('重试搜索'));
      await tester.pump();
      expect(provider.searches.map((request) => request.args['page']), [1, 1]);
      await _finish(tester, provider.searches.last, []);
      expect(find.text('暂时没有找到'), findsOneWidget);
      expect(find.text('重试搜索'), findsNothing);
      expect(find.text('更新剧库'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial and final pages retain earlier results and deduplicate',
    (tester) async {
      final (:provider, :store) = await _mount(tester);
      await _submit(tester);
      await _finish(tester, provider.searches.single, [
        _drama('A'),
        _drama('B'),
      ], more: true);
      await tester.tap(find.text('加载更多结果'));
      await tester.pump();
      provider.partial = [_drama('B'), _drama('C'), _drama('temporary')];
      await tester.pump(const Duration(milliseconds: 701));
      await tester.pump();
      expect(_ids(tester), ['A', 'B', 'C', 'temporary']);
      provider.partial = [_drama('B'), _drama('C')];
      await tester.pump(const Duration(milliseconds: 701));
      await tester.pump();
      expect(_ids(tester), ['A', 'B', 'C']);
      await _finish(tester, provider.searches.last, [
        _drama('B', title: '更新资料B'),
        _drama('D'),
      ], more: true);
      expect(_ids(tester), ['A', 'B', 'D']);
      expect(find.text('更新资料B'), findsWidgets);
      await tester.tap(find.text('加载更多结果'));
      await tester.pump();
      await _finish(tester, provider.searches.last, [_drama('E')]);
      expect(_ids(tester), ['A', 'B', 'D', 'E']);
      expect(provider.searches.map((request) => request.args['page']), [
        1,
        2,
        3,
      ]);
      expect(find.text('加载更多结果'), findsNothing);
      expect(store.catalog.recentSearches, ['故事']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final source in [DramaSource.hongguo, DramaSource.huangguo]) {
    testWidgets('${source.name} cached next page retains earlier results', (
      tester,
    ) async {
      final (:provider, :store) = await _mount(tester, source: source);
      final query = source == DramaSource.hongguo ? ' 故事 ' : '故事';
      await _submit(tester, query);
      await _finish(tester, provider.searches.single, [
        _drama('A', source: source),
        _drama('B', source: source),
      ], more: true);
      store.catalog.searchCache.put(
        '${source.name}|故事|2',
        CatalogSearchResult([
          _drama('B', source: source),
          _drama('C', source: source),
        ]),
        store.now(),
      );
      await tester.tap(find.text('加载更多结果'));
      await tester.pumpAndSettle();
      expect(_ids(tester), ['A', 'B', 'C']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        query,
      );
      expect(provider.searches, hasLength(1));
      expect(find.text('加载更多结果'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'failed next page preserves completed pages and retries that page',
    (tester) async {
      final (:provider, store: _) = await _mount(tester);
      await _submit(tester);
      await _finish(tester, provider.searches.single, [
        _drama('A'),
        _drama('B'),
      ], more: true);
      await tester.tap(find.text('加载更多结果'));
      await tester.pump();
      provider.partial = [_drama('temporary')];
      await tester.pump(const Duration(milliseconds: 701));
      await tester.pump();
      expect(_ids(tester), ['A', 'B', 'temporary']);
      provider.searches.last.result.completeError(
        StateError('raw-private-error'),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['A', 'B']);
      expect(find.text('搜索暂时失败，请检查网络后重试'), findsOneWidget);
      expect(find.textContaining('raw-private-error'), findsNothing);
      expect(find.text('正在补全结果…'), findsNothing);
      await tester.tap(find.text('重试搜索'));
      await tester.pump();
      expect(provider.searches.map((request) => request.args['page']), [
        1,
        2,
        2,
      ]);
      await _finish(tester, provider.searches.last, [_drama('C')]);
      expect(_ids(tester), ['A', 'B', 'C']);
      expect(find.text('重试搜索'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restarting the same query retries page one after failure', (
    tester,
  ) async {
    final (:provider, :store) = await _mount(tester);
    await _submit(tester);
    await _finish(tester, provider.searches.single, [_drama('A')], more: true);
    await tester.tap(find.text('加载更多结果'));
    await tester.pump();
    await _finish(tester, provider.searches.last, [_drama('B')], more: true);
    store.catalog.searchCache.put(
      'hongguo|故事|1',
      CatalogSearchResult([_drama('A')], hasMore: true),
      store.now().subtract(const Duration(hours: 1)),
    );
    await tester.tap(find.byTooltip('联网搜索'));
    await tester.pump();
    provider.searches.last.result.completeError(StateError('retry-first-page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试搜索'));
    await tester.pump();
    expect(provider.searches.map((request) => request.args['page']), [
      1,
      2,
      1,
      1,
    ]);
    await _finish(tester, provider.searches.last, [_drama('new')]);
    expect(_ids(tester), ['new']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search can be cleared while loading on a narrow screen', (
    tester,
  ) async {
    final (:provider, :store) = await _mount(
      tester,
      size: const Size(320, 844),
    );
    await _submit(tester);
    final submit = tester
        .widget<TextField>(find.byType(TextField))
        .onSubmitted!;
    submit('故事');
    await tester.pump();
    expect(provider.searches, hasLength(1));
    expect(find.byTooltip('清空搜索').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(
      provider.cancellations,
      contains(
        allOf(
          containsPair('source', provider.searches.single.args['source']),
          containsPair('query', provider.searches.single.args['query']),
          containsPair('requestId', provider.searches.single.args['requestId']),
        ),
      ),
    );
    await _finish(tester, provider.searches.single, [_drama('late')]);
    await tester.pump(const Duration(seconds: 2));
    expect(provider.polls, 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('联网结果'), findsNothing);
    expect(
      store.catalog.catalogs[DramaSource.hongguo]!.map((item) => item.id),
      ['local'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'composition, stale suggestions and caret movement keep search state',
    (tester) async {
      final (:provider, store: _) = await _mount(tester);
      final input = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      input.value = const TextEditingValue(
        text: '故',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      await tester.pump(const Duration(milliseconds: 400));
      tester.widget<TextField>(find.byType(TextField)).onSubmitted!('故');
      expect(provider.searches, isEmpty);
      expect(provider.suggestions, isEmpty);
      input.value = input.value.copyWith(composing: TextRange.empty);
      await tester.pump(const Duration(milliseconds: 299));
      expect(provider.suggestions, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(provider.suggestions, hasLength(1));
      await tester.enterText(find.byType(TextField), '故事');
      await tester.pump(const Duration(milliseconds: 300));
      provider.suggestions.last.result.complete({
        'items': [
          {'name': '故事联想'},
        ],
      });
      await tester.pumpAndSettle();
      provider.suggestions.first.result.complete({
        'items': [
          {'name': '过期联想'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('故事联想'), findsOneWidget);
      expect(find.text('过期联想'), findsNothing);
      await tester.tap(find.text('故事联想'));
      await tester.pump();
      expect(provider.searches.single.args['query'], '故事联想');
      await _finish(tester, provider.searches.single, [
        _drama('remote'),
      ], more: true);
      input.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_ids(tester), ['remote']);
      expect(find.text('加载更多结果'), findsOneWidget);
      expect(provider.suggestions, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'external source changes retain the keyword and reject late responses',
    (tester) async {
      final (:provider, :store) = await _mount(tester);
      await _submit(tester);
      store.catalog.catalogs[DramaSource.huangguo] = [
        _drama('new-source', source: DramaSource.huangguo),
      ];
      await store.catalog.selectSource(DramaSource.huangguo);
      await tester.pump();
      await _finish(tester, provider.searches.single, [_drama('old-source')]);
      expect(_ids(tester), isEmpty);
      expect(
        tester.widget<SourceSelector>(find.byType(SourceSelector)).value,
        DramaSource.huangguo,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '故事',
      );
      expect(
        provider.cancellations,
        contains(
          allOf(
            containsPair('source', provider.searches.single.args['source']),
            containsPair('query', provider.searches.single.args['query']),
            containsPair(
              'requestId',
              provider.searches.single.args['requestId'],
            ),
          ),
        ),
      );
      expect(provider.searches, hasLength(1));
      expect(find.text('搜索当前站源'), findsOneWidget);
      await tester.tap(find.byTooltip('联网搜索'));
      await tester.pump();
      expect(provider.searches.last.args['source'], 'huangguo');
      expect(provider.searches.last.args['query'], '故事');
      await _finish(tester, provider.searches.last, [
        _drama('new-result', source: DramaSource.huangguo),
      ]);
      expect(_ids(tester), ['new-result']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving during suggestions and search stops late work safely', (
    tester,
  ) async {
    final (:provider, :store) = await _mount(tester);
    await tester.enterText(find.byType(TextField), '故事');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    provider.suggestions.single.result.complete({
      'items': [
        {'name': '迟到联想'},
      ],
    });
    provider.searches.single.result.complete(_page([_drama('late')]));
    await tester.pump(const Duration(seconds: 2));
    expect(provider.polls, 0);
    expect(
      store.catalog.catalogs[DramaSource.hongguo]!.map((item) => item.id),
      ['local'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search is independent of the browsing filter and returning preserves it',
    (tester) async {
      final (:provider, :store) = await _mount(tester);
      final downloads = DownloadStore(store);
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('完整剧库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '分类'));
      await tester.pump();
      await tester.tap(find.byTooltip('搜索剧名'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      await _submit(tester);
      provider.partial = [
        _drama('A', category: '分类'),
        _drama('B', category: '其他'),
      ];
      await tester.pump(const Duration(milliseconds: 701));
      await tester.pump();
      expect(_ids(tester), ['A', 'B']);
      await _finish(tester, provider.searches.single, provider.partial);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '分类'))
            .selected,
        isTrue,
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('搜索剧名'));
      await tester.pumpAndSettle();
      store.catalog.catalogs[DramaSource.huangdou] = [
        _drama('target', source: DramaSource.huangdou, category: '新分类'),
      ];
      provider.catalogs[DramaSource.huangdou] =
          store.catalog.catalogs[DramaSource.huangdou]!;
      await store.catalog.selectSource(DramaSource.huangdou);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('submitting offline returns to filtering the local catalog', (
    tester,
  ) async {
    final (:provider, :store) = await _mount(tester);
    await _submit(tester, '目标');
    await _finish(tester, provider.searches.single, [
      _drama('remote'),
    ], more: true);
    expect(_ids(tester), ['remote']);
    store.setOffline(true);
    await tester.pump();
    await tester.tap(find.byTooltip('筛选缓存'));
    await tester.pumpAndSettle();
    expect(_ids(tester), ['local']);
    expect(find.text('本地匹配'), findsOneWidget);
    expect(find.text('加载更多结果'), findsNothing);
    expect(provider.searches, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final source in [DramaSource.hongguo, DramaSource.huangdou]) {
    testWidgets('${source.name} local search sends no network request', (
      tester,
    ) async {
      final (:provider, store: _) = await _mount(
        tester,
        source: source,
        offline: source == DramaSource.hongguo,
      );
      await _submit(tester, '目标');
      await tester.pump(const Duration(seconds: 1));
      expect(_ids(tester), ['local']);
      expect(provider.searches, isEmpty);
      expect(provider.suggestions, isEmpty);
      expect(find.text('本地匹配'), findsOneWidget);
      expect(find.text('加载更多结果'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
