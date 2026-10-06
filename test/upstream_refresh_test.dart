import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/search_cache.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/library_exchange.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/catalog_query.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/throttled_builder.dart';

const drama = Drama(
  id: 'hongguo:7300000000000000001',
  source: DramaSource.hongguo,
  title: '修仙第一季',
);

class RefreshProvider implements ProviderClient {
  int searches = 0, progress = 0, cancels = 0, overlaps = 0;
  bool polling = false;
  final result = Completer<Map<String, dynamic>>();
  Completer<Map<String, dynamic>>? progressResult;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'search') {
      searches++;
      return result.future;
    }
    if (method == 'cancelSearch') {
      cancels++;
      return {};
    }
    if (method == 'searchProgress') {
      if (polling) overlaps++;
      polling = true;
      progress++;
      try {
        return await (progressResult?.future ??
            Future.value({
              'source': args['source'],
              'query': args['query'],
              'items': [drama.toJson()],
              'done': false,
            }));
      } finally {
        polling = false;
      }
    }
    throw StateError('unexpected method $method');
  }
}

class FailingStorage extends MemoryStorage {
  bool fail = false;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    if (fail) throw const FileSystemException('disk full');
    await super.write(next);
  }
}

class PendingFailingStorage extends MemoryStorage {
  final pending = Completer<void>();
  @override
  Future<void> write(Map<String, dynamic> next) => pending.future;
}

