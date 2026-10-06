import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class SplitStorage implements PartitionedStorage {
  final records = MemoryStorage(), cache = MemoryStorage();
  int recordWrites = 0, cacheWrites = 0;
  bool failRecords = false, failCache = false;
  Completer<void>? cacheGate;
  @override
  String? get cacheReadError => null;
  @override
  Future<Map<String, dynamic>?> read() async =>
      records.value == null ? null : {...records.value!, ...?cache.value};
  @override
  Future<void> writeRecords(Map<String, dynamic> value) async {
    recordWrites++;
    if (failRecords) throw const FileSystemException('records disk full');
    await records.write(value);
  }

  @override
  Future<void> writeCache(Map<String, dynamic> value) async {
    cacheWrites++;
    final detached = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    await cacheGate?.future;
    if (failCache) throw const FileSystemException('cache disk full');
    await cache.write(detached);
  }

  @override
  Future<void> write(Map<String, dynamic> value) =>
      throw StateError('whole-document writes must not be used');
}

const drama = Drama(id: '1', source: DramaSource.hongguo, title: '作品第一季');
WatchRecord watch(
  int position, {
  Drama row = drama,
  String episode = 'e1',
  int index = 0,
  int duration = 100000,
  int day = 1,
}) => WatchRecord(
  drama: row,
  episodeId: episode,
  episodeIndex: index,
  positionMs: position,
  durationMs: duration,
  updatedAt: DateTime.utc(2026, 10, day),
);

class UnserializableCatalogRow extends Drama {
  const UnserializableCatalogRow()
    : super(id: 'catalog', source: DramaSource.hongguo, title: '缓存');
  @override
  Map<String, dynamic> toJson() => throw StateError('catalog was traversed');
}

class CountedWatch extends WatchRecord {
  CountedWatch(String id)
    : super(
        drama: Drama(id: id, source: DramaSource.hongguo, title: '作品 $id'),
        episodeId: 'e1',
        episodeIndex: 0,
        positionMs: 1,
        durationMs: 100,
        updatedAt: DateTime.utc(2026),
      );
  int encodings = 0;
  @override
  Map<String, dynamic> toJson() {
    encodings++;
    return super.toJson();
  }
}

