import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

const _drama = Drama(
  id: 'huangguo:result',
  source: DramaSource.huangguo,
  title: '原资料',
);
const _old = Episode(id: 'old', title: '原分集', number: 1, raw: {'id': 'old'});

class _Storage extends MemoryStorage implements PartitionedStorage {
  bool failCache = true, failRecords = false;
  @override
  String? get cacheReadError => null;
  @override
  Future<void> writeRecords(Map<String, dynamic> value) async {
    if (failRecords) throw const FileSystemException('private record failure');
    await super.write(value);
  }

  @override
  Future<void> writeCache(Map<String, dynamic> value) async {
    if (failCache) throw const FileSystemException('private cache failure');
  }
}

class _Provider implements ProviderClient {
  int chapterCalls = 0, detailCalls = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'detail') {
      detailCalls++;
      return {
        'item': {..._drama.toJson(), 'title': '更新资料'},
      };
    }
    if (method == 'chapters') {
      chapterCalls++;
      return {
        'chapters': [
          _old.raw,
          {'id': 'new', 'currentEpisode': 2},
        ],
      };
    }
    throw StateError('unexpected request');
  }
}

void main() {
  for (final cached in [false, true]) {
    for (final refresh in [false, true]) {
      test(
        'cache write failure keeps valid chapters cached=$cached refresh=$refresh',
        () async {
          final storage = _Storage(), provider = _Provider();
          final store = AppStore(storage: storage, provider: provider);
          addTearDown(store.dispose);
          if (cached) {
            store.catalog.episodeCache[_drama.key] = [_old];
            store.catalog.episodeUpdatedAt[_drama.key] = DateTime(2000);
          }
          final rows = await store.catalog.episodes(_drama, refresh: refresh);
          expect(rows.map((e) => e.id), ['old', 'new']);
          expect(store.catalog.episodeCache[_drama.key], same(rows));
          expect(store.catalog.episodeErrors, isEmpty);
          expect(store.cachePersistenceError, isNotNull);
          expect(store.persistenceError, isNull);
          expect(
            store.records.episodeSeenIds[_drama.key],
            cached ? {'old'} : {'old', 'new'},
          );
          await store.catalog.episodes(_drama);
          expect(provider.chapterCalls, 1);
          expect(store.sourceDiagnostics.samples.last.validation, 'passed');
        },
      );
    }
  }

  test(
    'cache failure keeps updated detail and committed favorite metadata',
    () async {
      final storage = _Storage(), provider = _Provider();
      final store = AppStore(storage: storage, provider: provider);
      addTearDown(store.dispose);
      await store.records.toggleFavorite(_drama);
      final updated = await store.catalog.refreshDetail(_drama, force: true);
      expect(updated.title, '更新资料');
      expect(store.catalog.detailErrors, isEmpty);
      expect(store.cachePersistenceError, isNotNull);
      expect(store.persistenceError, isNull);
      final restored = AppStore(storage: storage, provider: provider);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.favorites[_drama.key]!.title, '更新资料');
      await store.catalog.refreshDetail(_drama);
      expect(provider.detailCalls, 1);
    },
  );

  test(
    'cache recovery clears its notice without repeating a failed request',
    () async {
      final storage = _Storage(), provider = _Provider();
      final store = AppStore(storage: storage, provider: provider);
      addTearDown(store.dispose);
      await store.catalog.episodes(_drama, refresh: true);
      storage.failCache = false;
      await store.catalog.episodes(_drama, refresh: true);
      expect(store.cachePersistenceError, isNull);
      expect(store.catalog.episodeErrors, isEmpty);
      expect(provider.chapterCalls, 2);
    },
  );

  test(
    'record write failure remains observable and is not swallowed as a cache failure',
    () async {
      final storage = _Storage()..failRecords = true;
      final store = AppStore(storage: storage, provider: _Provider());
      addTearDown(store.dispose);
      await expectLater(
        store.catalog.episodes(_drama, refresh: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.persistenceError, isNotNull);
      expect(store.cachePersistenceError, isNull);
      expect(store.sourceDiagnostics.samples.single.result, 'success');
      expect(store.sourceDiagnostics.samples.single.validation, 'passed');
    },
  );
}
