import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/home_page.dart';

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
    if (method == 'cancelSearch') cancellations.add(args);
    return Future.value({'items': []});
  }
}

Future<({AppStore store, _Provider provider})> _mount(
  WidgetTester tester, {
  DramaSource source = DramaSource.hongguo,
  bool offline = false,
  Size size = const Size(1400, 1800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = _Provider();
  final store = AppStore(storage: MemoryStorage(), provider: provider)
    ..offline = offline;
  await store.catalog.selectSource(source);
  store.catalog.catalogs[source] = [
    _drama('local', source: source, title: '目标缓存', category: '分类'),
  ];
  final downloads = DownloadStore(store);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final request in [...provider.searches, ...provider.suggestions]) {
      if (!request.result.isCompleted) request.result.complete({'items': []});
    }
    await tester.pump();
    downloads.dispose();
    store.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(store: store, downloads: downloads, autoLoad: false),
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
    'empty search shows loading and retries failure without updating catalog',
    (tester) async {
      final (:provider, store: _) = await _mount(tester);
      await _submit(tester);
      expect(find.text('正在搜索…'), findsOneWidget);
      expect(find.text('暂时没有找到'), findsNothing);
      expect(find.text('更新剧库'), findsNothing);
      provider.searches.single.result.completeError(
        StateError('first-page-error'),
      );
      await tester.pumpAndSettle();
      expect(find.text('重试搜索'), findsOneWidget);
      expect(find.textContaining('first-page-error'), findsNothing);
      expect(find.text('更新剧库'), findsNothing);
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
    'external source changes clear search and reject late responses',
    (tester) async {
      final (:provider, :store) = await _mount(tester);
      await _submit(tester);
      store.catalog.catalogs[DramaSource.huangguo] = [
        _drama('new-source', source: DramaSource.huangguo),
      ];
      await store.catalog.selectSource(DramaSource.huangguo);
      await tester.pump();
      await _finish(tester, provider.searches.single, [_drama('old-source')]);
      expect(_ids(tester), ['new-source']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
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
    'search updates preserve a chosen category until the input changes',
    (tester) async {
      final (:provider, store: _) = await _mount(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '分类'));
      await tester.pump();
      await _submit(tester);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '分类'));
      await tester.pump();
      provider.partial = [_drama('A', category: '分类')];
      await tester.pump(const Duration(milliseconds: 701));
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '分类'))
            .selected,
        isTrue,
      );
      await _finish(tester, provider.searches.single, [
        _drama('A', category: '分类'),
      ]);
      await tester.tap(find.byTooltip('联网搜索'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '分类'))
            .selected,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '新关键词');
      await tester.pump();
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
    await tester.tap(find.byTooltip('联网搜索'));
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
