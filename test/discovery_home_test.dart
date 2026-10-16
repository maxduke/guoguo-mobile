import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/discovery_page.dart';
import 'package:guoguo_mobile/ui/library_page.dart';

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
    final request = _Request(method, args);
    requests.add(request);
    if (method == 'categories') {
      request.result.complete({'items': []});
    }
    return request.result.future;
  }
}

Drama _drama(
  String id, {
  DramaSource source = DramaSource.hongguo,
  bool? vip,
}) => Drama(id: id, source: source, title: '故事$id', vip: vip);

Map<String, dynamic> _recommendations(List<Drama> rows) => {
  'items': rows.map((row) => row.toJson()).toList(),
  'nextOffset': rows.length,
  'hasMore': true,
};

Map<String, dynamic> _column(List<DiscoveryRow> rows, DiscoveryKind kind) => {
  'items': rows.map((row) => row.toJson()).toList(),
  'kind': kind.name,
  'hasMore': true,
};

Future<({AppStore store, _Provider provider})> _fixture(
  WidgetTester tester, {
  DramaSource source = DramaSource.hongguo,
}) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = _Provider();
  final store = AppStore(
    storage: MemoryStorage(),
    provider: provider,
    // Keep dated cache fixtures inside retention regardless of the run date.
    now: () => DateTime.utc(2026, 10, 9, 12),
  );
  await store.catalog.selectSource(source);
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

Widget _discovery(
  AppStore store, {
  bool active = true,
  bool ready = true,
  bool autoLoad = true,
  VoidCallback? onMore,
}) => MaterialApp(
  home: Scaffold(
    body: DiscoveryPage(
      store: store,
      source: store.catalog.source,
      active: active,
      ready: ready,
      autoLoad: autoLoad,
      onOpen: (_) {},
      onSearch: () {},
      onLibrary: () {},
      onMore: onMore ?? () {},
    ),
  ),
);

List<String> _ids(WidgetTester tester) => tester
    .widgetList<DramaCard>(find.byType(DramaCard))
    .map((card) => card.drama.id)
    .toList();

