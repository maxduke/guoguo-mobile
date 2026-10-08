import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/discovery_cache.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _NoNetwork implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => throw StateError('Unexpected network request');
}

Drama _drama(
  String id, {
  DramaSource source = DramaSource.hongguo,
  String description = '',
}) => Drama(id: id, source: source, title: '条目$id', description: description);

void main() {
  final savedAt = DateTime.utc(2026, 10, 9, 12);

  test(
    'store roundtrip retains ordered genres, sources, kinds, ranks and warnings',
    () async {
      final storage = MemoryStorage();
      final store = AppStore(
        storage: storage,
        provider: _NoNetwork(),
        now: () => savedAt,
      );
      await store.catalog.saveRecommendationColumn(
        RecommendationGenre.shortPlay,
        [_drama('b'), _drama('a')],
        savedAt,
      );
      await store.catalog.saveRecommendationColumn(
        RecommendationGenre.comicSeries,
        [_drama('comic')],
        savedAt,
      );
      await store.catalog.saveDiscoveryBoards(DramaSource.hongguo, [
        const DiscoveryBoard('hot', '热播榜'),
        const DiscoveryBoard(
          'catalog',
          '目录',
          kind: DiscoveryKind.catalog,
          description: '目录顺序',
        ),
      ]);
      for (final source in [DramaSource.hongguo, DramaSource.huangguo]) {
        await store.catalog.saveRankingColumn(
          source,
          'hot',
          CachedDiscoveryColumn(
            [
              DiscoveryRow(_drama('b', source: source), rank: 9),
              DiscoveryRow(_drama('a', source: source), rank: 2),
            ],
            savedAt: savedAt,
            kind: DiscoveryKind.ranking,
            description: '站源真实排名',
            warning: '上游缓存',
          ),
        );
      }
      await store.catalog.saveRankingColumn(
        DramaSource.hongguo,
        'catalog',
        CachedDiscoveryColumn(
          [DiscoveryRow(_drama('directory'), rank: 8)],
          savedAt: savedAt,
          kind: DiscoveryKind.catalog,
          description: '目录顺序',
        ),
      );
      final restored = AppStore(
        storage: storage,
        provider: _NoNetwork(),
        now: () => savedAt,
      );
      await restored.load();
      final cache = restored.catalog.discoveryCache;
      expect(
        cache
            .recommendations(RecommendationGenre.shortPlay)!
            .rows
            .map((row) => row.drama.id),
        ['b', 'a'],
      );
      expect(
        cache
            .recommendations(RecommendationGenre.comicSeries)!
            .rows
            .single
            .drama
            .id,
        'comic',
      );
      expect(
        cache.boards(DramaSource.hongguo)!.boards.map((board) => board.id),
        ['hot', 'catalog'],
      );
      expect(
        cache.boards(DramaSource.hongguo)!.boards.last.kind,
        DiscoveryKind.catalog,
      );
      expect(
        cache.boards(DramaSource.hongguo)!.boards.last.description,
        '目录顺序',
      );
      final ranking = cache.ranking(DramaSource.huangguo, 'hot')!;
      expect(ranking.rows.map((row) => row.rank), [9, 2]);
      expect(
        ranking.rows.every((row) => row.drama.source == DramaSource.huangguo),
        true,
      );
      expect(ranking.kind, DiscoveryKind.ranking);
      expect(ranking.description, '站源真实排名');
      expect(ranking.warning, '上游缓存');
      expect(ranking.savedAt, savedAt);
      expect(
        cache.ranking(DramaSource.hongguo, 'catalog')!.kind,
        DiscoveryKind.catalog,
      );
      expect(restored.records.history, isEmpty);
      store.dispose();
      restored.dispose();
    },
  );

  test(
    'columns retain a bounded prefix and evict least recently used columns',
    () {
      final cache = DiscoveryCache(now: () => savedAt);
      cache.putRecommendations(
        RecommendationGenre.shortPlay,
        List.generate(100, (index) => _drama('$index')),
        savedAt,
      );
      expect(
        cache
            .recommendations(RecommendationGenre.shortPlay)!
            .rows
            .map((row) => row.drama.id),
        List.generate(DiscoveryCache.maxRows, (index) => '$index'),
      );
      for (var index = 0; index < DiscoveryCache.maxColumns - 1; index++) {
        cache.putRanking(
          DramaSource.hongguo,
          '$index',
          CachedDiscoveryColumn(
            [DiscoveryRow(_drama('$index'))],
            savedAt: savedAt,
            kind: DiscoveryKind.catalog,
          ),
        );
      }
      cache.recommendations(RecommendationGenre.shortPlay);
      cache.putRanking(
        DramaSource.hongguo,
        'new',
        CachedDiscoveryColumn(
          [],
          savedAt: savedAt,
          kind: DiscoveryKind.catalog,
        ),
      );
      expect(cache.ranking(DramaSource.hongguo, '0'), isNull);
      expect(cache.recommendations(RecommendationGenre.shortPlay), isNotNull);
      expect(
        (cache.toJson()['columns'] as Map).length,
        DiscoveryCache.maxColumns,
      );
    },
  );

  test(
    'UTF-8 byte bounds trim prefixes and oversized content preserves the previous column',
    () {
      final cache = DiscoveryCache(now: () => savedAt);
      cache.putRecommendations(
        RecommendationGenre.shortPlay,
        List.generate(60, (index) => _drama('$index', description: '字' * 2000)),
        savedAt,
      );
      final column = cache.recommendations(RecommendationGenre.shortPlay)!;
      expect(column.rows.length, inInclusiveRange(1, 59));
      expect(
        utf8.encode(jsonEncode(column.toJson())).length,
        lessThanOrEqualTo(DiscoveryCache.maxColumnBytes),
      );
      expect(column.rows.first.drama.id, '0');
      cache.putRecommendations(RecommendationGenre.shortPlay, [
        _drama('huge', description: '字' * 100000),
      ], savedAt);
      expect(
        cache.recommendations(RecommendationGenre.shortPlay),
        same(column),
      );
      cache.putBoards(
        DramaSource.hongguo,
        List.generate(200, (index) => DiscoveryBoard('$index', '栏目$index')),
        savedAt,
      );
      expect(
        cache.boards(DramaSource.hongguo)!.boards.length,
        DiscoveryCache.maxBoards,
      );
      cache.putBoards(DramaSource.hongguo, [
        DiscoveryBoard('large', '字' * 10000),
      ], savedAt);
      expect(
        cache.boards(DramaSource.hongguo)!.boards.length,
        DiscoveryCache.maxBoards,
      );
    },
  );

  test(
    'expired and future-dated cache entries are discarded without requests',
    () {
      var clock = savedAt;
      final cache = DiscoveryCache(now: () => clock);
      cache.putRecommendations(RecommendationGenre.shortPlay, [
        _drama('a'),
      ], savedAt);
      cache.putBoards(DramaSource.hongguo, [
        const DiscoveryBoard('hot', '热播榜'),
      ], savedAt);
      clock = savedAt
          .add(DiscoveryCache.retention)
          .add(const Duration(seconds: 1));
      expect(cache.recommendations(RecommendationGenre.shortPlay), isNull);
      expect(cache.boards(DramaSource.hongguo), isNull);
      cache.putRecommendations(RecommendationGenre.shortPlay, [
        _drama('future'),
      ], clock.add(const Duration(seconds: 1)));
      expect(cache.recommendations(RecommendationGenre.shortPlay), isNull);
      expect(cache.toJson()['columns'], isEmpty);
      expect(cache.toJson()['boards'], isEmpty);
    },
  );

  test(
    'damaged entries and source mismatches cannot discard healthy columns',
    () {
      final cache = DiscoveryCache(now: () => savedAt);
      final valid = CachedDiscoveryColumn(
        [DiscoveryRow(_drama('ok'), rank: 7)],
        savedAt: savedAt,
        kind: DiscoveryKind.ranking,
      ).toJson();
      cache.restore({
        'columns': {
          'rankings|hongguo|broken': {'rows': 'not a list'},
          'rankings|huangguo|wrong-source': valid,
          'rankings|hongguo|unknown-kind': {...valid, 'kind': 'made-up'},
          'rankings|hongguo|too-many': {
            ...valid,
            'rows': List.filled(61, (valid['rows'] as List).first),
          },
          'recommendations|unknown': valid,
          'rankings|hongguo|ok': valid,
        },
        'boards': {
          'hongguo': {
            'savedAt': savedAt.toIso8601String(),
            'boards': [
              {'id': 'bad', 'name': '错源', 'source': 'huangguo'},
            ],
          },
          'huangguo': {
            'savedAt': savedAt.toIso8601String(),
            'boards': [
              {'id': 'good', 'name': '可用'},
            ],
          },
        },
      });
      expect((cache.toJson()['columns'] as Map).keys, ['rankings|hongguo|ok']);
      expect(cache.ranking(DramaSource.hongguo, 'ok')!.rows.single.rank, 7);
      expect(cache.boards(DramaSource.hongguo), isNull);
      expect(cache.boards(DramaSource.huangguo)!.boards.single.id, 'good');
    },
  );
}
