import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';

import 'widget_test.dart' show NoNetwork;

class CountingStorage extends MemoryStorage {
  int writes = 0;
  bool fail = false;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    if (fail) throw const FileSystemException('disk full');
    await super.write(value);
  }
}

const drama = Drama(
  id: 'record',
  source: DramaSource.hongguo,
  title: '记录资料',
  tags: ['都市', '情感'],
);

WatchRecord watch({int number = 6, bool completed = false}) => WatchRecord(
  drama: drama,
  episodeId: 'e2',
  episodeIndex: 1,
  episodeNumber: number,
  episodeCompleted: completed,
  positionMs: 42000,
  durationMs: 100000,
  updatedAt: DateTime.utc(2026, 10, 7),
);

void main() {
  test(
    'equal metadata avoids writes and retains cached history objects',
    () async {
      final storage = CountingStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(store.dispose);
      await store.records.toggleFavorite(drama);
      await store.records.saveWatch(watch());
      final original = store.records.history[drama.key]!;
      final writes = storage.writes;
      var notifications = 0;
      store.records.addListener(() => notifications++);
      await store.records.updateDrama(Drama.fromJson(drama.toJson()));
      expect(storage.writes, writes);
      expect(notifications, 0);
      expect(store.records.history[drama.key], same(original));
    },
  );

  test(
    'changed metadata updates all saved references and preserves progress',
    () async {
      final storage = CountingStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(store.dispose);
      await store.records.toggleFavorite(drama);
      await store.records.saveWatch(watch(completed: true));
      final writes = storage.writes;
      final updated = Drama.fromJson({...drama.toJson(), 'tags': <String>[]});
      await store.records.updateDrama(updated);
      expect(storage.writes, writes + 1);
      expect(store.records.favorites[drama.key]!.tags, isEmpty);
      final record = store.records.history[drama.key]!;
      expect(record.drama.tags, isEmpty);
      expect(record.episodeId, 'e2');
      expect(record.episodeNumber, 6);
      expect(record.episodeCompleted, true);
      expect(record.positionMs, 42000);
      expect(record.updatedAt, watch().updatedAt);
    },
  );

  test('identical metadata retries an earlier failed save', () async {
    final storage = CountingStorage();
    final store = AppStore(storage: storage, provider: NoNetwork());
    addTearDown(store.dispose);
    await store.records.saveWatch(watch());
    final updated = Drama.fromJson({...drama.toJson(), 'cover': 'new-cover'});
    storage.fail = true;
    await expectLater(
      store.records.updateDrama(updated),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.persistenceError, isNotNull);
    var notifications = 0;
    store.records.addListener(() => notifications++);
    storage.fail = false;
    await store.records.updateDrama(Drama.fromJson(updated.toJson()));
    expect(store.persistenceError, isNull);
    expect(notifications, 1);
    final restored = AppStore(storage: storage, provider: NoNetwork());
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.records.history[drama.key]!.drama.cover, 'new-cover');
  });

  test(
    'corrected episode numbers persist even when progress is unchanged',
    () async {
      final storage = CountingStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(store.dispose);
      await store.records.saveWatch(watch());
      await store.records.saveWatch(watch(number: 10));
      expect(storage.writes, 2);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(restored.dispose);
      await restored.load();
      final record = restored.records.history[drama.key]!;
      expect(record.episodeNumber, 10);
      expect(restored.catalog.episodeCache, isEmpty);
      expect(restored.records.episodeNumberFor(record), 10);
      expect(record.positionMs, 42000);
      expect(
        () => WatchRecord.fromJson({...record.toJson(), 'episodeNumber': -1}),
        throwsFormatException,
      );
    },
  );

  test(
    'episode labels match IDs and never infer numbers from list positions',
    () {
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      addTearDown(store.dispose);
      store.catalog.episodeCache[drama.key] = [
        Episode.fromJson({'id': 'e2', 'currentEpisode': 10}, 0),
        Episode.fromJson({'id': 'e1', 'currentEpisode': 2}, 1),
      ];
      expect(store.records.episodeNumberFor(watch()), 10);
      final unknown = WatchRecord(
        drama: drama,
        episodeId: 'missing',
        episodeIndex: 1,
        positionMs: 42000,
        durationMs: 100000,
        updatedAt: DateTime.utc(2026, 10, 7),
      );
      expect(store.records.episodeNumberFor(unknown), isNull);
    },
  );

  test(
    'completion changes persist, retry after failure and survive backup',
    () async {
      final storage = CountingStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(store.dispose);
      await store.records.saveWatch(watch());
      storage.fail = true;
      await expectLater(
        store.records.saveWatch(watch(completed: true)),
        throwsA(isA<FileSystemException>()),
      );
      storage.fail = false;
      await store.records.saveWatch(watch(completed: true));
      expect(storage.writes, 3);
      expect(store.persistenceError, isNull);
      await store.records.saveWatch(watch(completed: true));
      expect(storage.writes, 3);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.history[drama.key]!.episodeCompleted, true);
      final backup = store.records.inspectBackup(store.records.exportBackup());
      expect(backup.history.single.episodeCompleted, true);
      final old = watch(completed: true).toJson()..remove('episodeCompleted');
      expect(WatchRecord.fromJson(old).episodeCompleted, false);
    },
  );

  test(
    'unchanged seen IDs skip writes; a failed update remains retryable',
    () async {
      final storage = CountingStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(store.dispose);
      final episodes = [
        Episode.fromJson({'id': 'e1'}, 0),
        Episode.fromJson({'id': 'e2'}, 1),
      ];
      await store.records.markEpisodesSeen(drama, episodes);
      final writes = storage.writes;
      var notifications = 0;
      store.records.addListener(() => notifications++);
      await store.records.markEpisodesSeen(drama, episodes.reversed.toList());
      expect(storage.writes, writes);
      expect(notifications, 0);
      final added = [
        ...episodes,
        Episode.fromJson({'id': 'e3'}, 2),
      ];
      storage.fail = true;
      await expectLater(
        store.records.markEpisodesSeen(drama, added),
        throwsA(isA<FileSystemException>()),
      );
      storage.fail = false;
      await store.records.markEpisodesSeen(drama, added);
      expect(store.persistenceError, isNull);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.episodeSeenIds[drama.key], {'e1', 'e2', 'e3'});
    },
  );
}
