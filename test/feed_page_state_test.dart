import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/discovery_cache.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/rankings_page.dart';
import 'package:guoguo_mobile/ui/recommendations_page.dart';

enum _Feed {
  recommendations('recommendations', '真人剧', '漫剧', '继续推荐'),
  rankings('ranking', '热播榜', '新剧榜', '加载更多');

  const _Feed(this.method, this.current, this.other, this.more);
  final String method, current, other, more;
}

Drama _drama(
  String id, {
  String? title,
  bool? vip,
  DramaSource source = DramaSource.hongguo,
}) => Drama(id: id, source: source, title: title ?? '条目$id', vip: vip);

Map<String, dynamic> _page(
  _Feed feed,
  List<Drama> items, {
  bool more = false,
  int next = 18,
  String session = 'session',
  String kind = 'ranking',
  String description = '',
  String? warning,
}) => {
  'items': [
    for (final (index, drama) in items.indexed)
      if (feed == _Feed.recommendations)
        drama.toJson()
      else
        {'drama': drama.toJson(), 'rank': index + 1},
  ],
  'hasMore': more,
  'nextOffset': next,
  'sessionId': session,
  'kind': kind,
  'description': description,
  'warning': warning,
};

const _boards = {
  'items': [
    {'id': 'a', 'name': '热播榜'},
    {'id': 'b', 'name': '新剧榜'},
  ],
};

class _Request {
  _Request(this.method, this.args);
  final String method;
  final Map<String, dynamic> args;
  final result = Completer<Map<String, dynamic>>();
}

class _Provider implements ProviderClient {
  _Provider({this.manualBoards = false});
  final bool manualBoards;
  final requests = <_Request>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    final request = _Request(
      method,
      Map<String, dynamic>.from(
        method == 'recommendations' ? args['recommendation'] as Map : args,
      ),
    );
    requests.add(request);
    if (method == 'boards' && !manualBoards) request.result.complete(_boards);
    return request.result.future;
  }
}

class _FailingCacheStorage implements PartitionedStorage {
  final records = MemoryStorage();
  @override
  String? get cacheReadError => null;
  @override
  Future<Map<String, dynamic>?> read() => records.read();
  @override
  Future<void> writeRecords(Map<String, dynamic> value) => records.write(value);
  @override
  Future<void> writeCache(Map<String, dynamic> value) async =>
      throw StateError('cache disk full');
  @override
  Future<void> write(Map<String, dynamic> value) async =>
      throw StateError('unexpected whole-document write');
}

Future<void> _seedColumn(_Feed feed, AppStore store) async {
  final rows = [_drama('cached-2'), _drama('cached-1')];
  if (feed == _Feed.recommendations) {
    await store.catalog.saveRecommendationColumn(
      RecommendationGenre.shortPlay,
      rows,
      store.now(),
    );
  } else {
    await store.catalog.saveDiscoveryBoards(DramaSource.hongguo, const [
      DiscoveryBoard('a', '热播榜'),
      DiscoveryBoard('b', '新剧榜'),
    ]);
    await store.catalog.saveRankingColumn(
      DramaSource.hongguo,
      'a',
      CachedDiscoveryColumn(
        [DiscoveryRow(rows[0], rank: 9), DiscoveryRow(rows[1], rank: 2)],
        savedAt: store.now(),
        kind: DiscoveryKind.catalog,
        description: '目录顺序，不代表官方排名',
        warning: '站源缓存说明',
      ),
    );
  }
}

class _Fixture {
  _Fixture(this.feed, this.store, this.provider);
  final _Feed feed;
  final AppStore store;
  final _Provider provider;
  List<_Request> get pages => provider.requests
      .where((request) => request.method == feed.method)
      .toList();
  _Request get latest => pages.last;

  Future<void> finish(
    WidgetTester tester,
    List<Drama> items, {
    bool more = false,
    int next = 18,
    String session = 'session',
  }) async {
    latest.result.complete(
      _page(feed, items, more: more, next: next, session: session),
    );
    await tester.pumpAndSettle();
  }
}

