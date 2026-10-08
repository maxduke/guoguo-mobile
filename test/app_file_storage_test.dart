import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/discovery_cache.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class NoNetwork implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw StateError('unexpected network request');
}

const anchor = Drama(id: 'a', source: DramaSource.hongguo, title: '故事第一季');
const season = Drama(id: 'b', source: DramaSource.hongguo, title: '故事第二季');
WatchRecord watch(int position) => WatchRecord(
  drama: anchor,
  episodeId: 'e1',
  episodeIndex: 0,
  positionMs: position,
  durationMs: 100000,
  updatedAt: DateTime.utc(2026),
);
AppStore makeStore(LocalStorage storage) =>
    AppStore(storage: storage, provider: NoNetwork());

Future<Map<String, dynamic>> savedState() async {
  final store = makeStore(MemoryStorage());
  await store.records.saveWatch(watch(1));
  await store.records.toggleFavorite(anchor);
  await store.preferences.setTheme(ThemeMode.dark);
  await store.preferences.setPlayback(progressive: true, speed: 1.5);
  store.catalog.selectedCategories[DramaSource.huangguo] = 'ai';
  store.catalog.catalogs[DramaSource.hongguo] = [anchor, season];
  store.catalog.catalogPages[DramaSource.hongguo] = 3;
  store.catalog.hasMore[DramaSource.hongguo] = true;
  store.catalog.episodeCache[anchor.key] = [
    const Episode(id: 'e1', title: '一', number: 1, raw: {'id': 'e1'}),
    const Episode(id: 'e2', title: '二', number: 2, raw: {'id': 'e2'}),
  ];
  store.catalog.episodeUpdatedAt[anchor.key] = DateTime.utc(2026);
  await store.records.markEpisodesSeen(anchor, [
    store.catalog.episodeCache[anchor.key]!.first,
  ]);
  await store.records.importBackup(
    RecordBackup(
      [],
      [],
      seasonReminders: [
        SeasonReminder(
          anchor: anchor,
          initialized: true,
          updatedAt: DateTime.utc(2026),
          seasons: {season.key: const SeasonNotice(season)},
        ),
      ],
    ),
  );
  return store.snapshot();
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('guoguo-partitions-');
  });
  tearDown(() => directory.delete(recursive: true));
  File file(String name) => File('${directory.path}/$name');

  test(
    'discovery columns roundtrip through the cache file without rewriting records',
    () async {
      final store = makeStore(AppFileStorage(directory));
      addTearDown(store.dispose);
      await store.records.saveWatch(watch(42));
      final recordBytes = await file('records.json').readAsBytes();
      await store.catalog.saveRecommendationColumn(
        RecommendationGenre.shortPlay,
        [season, anchor],
        store.now(),
      );
      await store.catalog.saveDiscoveryBoards(DramaSource.hongguo, const [
        DiscoveryBoard('hot', '热播榜'),
      ]);
      await store.catalog.saveRankingColumn(
        DramaSource.hongguo,
        'hot',
        CachedDiscoveryColumn(
          [
            const DiscoveryRow(season, rank: 8),
            const DiscoveryRow(anchor, rank: 3),
          ],
          savedAt: store.now(),
          kind: DiscoveryKind.ranking,
        ),
      );
      expect(await file('records.json').readAsBytes(), recordBytes);
      final durable =
          jsonDecode(await file('records.json').readAsString()) as Map;
      expect(durable.keys, isNot(contains('discoveryCache')));
      final cached =
          jsonDecode(await file('catalog-cache.json').readAsString()) as Map;
      expect((cached['cache'] as Map)['discoveryCache'], isNotNull);
      final restored = makeStore(AppFileStorage(directory));
      addTearDown(restored.dispose);
      await restored.load();
      expect(
        restored.catalog.discoveryCache
            .recommendations(RecommendationGenre.shortPlay)!
            .rows
            .map((row) => row.drama.id),
        ['b', 'a'],
      );
      expect(
        restored.catalog.discoveryCache
            .boards(DramaSource.hongguo)!
            .boards
            .single
            .id,
        'hot',
      );
      expect(
        restored.catalog.discoveryCache
            .ranking(DramaSource.hongguo, 'hot')!
            .rows
            .map((row) => row.rank),
        [8, 3],
      );
      expect(restored.records.history[anchor.key]!.positionMs, 42);
    },
  );

  test(
    'fresh install ignores old state and writes only current partitions',
    () async {
      await FileStorage(directory).write(await savedState());
      final oldBytes = await file('state.json').readAsBytes();
      final storage = AppFileStorage(directory);
      expect(await storage.read(), isNull);
      await storage.write(await savedState());
      expect(await file('state.json').readAsBytes(), oldBytes);
      final restored = makeStore(AppFileStorage(directory));
      await restored.load();
      expect(restored.records.history[anchor.key]!.positionMs, 1);
      expect(restored.catalog.catalogPages[DramaSource.hongguo], 3);
      expect(restored.records.newEpisodeCount(anchor), 1);
      expect(restored.preferences.themeMode, ThemeMode.dark);
      expect(restored.preferences.progressivePreparation, true);
      expect(restored.preferences.playbackSpeed, 1.5);
      expect(restored.catalog.selectedCategories[DramaSource.huangguo], 'ai');
      expect(restored.records.favorites.keys, [anchor.key]);
      expect(restored.records.seasonReminders[anchor.key]!.unreadCount, 1);
      final durable =
          jsonDecode(await file('records.json').readAsString()) as Map;
      expect(durable.keys, isNot(contains('catalogs')));
      expect(durable.keys, isNot(contains('episodes')));
      final cached =
          jsonDecode(await file('catalog-cache.json').readAsString()) as Map;
      expect((cached['cache'] as Map).keys, isNot(contains('records')));
      expect((cached['cache'] as Map).keys, isNot(contains('episodeSeenIds')));
    },
  );

  test('records without a cache restore with an empty catalog', () async {
    await AppFileStorage(directory).writeRecords(await savedState());
    final restored = makeStore(AppFileStorage(directory));
    await restored.load();
    expect(restored.records.history[anchor.key]!.positionMs, 1);
    expect(restored.catalog.catalogs, isEmpty);
    expect(restored.cachePersistenceError, isNull);
  });

  test('saving a watch record leaves cache file bytes unchanged', () async {
    final store = makeStore(AppFileStorage(directory));
    await store.load();
    await store.catalog.saveRecommendations([anchor]);
    final before = await file('catalog-cache.json').readAsBytes();
    await store.records.saveWatch(watch(15000));
    expect(await file('catalog-cache.json').readAsBytes(), before);
    final restored = makeStore(AppFileStorage(directory));
    await restored.load();
    expect(
      restored.catalog.catalogs[DramaSource.hongguo]!.single.key,
      anchor.key,
    );
    expect(restored.records.history[anchor.key]!.positionMs, 15000);
  });

  test(
    'corrupt JSON cache cannot block durable records, settings or seen baselines',
    () async {
      await AppFileStorage(directory).write(await savedState());
      await file('catalog-cache.json').writeAsString('{broken');
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      expect(store.records.history[anchor.key]!.positionMs, 1);
      expect(store.preferences.themeMode, ThemeMode.dark);
      expect(store.records.episodeSeenIds[anchor.key], {'e1'});
      expect(store.records.seasonReminders.keys, [anchor.key]);
      expect(store.catalog.catalogs, isEmpty);
      expect(store.cachePersistenceError, isNotNull);
      await store.records.saveWatch(watch(2));
      expect(await file('catalog-cache.json').readAsString(), '{broken');
      await store.catalog.saveRecommendations([anchor]);
      expect(store.cachePersistenceError, isNull);
    },
  );

  test(
    'malformed cache rows and unknown cache versions are discarded independently',
    () async {
      await AppFileStorage(directory).write(await savedState());
      for (final bad in [
        {
          'format': 'guoguo.catalog-cache',
          'version': 1,
          'cache': {
            'catalogs': {
              'hongguo': [
                {'id': 'missing-title'},
              ],
            },
          },
        },
        {'format': 'guoguo.catalog-cache', 'version': 99, 'cache': {}},
      ]) {
        await file('catalog-cache.json').writeAsString(jsonEncode(bad));
        final store = makeStore(AppFileStorage(directory));
        await store.load();
        expect(store.records.history[anchor.key]!.positionMs, 1);
        expect(store.catalog.catalogs, isEmpty);
        expect(store.cachePersistenceError, isNotNull);
      }
    },
  );

  test('corrupt record file is preserved and never silently reset', () async {
    await AppFileStorage(directory).write(await savedState());
    await file('records.json').writeAsString('{broken');
    final restarted = makeStore(AppFileStorage(directory));
    await expectLater(restarted.load(), throwsFormatException);
    expect(restarted.records.history, isEmpty);
    expect(await file('records.json').readAsString(), '{broken');
  });

  test(
    'queued full writes detach inputs and preserve order in both files',
    () async {
      final storage = AppFileStorage(directory);
      final first = await savedState();
      final saving = storage.write(first);
      (first['records'] as Map)['history'] = [];
      first['catalogs'] = {};
      await saving;
      expect(
        ((await storage.read())!['records'] as Map)['history'],
        hasLength(1),
      );
      final second = await savedState(), third = await savedState();
      ((second['records'] as Map)['history'] as List).single['positionMs'] = 2;
      ((third['records'] as Map)['history'] as List).single['positionMs'] = 3;
      second['pages'] = {'hongguo': 2};
      third['pages'] = {'hongguo': 3};
      await Future.wait([storage.write(second), storage.write(third)]);
      final loaded = (await storage.read())!;
      expect(
        ((loaded['records'] as Map)['history'] as List).single['positionMs'],
        3,
      );
      expect(loaded['pages'], {'hongguo': 3});
    },
  );

  test(
    'failed atomic record write preserves previous file and allows retry',
    () async {
      final storage = AppFileStorage(directory);
      final store = makeStore(storage);
      await store.records.saveWatch(watch(1));
      final before = await file('records.json').readAsString();
      final obstacle = Directory('${directory.path}/records.json.tmp');
      await obstacle.create();
      await expectLater(
        store.records.saveWatch(watch(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file('records.json').readAsString(), before);
      await obstacle.delete();
      await store.records.saveWatch(watch(2));
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.records.history[anchor.key]!.positionMs, 2);
    },
  );

  test(
    'failed cache write preserves committed records and permits retry',
    () async {
      await AppFileStorage(directory).write(await savedState());
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      await store.records.saveWatch(watch(40000));
      final obstacle = Directory('${directory.path}/catalog-cache.json.tmp');
      await obstacle.create();
      await store.persist();
      expect(store.persistenceError, isNull);
      expect(store.cachePersistenceError, isNotNull);
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.records.history[anchor.key]!.positionMs, 40000);
      expect(restarted.catalog.catalogs[DramaSource.hongguo], hasLength(2));
      await obstacle.delete();
      await store.persist();
      expect(store.cachePersistenceError, isNull);
    },
  );
}