void main() {
  test(
    'identical progress skips disk, notifications and timestamp changes',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      var notifications = 0;
      store.records.progress.addListener(() => notifications++);
      await store.records.saveWatch(watch(12000));
      await store.records.saveWatch(watch(12000, day: 2));
      expect(storage.recordWrites, 1);
      expect(storage.cacheWrites, 0);
      expect(notifications, 1);
      expect(
        store.records.history[drama.key]!.updatedAt,
        DateTime.utc(2026, 10, 1),
      );
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      await restored.records.saveWatch(watch(12000, day: 3));
      expect(storage.recordWrites, 1);
    },
  );

  test(
    'backward seek, episode mapping, duration and metadata remain saved',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      await store.records.saveWatch(watch(8000, duration: 0));
      await store.records.saveWatch(watch(8000));
      await store.records.saveWatch(watch(1000));
      await store.records.saveWatch(watch(1000, index: 2));
      await store.records.saveWatch(watch(1000, index: 2, episode: 'e2'));
      final updated = Drama.fromJson({...drama.toJson(), 'cover': 'new-cover'});
      await store.records.saveWatch(
        watch(1000, index: 2, episode: 'e2', row: updated),
      );
      // Equal tags from different list instances do not cause redundant saves.
      final equal = Drama.fromJson(updated.toJson());
      await store.records.saveWatch(
        watch(1000, index: 2, episode: 'e2', row: equal),
      );
      expect(storage.recordWrites, 6);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      final record = restored.records.history[drama.key]!;
      expect(record.positionMs, 1000);
      expect(record.episodeId, 'e2');
      expect(record.episodeIndex, 2);
      expect(record.durationMs, 100000);
      expect(record.drama.cover, 'new-cover');
    },
  );

  test('record saves never serialize catalog and episode cache', () async {
    final storage = SplitStorage();
    final store = AppStore(storage: storage, provider: NoNetwork());
    store.catalog.catalogs[DramaSource.hongguo] = [
      const UnserializableCatalogRow(),
    ];
    store.catalog.episodeCache[drama.key] = [
      Episode(id: 'e1', title: '一', number: 1, raw: {'unsupported': Object()}),
    ];
    await store.records.saveWatch(watch(1));
    await store.records.toggleFavorite(drama);
    await store.records.toggleSeasonReminder(drama);
    await store.records.markEpisodesSeen(
      drama,
      store.catalog.episodeCache[drama.key]!,
    );
    expect(storage.cacheWrites, 0);
    expect(storage.records.value!.keys, isNot(contains('catalogs')));
    expect(storage.records.value!.keys, isNot(contains('episodes')));
    expect(storage.records.value!['episodeSeenIds'], {
      drama.key: ['e1'],
    });
  });

  test(
    'unchanged history rows reuse serialization and removed rows are evicted',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      final first = CountedWatch('first'), second = CountedWatch('second');
      await store.records.saveWatch(first);
      await store.records.saveWatch(second);
      await store.records.saveWatch(watch(1));
      await store.records.saveWatch(watch(2));
      expect(first.encodings, 1);
      expect(second.encodings, 1);
      await store.records.removeHistory(first.drama.key);
      await store.records.saveWatch(first);
      expect(first.encodings, 2);
      final exported = jsonDecode(store.records.exportBackup()) as Map;
      expect(exported['history'], hasLength(3));
    },
  );

  test(
    'mutable public snapshots and failed backup import cannot poison cached rows',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      await store.records.saveWatch(watch(10));
      final snapshot = store.snapshot();
      ((snapshot['records'] as Map)['history'] as List).single['positionMs'] =
          999;
      await store.records.toggleFavorite(drama);
      expect(
        ((storage.records.value!['records'] as Map)['history'] as List)
            .single['positionMs'],
        10,
      );
      storage.failRecords = true;
      await expectLater(
        store.records.importBackup(RecordBackup([], [watch(50, day: 2)])),
        throwsA(isA<FileSystemException>()),
      );
      storage.failRecords = false;
      await store.persist(cache: false);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      expect(restored.records.history[drama.key]!.positionMs, 10);
    },
  );

  test('an unchanged position retries after a failed record write', () async {
    final storage = SplitStorage();
    final store = AppStore(storage: storage, provider: NoNetwork());
    await store.records.saveWatch(watch(1));
    storage.failRecords = true;
    await expectLater(
      store.records.saveWatch(watch(2)),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.persistenceError, isNotNull);
    storage.failRecords = false;
    await store.records.saveWatch(watch(2, day: 2));
    expect(storage.recordWrites, 3);
    expect(store.persistenceError, isNull);
    final restored = AppStore(storage: storage, provider: NoNetwork());
    await restored.load();
    expect(restored.records.history[drama.key]!.positionMs, 2);
  });

  test('slow cache persistence does not block final watch save', () async {
    final storage = SplitStorage();
    final store = AppStore(storage: storage, provider: NoNetwork());
    await store.persist(cache: false);
    storage.cacheGate = Completer();
    final savingCache = store.catalog.saveRecommendations([drama]);
    await store.records
        .saveWatch(watch(42000))
        .timeout(const Duration(seconds: 2));
    expect(storage.cacheGate!.isCompleted, false);
    expect(
      ((storage.records.value!['records'] as Map)['history'] as List)
          .single['positionMs'],
      42000,
    );
    storage.cacheGate!.complete();
    await savingCache;
  });

  test(
    'cache-only writes bootstrap durable state for a fresh installation',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      await store.load();
      await store.catalog.saveRecommendations([drama]);
      expect(storage.recordWrites, 1);
      expect(storage.cacheWrites, 1);
      await store.catalog.saveRecommendations([drama]);
      expect(storage.recordWrites, 1);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      expect(
        restored.catalog.catalogs[DramaSource.hongguo]!.single.key,
        drama.key,
      );
    },
  );

  test(
    'cache failure leaves committed records, reminders and record errors independent',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      await store.records.saveWatch(watch(1));
      await store.records.toggleSeasonReminder(drama);
      storage.failCache = true;
      await store.persist();
      expect(store.persistenceError, isNull);
      expect(store.cachePersistenceError, isNotNull);
      await store.records.saveWatch(watch(2));
      expect(store.cachePersistenceError, isNotNull);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      expect(restored.records.history[drama.key]!.positionMs, 2);
      expect(restored.records.seasonReminders.keys, [drama.key]);
      storage.failCache = false;
      storage.failRecords = true;
      await expectLater(
        store.records.saveWatch(watch(3)),
        throwsA(isA<FileSystemException>()),
      );
      await store.catalog.saveRecommendations([drama]);
      expect(store.persistenceError, isNotNull);
      expect(store.cachePersistenceError, isNull);
    },
  );

  test(
    'failed cache import rolls back its rows without changing durable records',
    () async {
      final storage = SplitStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      await store.records.saveWatch(watch(1));
      final recordWrites = storage.recordWrites;
      storage.failCache = true;
      await expectLater(
        store.catalog.importLibraryRows([drama]),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.catalog.catalogs, isEmpty);
      expect(store.records.history[drama.key]!.positionMs, 1);
      expect(storage.recordWrites, recordWrites);
      expect(store.persistenceError, isNull);
      expect(store.cachePersistenceError, isNotNull);
    },
  );
}