void main() {
  testWidgets('cold Huangguo home refresh calls the core again after failure', (
    tester,
  ) async {
    final (:store, :provider) = await _fixture(
      tester,
      source: DramaSource.huangguo,
    );
    await tester.pumpWidget(_discovery(store));
    void completeBoards() => provider.requests.last.result.complete({
      'items': [
        {'id': 'huangguo-hot', 'name': '热播榜'},
      ],
    });
    completeBoards();
    await tester.pump();
    provider.requests.last.result.completeError(
      const ProviderException(
        'https://site.invalid/?token=secret DNS failed before dialing',
        failureHint: '站点域名解析异常，可尝试切换网络后重试',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('站点域名解析异常'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    await tester.tap(find.byTooltip('更新首页栏目'));
    await tester.pump();
    completeBoards();
    await tester.pump();
    expect(provider.requests.map((r) => r.method), [
      'boards',
      'ranking',
      'boards',
      'ranking',
    ]);
    expect(provider.requests.last.args['refresh'], isTrue);
    provider.requests.last.result.complete(
      _column([
        DiscoveryRow(_drama('117', source: DramaSource.huangguo), rank: 1),
      ], DiscoveryKind.ranking),
    );
    await tester.pumpAndSettle();
    expect(_ids(tester), ['117']);
  });

  testWidgets(
    'Huangguo home refresh forces a new board read and keeps fallback age',
    (tester) async {
      final (:store, :provider) = await _fixture(
        tester,
        source: DramaSource.huangguo,
      );
      await tester.pumpWidget(_discovery(store));
      provider.requests.last.result.complete({
        'items': [
          {'id': 'huangguo-hot', 'name': '热播榜'},
        ],
      });
      await tester.pump();
      final fetchedAt = DateTime.utc(2026, 10, 8, 12);
      expect(provider.requests.last.args['refresh'], isFalse);
      final rows = [
        DiscoveryRow(_drama('117', source: DramaSource.huangguo), rank: 1),
      ];
      provider.requests.last.result.complete({
        ..._column(rows, DiscoveryKind.ranking),
        'fetchedAt': fetchedAt.toIso8601String(),
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更新首页栏目'));
      await tester.pump();
      provider.requests.last.result.complete({
        'items': [
          {'id': 'huangguo-hot', 'name': '热播榜'},
        ],
      });
      await tester.pump();
      expect(provider.requests.last.args['refresh'], isTrue);
      provider.requests.last.result.complete({
        ..._column(rows, DiscoveryKind.ranking),
        'fetchedAt': fetchedAt.toIso8601String(),
        'stale': true,
        'warning': '站点暂不可用',
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('缓存 · 上次获取'), findsOneWidget);
      expect(
        store.catalog.discoveryCache
            .ranking(DramaSource.huangguo, 'huangguo-hot')!
            .savedAt,
        fetchedAt,
      );
    },
  );

  testWidgets(
    'the app defers its directory until library entry and keeps the preview on return',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      final downloads = DownloadStore(store);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
      });
      await tester.pumpWidget(GuoguoApp(store: store, downloads: downloads));
      expect(provider.requests.map((r) => r.method), ['recommendations']);
      provider.requests.single.result.complete(
        _recommendations([_drama('home')]),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['home']);
      await tester.tap(find.text('完整剧库'));
      await tester.pump();
      expect(provider.requests.map((r) => r.method), [
        'recommendations',
        'catalog',
      ]);
      provider.requests.last.result.complete({'items': [], 'hasMore': false});
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('当前目录没有作品'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(_ids(tester), ['home']);
      expect(provider.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home fetches one recommendation prefix without a directory or pagination',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      var more = 0;
      await tester.pumpWidget(_discovery(store, onMore: () => more++));
      expect(provider.requests.map((r) => r.method), ['recommendations']);
      expect(provider.requests.single.args, {
        'recommendation': {
          'genre': 'short_play',
          'offset': 0,
          'sessionId': '',
          'seen': [],
        },
      });
      provider.requests.single.result.complete(
        _recommendations(List.generate(9, (i) => _drama('$i'))),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['0', '1', '2', '3', '4', '5']);
      expect(store.catalog.libraryLoaded, isFalse);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(provider.requests, hasLength(1));
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多推荐'));
      expect(more, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in DiscoveryKind.values) {
    testWidgets(
      'one actual ${kind.name} column preserves order and honest ranks',
      (tester) async {
        final (:store, :provider) = await _fixture(
          tester,
          source: DramaSource.huangdou,
        );
        await tester.pumpWidget(_discovery(store));
        expect(provider.requests.map((r) => r.method), ['boards']);
        expect(provider.requests.single.args, {'source': 'huangdou'});
        provider.requests.single.result.complete({
          'items': [
            {'id': 'actual', 'name': '公开栏目', 'kind': kind.name},
            {'id': 'other', 'name': '另一栏目', 'kind': kind.name},
          ],
        });
        await tester.pump();
        await tester.pump();
        expect(provider.requests.map((r) => r.method), ['boards', 'ranking']);
        expect(provider.requests.last.args, {
          'board': 'actual',
          'page': 1,
          'refresh': false,
        });
        provider.requests.last.result.complete(
          _column([
            DiscoveryRow(
              _drama('vip', source: DramaSource.huangdou, vip: true),
              rank: 1,
            ),
            DiscoveryRow(
              _drama('first', source: DramaSource.huangdou),
              rank: 4,
            ),
            DiscoveryRow(
              _drama('second', source: DramaSource.huangdou),
              rank: 9,
            ),
          ], kind),
        );
        await tester.pumpAndSettle();
        expect(_ids(tester), ['first', 'second']);
        expect(find.text('公开栏目'), findsOneWidget);
        expect(
          find.text('4'),
          kind == DiscoveryKind.ranking ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('9'),
          kind == DiscoveryKind.ranking ? findsOneWidget : findsNothing,
        );
        expect(store.catalog.libraryLoaded, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cached preview survives failure and retries without fabricating a cursor',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        [_drama('saved')],
        store.now(),
      );
      await tester.pumpWidget(_discovery(store));
      expect(_ids(tester), ['saved']);
      provider.requests.single.result.completeError(
        StateError('private detail'),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['saved']);
      expect(find.textContaining('private detail'), findsNothing);
      expect(find.textContaining('已保留现有内容'), findsOneWidget);
      await tester.tap(find.text('重试栏目'));
      await tester.pump();
      expect(provider.requests, hasLength(2));
      expect(provider.requests.last.args, provider.requests.first.args);
      provider.requests.last.result.complete(
        _recommendations([_drama('fresh')]),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['fresh']);
      expect(find.text('重试栏目'), findsNothing);
      expect(store.catalog.libraryLoaded, isFalse);
    },
  );

  testWidgets('readiness and active page gate content requests', (
    tester,
  ) async {
    final (:store, :provider) = await _fixture(tester);
    await tester.pumpWidget(_discovery(store, ready: false));
    expect(provider.requests, isEmpty);
    await tester.pumpWidget(_discovery(store, active: false));
    expect(provider.requests, isEmpty);
    await tester.pumpWidget(_discovery(store));
    expect(provider.requests, hasLength(1));
    provider.requests.single.result.complete(_recommendations([]));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_discovery(store, active: false));
    await tester.pumpWidget(_discovery(store));
    expect(provider.requests, hasLength(1));
  });

  testWidgets(
    'late response after source change or disposal cannot enter the cache',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      await tester.pumpWidget(_discovery(store));
      final old = provider.requests.single;
      await store.catalog.selectSource(DramaSource.huangdou);
      await tester.pumpWidget(_discovery(store));
      old.result.complete(_recommendations([_drama('late')]));
      await tester.pump();
      expect(
        store.catalog.discoveryCache.recommendations(
          RecommendationGenre.shortPlay,
        ),
        isNull,
      );
      final boards = provider.requests.last;
      await tester.pumpWidget(const SizedBox());
      boards.result.complete({
        'items': [
          {'id': 'late', 'name': '迟到栏目'},
        ],
      });
      await tester.pumpAndSettle();
      expect(provider.requests.map((r) => r.method), [
        'recommendations',
        'boards',
      ]);
      expect(store.catalog.discoveryCache.boards(DramaSource.huangdou), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing store ignores its pending recommendation and loads the new owner',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      final nextProvider = _Provider();
      final next = AppStore(storage: MemoryStorage(), provider: nextProvider);
      addTearDown(next.dispose);
      await tester.pumpWidget(_discovery(store));
      await tester.pumpWidget(_discovery(next));
      provider.requests.single.result.complete(
        _recommendations([_drama('old')]),
      );
      nextProvider.requests.single.result.complete(
        _recommendations([_drama('new')]),
      );
      await tester.pumpAndSettle();
      expect(_ids(tester), ['new']);
      expect(
        store.catalog.discoveryCache.recommendations(
          RecommendationGenre.shortPlay,
        ),
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'metadata does not prevent the first directory fetch and an empty response stays empty',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      store.catalog.catalogs[DramaSource.hongguo] = [_drama('metadata')];
      expect(store.catalog.libraryLoaded, isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(store: store, onOpen: (_) {}, onSearch: () {}),
        ),
      );
      await tester.pump();
      expect(provider.requests.map((r) => r.method), ['catalog']);
      provider.requests.single.result.complete({'items': [], 'hasMore': false});
      await tester.pumpAndSettle();
      expect(store.catalog.libraryLoaded, isTrue);
      expect(store.catalog.library, isEmpty);
      expect(
        store.catalog.catalogs[DramaSource.hongguo]!.single.id,
        'metadata',
      );
      expect(find.text('当前目录没有作品'), findsOneWidget);
      expect(find.text('本轮目录已返回完毕'), findsOneWidget);
      expect(provider.requests, hasLength(1));
      final restored = AppStore(storage: store.storage, provider: provider);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.catalog.libraryLoaded, isTrue);
      expect(restored.catalog.library, isEmpty);
      expect(
        restored.catalog.catalogs[DramaSource.hongguo]!.single.id,
        'metadata',
      );
    },
  );

  testWidgets(
    'offline metadata is labelled as saved information without pagination',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      store.offline = true;
      store.catalog.catalogs[DramaSource.hongguo] = [_drama('saved')];
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(store: store, onOpen: (_) {}, onSearch: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已保存资料 · 尚未取得当前目录'), findsOneWidget);
      expect(find.text('本轮目录已返回完毕'), findsNothing);
      expect(provider.requests, isEmpty);
      expect(_ids(tester), ['saved']);
    },
  );

  for (final source in [DramaSource.hongguo, DramaSource.huangju]) {
    testWidgets(
      '${source.name} imported prefix still fetches the first actual directory',
      (tester) async {
        final (:store, :provider) = await _fixture(tester, source: source);
        store.catalog.catalogs[source] = [
          _drama('search-only', source: source),
        ];
        await store.catalog.importLibraryRows([
          _drama('imported', source: source),
        ]);
        expect(store.catalog.libraryLoaded, isFalse);
        expect(store.catalog.library.map((row) => row.id), ['imported']);
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryPage(store: store, onOpen: (_) {}, onSearch: () {}),
          ),
        );
        await tester.pump();
        final request = provider.requests.lastWhere(
          (r) => r.method == 'catalog',
        );
        request.result.complete({
          'items': [_drama('actual', source: source).toJson()],
          'hasMore': false,
        });
        await tester.pumpAndSettle();
        expect(store.catalog.library.map((row) => row.id), ['actual']);
        expect(store.catalog.libraryLoaded, isTrue);
        expect(store.catalog.catalogs[source]!.map((row) => row.id), [
          'search-only',
          'imported',
          'actual',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'library filters and saved rows fit a narrow dark screen with large text',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      tester.view.physicalSize = const Size(320, 740);
      store.offline = true;
      store.catalog.catalogs[DramaSource.hongguo] = [
        _drama('一个很长的剧名用于检查筛选展开后的窄屏大字体布局'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: LibraryPage(store: store, onOpen: (_) {}, onSearch: () {}),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(provider.requests, isEmpty);
    },
  );

  testWidgets(
    'small dark home with large text preserves its cached column through rotation',
    (tester) async {
      final (:store, :provider) = await _fixture(tester);
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        [_drama('很长的剧名用于验证窄屏和系统大字体的交互布局')],
        store.now(),
      );
      Widget app() => MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: DiscoveryPage(
            store: store,
            source: store.catalog.source,
            autoLoad: false,
            onOpen: (_) {},
            onSearch: () {},
            onLibrary: () {},
            onMore: () {},
          ),
        ),
      );
      for (final size in [const Size(320, 740), const Size(740, 320)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(provider.requests, isEmpty);
      expect(
        store.catalog.discoveryCache
            .recommendations(RecommendationGenre.shortPlay)!
            .rows,
        hasLength(1),
      );
    },
  );
}
