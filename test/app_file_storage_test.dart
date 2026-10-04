import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
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

Future<Map<String, dynamic>> legacyState() async {
  final store = makeStore(MemoryStorage());
  await store.saveWatch(watch(1));
  await store.toggleFavorite(anchor);
  await store.setTheme(ThemeMode.dark);
  await store.setPlayback(progressive: true, speed: 1.5);
  store.selectedCategories[DramaSource.huangguo] = 'ai';
  store.catalogs[DramaSource.hongguo] = [anchor, season];
  store.catalogPages[DramaSource.hongguo] = 3;
  store.hasMore[DramaSource.hongguo] = true;
  store.episodeCache[anchor.key] = [
    const Episode(id: 'e1', title: '一', number: 1, raw: {'id': 'e1'}),
    const Episode(id: 'e2', title: '二', number: 2, raw: {'id': 'e2'}),
  ];
  store.episodeUpdatedAt[anchor.key] = DateTime.utc(2026);
  store.episodeSeenIds[anchor.key] = {'e1'};
  store.seasonReminders[anchor.key] = SeasonReminder(
    anchor: anchor,
    initialized: true,
    updatedAt: DateTime.utc(2026),
    seasons: {season.key: const SeasonNotice(season)},
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
    'legacy migration survives records-only interruption and retires old file after both commits',
    () async {
      await FileStorage(directory).write(await legacyState());
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      expect(store.newEpisodeCount(anchor), 1);
      await store.saveWatch(watch(42000));
      expect(await file('state.json').exists(), true);
      expect(await file('records.json').exists(), true);
      expect(await file('catalog-cache.json').exists(), false);
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.history[anchor.key]!.positionMs, 42000);
      expect(restarted.catalogPages[DramaSource.hongguo], 3);
      expect(restarted.newEpisodeCount(anchor), 1);
      expect(restarted.themeMode, ThemeMode.dark);
      expect(restarted.progressivePreparation, true);
      expect(restarted.playbackSpeed, 1.5);
      expect(restarted.selectedCategories[DramaSource.huangguo], 'ai');
      expect(restarted.favorites.keys, [anchor.key]);
      expect(
        restarted.seasonReminders[anchor.key]!.seasons[season.key]!.read,
        false,
      );
      await restarted.persist();
      expect(await file('state.json').exists(), false);
      final durable =
          jsonDecode(await file('records.json').readAsString()) as Map;
      expect(durable.keys, isNot(contains('catalogs')));
      expect(durable.keys, isNot(contains('episodes')));
      expect((durable['records'] as Map)['version'], 2);
      final cached =
          jsonDecode(await file('catalog-cache.json').readAsString()) as Map;
      expect((cached['cache'] as Map).keys, isNot(contains('records')));
      expect((cached['cache'] as Map).keys, isNot(contains('episodeSeenIds')));
      final finalStore = makeStore(AppFileStorage(directory));
      await finalStore.load();
      expect(finalStore.history[anchor.key]!.positionMs, 42000);
      expect(finalStore.newEpisodeCount(anchor), 1);
      expect(
        finalStore.seasonReminders[anchor.key]!.seasons[season.key]!.read,
        false,
      );
    },
  );

  test(
    'cache-only migration preserves legacy records until new records commit',
    () async {
      final legacy = await legacyState();
      await FileStorage(directory).write(legacy);
      final storage = AppFileStorage(directory);
      final loaded = (await storage.read())!;
      await storage.writeCache(loaded);
      expect(await file('state.json').exists(), true);
      expect(await file('records.json').exists(), false);
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.history[anchor.key]!.positionMs, 1);
      await restarted.saveWatch(watch(2));
      expect(await file('state.json').exists(), false);
    },
  );

  test('saving a watch record leaves cache file bytes unchanged', () async {
    final store = makeStore(AppFileStorage(directory));
    await store.load();
    await store.saveRecommendations([anchor]);
    final before = await file('catalog-cache.json').readAsBytes();
    await store.saveWatch(watch(15000));
    expect(await file('catalog-cache.json').readAsBytes(), before);
    final restored = makeStore(AppFileStorage(directory));
    await restored.load();
    expect(restored.catalogs[DramaSource.hongguo]!.single.key, anchor.key);
    expect(restored.history[anchor.key]!.positionMs, 15000);
  });

  test(
    'corrupt JSON cache cannot block durable records, settings or seen baselines',
    () async {
      await AppFileStorage(directory).write(await legacyState());
      await file('catalog-cache.json').writeAsString('{broken');
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      expect(store.history[anchor.key]!.positionMs, 1);
      expect(store.themeMode, ThemeMode.dark);
      expect(store.episodeSeenIds[anchor.key], {'e1'});
      expect(store.seasonReminders.keys, [anchor.key]);
      expect(store.catalogs, isEmpty);
      expect(store.cachePersistenceError, isNotNull);
      await store.saveWatch(watch(2));
      expect(await file('catalog-cache.json').readAsString(), '{broken');
      await store.saveRecommendations([anchor]);
      expect(store.cachePersistenceError, isNull);
    },
  );

  test(
    'malformed cache rows and unknown cache versions are discarded independently',
    () async {
      await AppFileStorage(directory).write(await legacyState());
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
        expect(store.history[anchor.key]!.positionMs, 1);
        expect(store.catalogs, isEmpty);
        expect(store.cachePersistenceError, isNotNull);
      }
    },
  );

  test(
    'corrupt authoritative record file never falls back to stale legacy history',
    () async {
      final legacy = await legacyState();
      await FileStorage(directory).write(legacy);
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      await store.saveWatch(watch(20000));
      await file('records.json').writeAsString('{broken');
      final restarted = makeStore(AppFileStorage(directory));
      await expectLater(restarted.load(), throwsFormatException);
      expect(restarted.history, isEmpty);
      expect(await file('records.json').readAsString(), '{broken');
      expect(await file('state.json').exists(), true);
    },
  );

  test(
    'a damaged legacy cache still permits migrating its valid records',
    () async {
      final state = await legacyState();
      state['catalogs'] = {'hongguo': 'broken'};
      await FileStorage(directory).write(state);
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      expect(store.history[anchor.key]!.positionMs, 1);
      expect(store.catalogs, isEmpty);
      expect(store.cachePersistenceError, isNotNull);
      await store.saveWatch(watch(2));
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.history[anchor.key]!.positionMs, 2);
    },
  );

  test(
    'queued full writes detach inputs and preserve order in both files',
    () async {
      final storage = AppFileStorage(directory);
      final first = await legacyState();
      final saving = storage.write(first);
      (first['records'] as Map)['history'] = [];
      first['catalogs'] = {};
      await saving;
      expect(
        ((await storage.read())!['records'] as Map)['history'],
        hasLength(1),
      );
      final second = await legacyState(), third = await legacyState();
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
      await store.saveWatch(watch(1));
      final before = await file('records.json').readAsString();
      final obstacle = Directory('${directory.path}/records.json.tmp');
      await obstacle.create();
      await expectLater(
        store.saveWatch(watch(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file('records.json').readAsString(), before);
      await obstacle.delete();
      await store.saveWatch(watch(2));
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.history[anchor.key]!.positionMs, 2);
    },
  );

  test(
    'failed cache migration retains legacy file and committed new watch position',
    () async {
      await FileStorage(directory).write(await legacyState());
      final store = makeStore(AppFileStorage(directory));
      await store.load();
      await store.saveWatch(watch(40000));
      final obstacle = Directory('${directory.path}/catalog-cache.json.tmp');
      await obstacle.create();
      await store.persist();
      expect(store.persistenceError, isNull);
      expect(store.cachePersistenceError, isNotNull);
      expect(await file('state.json').exists(), true);
      final restarted = makeStore(AppFileStorage(directory));
      await restarted.load();
      expect(restarted.history[anchor.key]!.positionMs, 40000);
      expect(restarted.catalogs[DramaSource.hongguo], hasLength(2));
      await obstacle.delete();
      await restarted.persist();
      expect(await file('state.json').exists(), false);
    },
  );
}