void main() {
  test(
    'unknown record sources are rejected without mutating existing data',
    () async {
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: RefreshProvider());
      await store.toggleFavorite(drama);
      final state = store.snapshot();
      final records = state['records'] as Map;
      records['favorites'] = [
        {...drama.toJson(), 'source': 'unknown'},
      ];
      expect(
        () => store.inspectBackup(jsonEncode(records)),
        throwsFormatException,
      );
      expect(store.favorites.keys, [drama.key]);
      await storage.write(state);
      final restored = AppStore(storage: storage, provider: RefreshProvider());
      await expectLater(restored.load(), throwsFormatException);
      expect(restored.favorites, isEmpty);
    },
  );
  test(
    'search cache preserves pagination, isolation and complete data under budgets',
    () {
      final cache = SearchCache(), now = DateTime.utc(2026, 10, 3);
      cache.put(
        'hongguo|修仙|1',
        const CatalogSearchResult([drama], hasMore: true, total: 30),
        now,
      );
      cache.put(
        'hongguo|修仙|1',
        const CatalogSearchResult([], warning: 'partial failure'),
        now.add(const Duration(minutes: 1)),
      );
      final cached = cache.read('hongguo|修仙|1', now)!;
      expect(cached.result.hasMore, isTrue);
      expect(cached.result.total, 30);
      expect(cached.result.items.single.key, drama.key);
      expect(cache.read('huangguo|修仙|1', now), isNull);
      expect(
        cache.read('hongguo|修仙|1', now.add(const Duration(minutes: 21)))!.fresh,
        isFalse,
      );
      for (var i = 0; i < 30; i++) {
        cache.put('hongguo|$i|1', const CatalogSearchResult([drama]), now);
      }
      expect(cache.toJson().length, SearchCache.maxEntries);
      final restored = SearchCache()..restore(cache.toJson());
      expect(restored.toJson().length, SearchCache.maxEntries);
      expect(
        () => restored.restore({
          'hongguo|bad|1': {'items': 'malformed'},
        }),
        returnsNormally,
      );
    },
  );
  test(
    'identical search owners share one request and persist final cache',
    () async {
      final provider = RefreshProvider(), storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: provider);
      final first = store.searchCatalog(DramaSource.hongguo, '修仙');
      final second = store.searchCatalog(DramaSource.hongguo, ' 修仙 ');
      expect(provider.searches, 1);
      provider.result.complete({
        'items': [drama.toJson()],
        'hasMore': true,
        'total': 30,
      });
      await Future.wait([first, second]);
      final restored = AppStore(storage: storage, provider: provider)
        ..offline = true;
      await restored.load();
      restored.offline = true;
      final cached = await restored.searchCatalog(DramaSource.hongguo, '修仙');
      expect(cached.hasMore, isTrue);
      expect(cached.total, 30);
      expect(provider.searches, 1);
    },
  );
  testWidgets(
    'progress polling never overlaps and late progress stops after final result',
    (tester) async {
      await tester.pump();
      final provider = RefreshProvider()..progressResult = Completer();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      final partials = <CatalogSearchResult>[];
      final pending = store.searchCatalog(
        DramaSource.hongguo,
        '修仙',
        requestId: 'ui-1',
        onPartial: partials.add,
      );
      await tester.pump();
      expect(provider.searches, 1);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 1400));
      expect(
        provider.progress,
        1,
        reason: 'searches=${provider.searches}, polling=${provider.polling}',
      );
      expect(provider.overlaps, 0);
      provider.result.complete({
        'items': [drama.toJson()],
      });
      await tester.pump();
      await pending;
      provider.progressResult!.complete({
        'source': 'hongguo',
        'query': '修仙',
        'items': [drama.toJson()],
      });
      await tester.pump(const Duration(seconds: 2));
      expect(partials, isEmpty);
      expect(provider.progress, 1);
      expect(provider.cancels, 1);
    },
  );
  test(
    'library import fills missing fields, preserves IDs and rolls back write failures',
    () async {
      final storage = FailingStorage(),
          store = AppStore(
            storage: FailingStorage(),
            provider: RefreshProvider(),
          );
      final working = AppStore(storage: storage, provider: RefreshProvider());
      const original = Drama(
        id: 'xingguo:5@长介绍',
        source: DramaSource.xingguo,
        title: '现有标题',
      );
      working.catalogs[DramaSource.xingguo] = [original];
      final result = await working.importLibraryRows([
        const Drama(
          id: 'xingguo:5@长',
          source: DramaSource.xingguo,
          title: '导入标题',
          description: '完整简介',
          cover: 'https://art.example.org/cover',
        ),
      ]);
      expect(result['imported'], 0);
      expect(result['merged'], 1);
      expect(working.catalogs[DramaSource.xingguo]!.single.id, original.id);
      expect(
        working.catalogs[DramaSource.xingguo]!.single.title,
        original.title,
      );
      expect(working.catalogs[DramaSource.xingguo]!.single.description, '完整简介');
      await working.selectSource(DramaSource.xingguo);
      expect(working.library.single.id, original.id);
      storage.fail = true;
      await expectLater(
        working.importLibraryRows([drama]),
        throwsA(isA<FileSystemException>()),
      );
      expect(working.catalogs[DramaSource.hongguo], isNull);
      expect(store.catalogs, isEmpty);
    },
  );
  test('library exchange rejects a malformed batch before merging', () async {
    final directory = await Directory.systemTemp.createTemp(
      'guoguo-library-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/library.json',
    ).writeAsString('{}');
    final provider = _ExchangeProvider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    await expectLater(
      LibraryExchange(store).inspect(file),
      throwsA(isA<FormatException>()),
    );
    expect(store.catalogs, isEmpty);
  });
  test('failed library import preserves concurrent refresh results', () async {
    final storage = PendingFailingStorage();
    final store = AppStore(storage: storage, provider: RefreshProvider());
    final operation = store.importLibraryRows([drama]);
    final failure = expectLater(operation, throwsA(isA<FileSystemException>()));
    const refreshed = Drama(
      id: 'hongguo:7300000000000000002',
      source: DramaSource.hongguo,
      title: '刷新结果',
    );
    store.catalogs[DramaSource.hongguo] = [drama, refreshed];
    store.catalogs[DramaSource.huangdou] = const [
      Drama(id: 'huangdou:1', source: DramaSource.huangdou, title: '其他源'),
    ];
    storage.pending.completeError(const FileSystemException('disk full'));
    await failure;
    expect(store.catalogs[DramaSource.hongguo], [refreshed]);
    expect(store.catalogs[DramaSource.huangdou]!.single.title, '其他源');
  });
  test(
    'file storage snapshots input and preserves queued write order',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'guoguo-storage-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = FileStorage(directory),
          first = {
            'rows': <Object>[
              {'position': 1},
            ],
          };
      final saved = storage.write(first);
      (first['rows'] as List).clear();
      await saved;
      expect((await storage.read())!['rows'], [
        {'position': 1},
      ]);
      await Future.wait([
        storage.write({'position': 2}),
        storage.write({'position': 3}),
      ]);
      expect((await storage.read())!['position'], 3);
    },
  );
  test('watch progress uses its own notification channel', () async {
    final store = AppStore(
      storage: MemoryStorage(),
      provider: RefreshProvider(),
    );
    int global = 0, library = 0;
    store.addListener(() => global++);
    store.libraryChanges.addListener(() => library++);
    await store.saveWatch(
      WatchRecord(
        drama: drama,
        episodeId: '1',
        episodeIndex: 0,
        positionMs: 10,
        durationMs: 100,
        updatedAt: DateTime.utc(2026),
      ),
    );
    expect(global, 0);
    expect(library, 1);
    expect(store.history[drama.key]!.positionMs, 10);
  });
  test(
    'same-series suggestions stay on source and use natural season order',
    () {
      final rows = relatedSeries(drama, [
        const Drama(id: '2', source: DramaSource.hongguo, title: '修仙第十季'),
        const Drama(id: '3', source: DramaSource.hongguo, title: '修仙第二季'),
        const Drama(id: '4', source: DramaSource.huangguo, title: '修仙第三季'),
        const Drama(id: '5', source: DramaSource.hongguo, title: '修仙其他作品'),
      ]);
      expect(rows.map((d) => d.title), ['修仙第二季', '修仙第十季']);
    },
  );
  testWidgets(
    'hidden controls skip ticks; important state changes rebuild immediately',
    (tester) async {
      final value = ValueNotifier((position: 0, playing: true));
      addTearDown(value.dispose);
      int builds = 0;
      Future<void> show(bool active) => tester.pumpWidget(
        MaterialApp(
          home: ThrottledValueBuilder(
            listenable: value,
            active: active,
            immediate: (before, after) => before.playing != after.playing,
            builder: (_) {
              builds++;
              return Text('${value.value.position}');
            },
          ),
        ),
      );
      await show(false);
      final initial = builds;
      for (var i = 1; i < 20; i++) {
        value.value = (position: i, playing: true);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(builds, initial);
      await show(true);
      value.value = (position: 21, playing: true);
      await tester.pump();
      final painted = builds;
      value.value = (position: 22, playing: true);
      await tester.pump(const Duration(milliseconds: 50));
      expect(builds, painted);
      value.value = (position: 22, playing: false);
      await tester.pump();
      expect(builds, painted + 1);
    },
  );
}

class _ExchangeProvider implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => {
    'items': [
      drama.toJson(),
      {'id': 'broken', 'source': 'hongguo', 'title': ''},
    ],
  };
}