Future<_Fixture> _mount(
  WidgetTester tester,
  _Feed feed, {
  bool manualBoards = false,
  bool offline = false,
  DramaSource source = DramaSource.hongguo,
  Size size = const Size(1024, 1600),
  double textScale = 1,
  FutureOr<void> Function(AppStore)? seed,
  LocalStorage? storage,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = _Provider(manualBoards: manualBoards);
  final store = AppStore(
    storage: storage ?? MemoryStorage(),
    provider: provider,
  )..offline = offline;
  store.catalog.source = source;
  await seed?.call(store);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final request in provider.requests) {
      if (!request.result.isCompleted) {
        request.result.complete(_page(feed, []));
      }
    }
    await tester.idle();
    store.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: feed == _Feed.recommendations
          ? RecommendationsPage(store: store, onOpen: (_) {})
          : RankingsPage(store: store, onOpen: (_) {}),
    ),
  );
  await tester.pump();
  return _Fixture(feed, store, provider);
}

List<String> _ids(WidgetTester tester) => tester
    .widgetList<Poster>(find.byType(Poster))
    .map((poster) => poster.drama.id)
    .toList();

Future<void> _refresh(WidgetTester tester) =>
    tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();

VoidCallback _retry(WidgetTester tester) =>
    tester.widget<TextButton>(find.widgetWithText(TextButton, '重试')).onPressed!;

void _expectFirstPage(_Fixture fixture) {
  final args = fixture.latest.args;
  if (fixture.feed == _Feed.recommendations) {
    expect(args['offset'], 0);
    expect(args['sessionId'], '');
    expect(args['seen'], isEmpty);
  } else {
    expect(args['page'], 1);
  }
}

void main() {
  for (final feed in _Feed.values) {
    testWidgets(
      '${feed.name} cached refresh failure fits a narrow screen with large text',
      (tester) async {
        final fixture = await _mount(
          tester,
          feed,
          size: const Size(320, 640),
          textScale: 1.6,
          seed: (store) => _seedColumn(feed, store),
        );
        fixture.latest.result.completeError(StateError('network failed'));
        await tester.pumpAndSettle();
        expect(find.textContaining('缓存 · 上次获取'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${feed.name} displays an ordered cache before refreshing and keeps it on failure',
      (tester) async {
        final fixture = await _mount(
          tester,
          feed,
          seed: (store) => _seedColumn(feed, store),
        );
        expect(_ids(tester), ['cached-2', 'cached-1']);
        expect(find.textContaining('缓存 · 上次获取'), findsOneWidget);
        _expectFirstPage(fixture);
        if (feed == _Feed.rankings) {
          expect(find.text('目录顺序，不代表官方排名'), findsOneWidget);
          expect(find.text('站源缓存说明'), findsOneWidget);
          expect(find.text('9'), findsNothing);
        }
        fixture.latest.result.completeError(StateError('network failed'));
        await tester.pumpAndSettle();
        expect(_ids(tester), ['cached-2', 'cached-1']);
        expect(find.textContaining('缓存 · 上次获取'), findsOneWidget);
        expect(find.text('这轮推荐已看完'), findsNothing);
        _retry(tester)();
        _expectFirstPage(fixture);
        await fixture.finish(
          tester,
          [_drama('fresh')],
          more: true,
          next: 37,
          session: 'new-session',
        );
        expect(_ids(tester), ['fresh']);
        expect(find.textContaining('缓存 · 上次获取'), findsNothing);
        await tester.tap(find.text(feed.more));
        if (feed == _Feed.recommendations) {
          expect(fixture.latest.args['offset'], 37);
          expect(fixture.latest.args['sessionId'], 'new-session');
          expect(fixture.latest.args['seen'], ['fresh']);
        } else {
          expect(fixture.latest.args['page'], 2);
        }
        await fixture.finish(tester, [_drama('next')]);
        expect(_ids(tester), ['fresh', 'next']);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${feed.name} switching back uses its own cache and ignores late responses',
      (tester) async {
        final fixture = await _mount(
          tester,
          feed,
          seed: (store) => _seedColumn(feed, store),
        );
        final stale = fixture.latest;
        await tester.tap(find.text(feed.other));
        await tester.pump();
        await fixture.finish(tester, [_drama('other')]);
        stale.result.complete(_page(feed, [_drama('late')]));
        await tester.pumpAndSettle();
        expect(_ids(tester), ['other']);
        await tester.tap(find.text(feed.current));
        await tester.pump();
        expect(_ids(tester), ['cached-2', 'cached-1']);
        _expectFirstPage(fixture);
        await fixture.finish(tester, [_drama('fresh')]);
        expect(_ids(tester), ['fresh']);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${feed.name} successful pages advance even when cache storage fails',
      (tester) async {
        final fixture = await _mount(
          tester,
          feed,
          storage: _FailingCacheStorage(),
        );
        await fixture.finish(tester, [_drama('1')], more: true, next: 37);
        expect(_ids(tester), ['1']);
        expect(fixture.store.cachePersistenceError, isNotNull);
        expect(find.text('重试'), findsNothing);
        await tester.tap(find.text(feed.more));
        expect(
          fixture.latest.args[feed == _Feed.recommendations
              ? 'offset'
              : 'page'],
          feed == _Feed.recommendations ? 37 : 2,
        );
        await fixture.finish(tester, [_drama('2')]);
        expect(_ids(tester), ['1', '2']);
        expect(find.text('重试'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${feed.name} replacing a store invalidates its pending request and cached column',
      (tester) async {
        final fixture = await _mount(
          tester,
          feed,
          seed: (store) => _seedColumn(feed, store),
        );
        final stale = fixture.latest;
        final provider = _Provider();
        final replacement = AppStore(
          storage: MemoryStorage(),
          provider: provider,
        );
        addTearDown(replacement.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: feed == _Feed.recommendations
                ? RecommendationsPage(store: replacement, onOpen: (_) {})
                : RankingsPage(store: replacement, onOpen: (_) {}),
          ),
        );
        await tester.pump();
        expect(_ids(tester), isEmpty);
        final request = provider.requests.last;
        expect(request.method, feed.method);
        stale.result.complete(_page(feed, [_drama('late')]));
        request.result.complete(_page(feed, [_drama('replacement')]));
        await tester.pumpAndSettle();
        expect(_ids(tester), ['replacement']);
        expect(
          fixture.store.catalog.discoveryCache.toJson().toString(),
          isNot(contains('late')),
        );
        expect(
          replacement.catalog.discoveryCache.toJson().toString(),
          isNot(contains('late')),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'cached rankings survive board discovery failure and retry the board list',
    (tester) async {
      final fixture = await _mount(
        tester,
        _Feed.rankings,
        manualBoards: true,
        seed: (store) => _seedColumn(_Feed.rankings, store),
      );
      expect(_ids(tester), ['cached-2', 'cached-1']);
      expect(fixture.pages, isEmpty);
      fixture.provider.requests.single.result.completeError(
        StateError('boards failed'),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['cached-2', 'cached-1']);
      _retry(tester)();
      expect(fixture.provider.requests.last.method, 'boards');
      fixture.provider.requests.last.result.complete(_boards);
      await tester.pump();
      _expectFirstPage(fixture);
      await fixture.finish(tester, [_drama('fresh')]);
      expect(_ids(tester), ['fresh']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ranking source mismatch cannot replace good rows or their cache',
    (tester) async {
      final fixture = await _mount(tester, _Feed.rankings);
      await fixture.finish(tester, [_drama('good')], more: true);
      await tester.tap(find.text('加载更多'));
      await fixture.finish(tester, [
        _drama('foreign', source: DramaSource.huangguo),
      ]);
      expect(_ids(tester), ['good']);
      expect(find.text('重试'), findsOneWidget);
      expect(
        fixture.store.catalog.discoveryCache
            .ranking(DramaSource.hongguo, 'a')!
            .rows
            .single
            .drama
            .id,
        'good',
      );
      _retry(tester)();
      expect(fixture.latest.args['page'], 2);
      await fixture.finish(tester, [_drama('next')]);
      expect(_ids(tester), ['good', 'next']);
    },
  );

  for (final feed in _Feed.values) {
    testWidgets('${feed.name} refresh retains content and retries page one', (
      tester,
    ) async {
      final fixture = await _mount(tester, feed);
      await fixture.finish(tester, [_drama('1')], more: true);
      await tester.tap(find.text(feed.more));
      await fixture.finish(tester, [_drama('2')], next: 36);
      expect(_ids(tester), ['1', '2']);
      final refreshing = _refresh(tester);
      await tester.pump();
      expect(_ids(tester), ['1', '2']);
      _expectFirstPage(fixture);
      await _refresh(tester);
      await tester.tap(find.text(feed.current));
      expect(fixture.pages, hasLength(3));
      fixture.latest.result.completeError(StateError('private-request-detail'));
      await refreshing;
      await tester.pumpAndSettle();
      expect(_ids(tester), ['1', '2']);
      expect(find.textContaining('已保留现有内容'), findsOneWidget);
      expect(find.textContaining('private-request-detail'), findsNothing);
      final retry = _retry(tester);
      retry();
      retry();
      expect(fixture.pages, hasLength(4));
      _expectFirstPage(fixture);
      await fixture.finish(tester, [_drama('3')]);
      expect(_ids(tester), ['3']);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '${feed.name} failed pagination retries its cursor and dedupes',
      (tester) async {
        final fixture = await _mount(tester, feed);
        await fixture.finish(tester, [_drama('1')], more: true);
        final button = tester
            .widget<ButtonStyleButton>(
              find.ancestor(
                of: find.text(feed.more),
                matching: find.byWidgetPredicate(
                  (widget) => widget is ButtonStyleButton,
                ),
              ),
            )
            .onPressed!;
        button();
        button();
        await tester.pump();
        expect(fixture.pages, hasLength(2));
        final args = fixture.latest.args;
        if (feed == _Feed.recommendations) {
          expect(args['offset'], 18);
          expect(args['sessionId'], 'session');
          expect(args['seen'], ['1']);
        } else {
          expect(args['page'], 2);
        }
        fixture.latest.result.completeError(StateError('private-pagination'));
        await tester.pumpAndSettle();
        expect(_ids(tester), ['1']);
        expect(find.textContaining('private-pagination'), findsNothing);
        _retry(tester)();
        expect(fixture.latest.args, args);
        await fixture.finish(tester, [
          _drama('1', title: '更新资料'),
          _drama('2'),
        ], next: 36);
        expect(_ids(tester), ['1', '2']);
        expect(find.text('更新资料'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('${feed.name} malformed response does not partially commit', (
      tester,
    ) async {
      final fixture = await _mount(tester, feed);
      await fixture.finish(tester, [_drama('1')], more: true);
      await tester.tap(find.text(feed.more));
      final malformed = _page(feed, [_drama('2')], more: true, next: 36);
      malformed[feed == _Feed.recommendations ? 'nextOffset' : 'description'] =
          {'private': 'invalid-response'};
      fixture.latest.result.complete(malformed);
      await tester.pumpAndSettle();
      expect(_ids(tester), ['1']);
      expect(find.text('条目2'), findsNothing);
      expect(find.textContaining('invalid-response'), findsNothing);
      if (feed == _Feed.recommendations) {
        expect(fixture.store.catalog.library.map((d) => d.id), ['1']);
      }
      _retry(tester)();
      expect(
        fixture.latest.args[feed == _Feed.recommendations ? 'offset' : 'page'],
        feed == _Feed.recommendations ? 18 : 2,
      );
      await fixture.finish(tester, [_drama('2')]);
      expect(_ids(tester), ['1', '2']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${feed.name} switching during refresh rejects old results', (
      tester,
    ) async {
      final fixture = await _mount(tester, feed);
      await fixture.finish(tester, [_drama('1')], more: true);
      final refreshing = _refresh(tester);
      final old = fixture.latest;
      await tester.tap(find.text(feed.other));
      await tester.pump();
      expect(_ids(tester), isEmpty);
      _expectFirstPage(fixture);
      final current = fixture.latest;
      old.result.complete(_page(feed, [_drama('old')]));
      await refreshing;
      await tester.pump();
      expect(_ids(tester), isEmpty);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.tap(find.text(feed.other));
      expect(fixture.latest, same(current));
      current.result.completeError(StateError('new category failed'));
      await tester.pumpAndSettle();
      _retry(tester)();
      _expectFirstPage(fixture);
      expect(
        fixture.latest.args[feed == _Feed.recommendations ? 'genre' : 'board'],
        feed == _Feed.recommendations ? 'comic_series' : 'b',
      );
      await fixture.finish(tester, [_drama('new')]);
      expect(_ids(tester), ['new']);
      if (feed == _Feed.recommendations) {
        expect(
          fixture.store.catalog.library.any((d) => d.id == 'old'),
          isFalse,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '${feed.name} initial failure retries without duplicate requests',
      (tester) async {
        final fixture = await _mount(tester, feed);
        await tester.tap(find.text(feed.current));
        expect(fixture.pages, hasLength(1));
        fixture.latest.result.completeError(
          StateError('private-initial-error'),
        );
        await tester.pumpAndSettle();
        expect(find.text('重试'), findsOneWidget);
        expect(find.textContaining('private-initial-error'), findsNothing);
        final retry = _retry(tester);
        retry();
        retry();
        _expectFirstPage(fixture);
        expect(fixture.pages, hasLength(2));
        await fixture.finish(tester, [_drama('1')]);
        expect(_ids(tester), ['1']);
        expect(tester.takeException(), isNull);
      },
    );

    for (final refreshing in [false, true]) {
      testWidgets(
        '${feed.name} leaving during ${refreshing ? 'refresh' : 'initial load'} ignores late work',
        (tester) async {
          final fixture = await _mount(tester, feed);
          VoidCallback? retry;
          Future<void>? refresh;
          if (refreshing) {
            await fixture.finish(tester, [_drama('1')]);
            refresh = _refresh(tester);
          } else {
            fixture.latest.result.completeError(StateError('initial failure'));
            await tester.pumpAndSettle();
            retry = _retry(tester);
            retry();
          }
          final before = fixture.pages.length;
          final request = fixture.latest;
          await tester.pumpWidget(const SizedBox());
          retry?.call();
          request.result.complete(_page(feed, [_drama('late')]));
          await refresh;
          await tester.idle();
          expect(fixture.pages, hasLength(before));
          expect(
            fixture.store.catalog.library.any((d) => d.id == 'late'),
            isFalse,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${feed.name} refresh failure fits a narrow screen with large text',
      (tester) async {
        final fixture = await _mount(
          tester,
          feed,
          size: const Size(320, 640),
          textScale: 1.6,
        );
        await fixture.finish(tester, [_drama('1')]);
        final refresh = _refresh(tester);
        fixture.latest.result.completeError(StateError('network failed'));
        await refresh;
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('重试'),
          -150,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text('重试'));
        await fixture.finish(tester, [_drama('2')]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rankings board discovery can retry without overlapping requests',
    (tester) async {
      final fixture = await _mount(tester, _Feed.rankings, manualBoards: true);
      fixture.provider.requests.single.result.completeError(
        StateError('private-board-error'),
      );
      await tester.pumpAndSettle();
      expect(find.text('栏目列表暂时无法加载，请重试'), findsOneWidget);
      expect(find.textContaining('private-board-error'), findsNothing);
      final retry = _retry(tester);
      retry();
      retry();
      expect(fixture.provider.requests, hasLength(2));
      fixture.provider.requests.last.result.complete(_boards);
      await tester.pump();
      expect(fixture.latest.args['board'], 'a');
      await fixture.finish(tester, [_drama('1')]);
      expect(_ids(tester), ['1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving during board discovery cannot start ranking work', (
    tester,
  ) async {
    final fixture = await _mount(tester, _Feed.rankings, manualBoards: true);
    await tester.pumpWidget(const SizedBox());
    fixture.provider.requests.single.result.complete(_boards);
    await tester.idle();
    expect(fixture.pages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid ranking rows fail before rendering or advancing pages', (
    tester,
  ) async {
    final fixture = await _mount(tester, _Feed.rankings);
    await fixture.finish(tester, [_drama('1')], more: true);
    await tester.tap(find.text('加载更多'));
    fixture.latest.result.complete({
      'items': [
        {'drama': _drama('2').toJson(), 'rank': 2},
        {
          'drama': {'private': 'invalid-row'},
          'rank': 3,
        },
      ],
      'hasMore': true,
    });
    await tester.pumpAndSettle();
    expect(_ids(tester), ['1']);
    expect(find.textContaining('invalid-row'), findsNothing);
    expect(tester.takeException(), isNull);
    _retry(tester)();
    expect(fixture.latest.args['page'], 2);
    await fixture.finish(tester, [_drama('2')]);
    expect(_ids(tester), ['1', '2']);
  });

  testWidgets(
    'rankings preserve cached warnings, board kinds and VIP filtering',
    (tester) async {
      final fixture = await _mount(
        tester,
        _Feed.rankings,
        source: DramaSource.huangdou,
      );
      fixture.latest.result.complete(
        _page(
          _Feed.rankings,
          [
            _drama('1', source: DramaSource.huangdou),
            _drama('vip', vip: true, source: DramaSource.huangdou),
          ],
          more: true,
          kind: 'catalog',
          description: '目录顺序，不代表官方排名',
          warning: '站点暂不可用，显示上次取得的榜单，请稍后刷新。',
        ),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['1']);
      expect(find.text('目录顺序，不代表官方排名'), findsOneWidget);
      expect(find.text('站点暂不可用，显示上次取得的榜单，请稍后刷新。'), findsOneWidget);
      expect(find.text('1'), findsNothing);
      expect(find.text('重试'), findsNothing);
      await tester.tap(find.text('隐藏 VIP'));
      await tester.pumpAndSettle();
      expect(_ids(tester), ['1', 'vip']);
      expect(fixture.pages, hasLength(1));
      await tester.tap(find.text('加载更多'));
      await fixture.finish(tester, [_drama('2', source: DramaSource.huangdou)]);
      expect(_ids(tester), ['1', 'vip', '2']);
      expect(find.text('站点暂不可用，显示上次取得的榜单，请稍后刷新。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline recommendations explain retry and preserve existing rows',
    (tester) async {
      final fixture = await _mount(
        tester,
        _Feed.recommendations,
        offline: true,
      );
      await tester.pumpAndSettle();
      expect(fixture.pages, isEmpty);
      expect(find.text('当前离线，联网后可重试推荐'), findsOneWidget);
      fixture.store.offline = false;
      _retry(tester)();
      await fixture.finish(tester, [_drama('1')]);
      fixture.store.offline = true;
      await _refresh(tester);
      await tester.pumpAndSettle();
      expect(_ids(tester), ['1']);
      expect(fixture.pages, hasLength(1));
      expect(find.text('当前离线，联网后可重试推荐'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
