import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

const watched = Drama(id: 'a', source: DramaSource.hongguo, title: '故事第一季');
const imported = Drama(
  id: 'imported',
  source: DramaSource.hongguo,
  title: '导入作品',
);
const added = Drama(id: 'new', source: DramaSource.hongguo, title: '新增收藏');
const second = Drama(id: 'b', source: DramaSource.hongguo, title: '故事第二季');
WatchRecord watch(int position) => WatchRecord(
  drama: watched,
  episodeId: 'e',
  episodeIndex: 0,
  positionMs: position,
  durationMs: 100000,
  updatedAt: DateTime.utc(2026, 10, 7, 0, 0, position),
);

class NoNetwork implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => throw StateError('unexpected network');
}

class WriteGate {
  WriteGate({this.fail = false});
  final bool fail;
  final entered = Completer<void>();
  final release = Completer<void>();
}

class GatedFiles implements PartitionedStorage {
  GatedFiles(Directory root) : files = AppFileStorage(root);
  final AppFileStorage files;
  WriteGate? next;
  Future<void> _queue = Future.value();
  @override
  String? get cacheReadError => files.cacheReadError;
  @override
  Future<Map<String, dynamic>?> read() => files.read();
  @override
  Future<void> writeCache(Map<String, dynamic> value) =>
      files.writeCache(value);
  @override
  Future<void> write(Map<String, dynamic> value) async {
    await Future.wait([writeRecords(value), writeCache(value)]);
  }

  @override
  Future<void> writeRecords(Map<String, dynamic> value) {
    final snapshot = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
    final gate = next;
    next = null;
    final operation = _queue.catchError((Object _) {}).then((_) async {
      if (gate != null) {
        gate.entered.complete();
        await gate.release.future;
        if (gate.fail) throw const FileSystemException('full disk');
      }
      await files.writeRecords(snapshot);
    });
    _queue = operation;
    return operation;
  }
}

AppStore create(LocalStorage storage) => AppStore(
  storage: storage,
  provider: NoNetwork(),
  now: () => DateTime.utc(2026, 10, 7, 1),
);

void main() {
  late Directory root;
  late GatedFiles storage;
  late AppStore app;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('record-transactions-');
    storage = GatedFiles(root);
    app = create(storage);
    await app.records.saveWatch(watch(10));
    await app.records.toggleFavorite(watched);
  });
  tearDown(() async {
    app.dispose();
    await root.delete(recursive: true);
  });

  test(
    'failed import cannot roll back later edits or leak into queued snapshots',
    () async {
      final gate = storage.next = WriteGate(fail: true);
      final importing = app.records.importBackup(
        RecordBackup([imported], [watch(20)]),
      );
      final failure = expectLater(
        importing,
        throwsA(isA<FileSystemException>()),
      );
      await gate.entered.future;
      final savingWatch = app.records.saveWatch(watch(30));
      final adding = app.records.toggleFavorite(added);
      final removing = app.records.toggleFavorite(watched);
      final preferences = app.preferences.setTheme(ThemeMode.dark);
      gate.release.complete();
      await failure;
      await Future.wait([savingWatch, adding, removing, preferences]);
      expect(app.records.history[watched.key]!.positionMs, 30);
      expect(app.records.favorites.keys, [added.key]);
      final restored = create(storage.files);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.history[watched.key]!.positionMs, 30);
      expect(restored.records.favorites.keys, [added.key]);
      expect(restored.preferences.themeMode, ThemeMode.dark);
    },
  );

  test(
    'candidate is invisible until committed and later deletion wins on restart',
    () async {
      final gate = storage.next = WriteGate();
      final importing = app.records.importBackup(
        RecordBackup([imported], [watch(20)]),
      );
      await gate.entered.future;
      final visibleImport = app.records.favorites.containsKey(imported.key);
      final visiblePosition = app.records.history[watched.key]!.positionMs;
      final deleting = app.records.removeHistory(watched.key);
      gate.release.complete();
      await Future.wait([importing, deleting]);
      expect(visibleImport, false);
      expect(visiblePosition, 10);
      expect(app.records.history, isEmpty);
      final restored = create(storage.files);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.history, isEmpty);
      expect(
        restored.records.favorites.keys,
        containsAll([watched.key, imported.key]),
      );
    },
  );

  test(
    'queued imports detach their input and preserve intervening edits',
    () async {
      final gate = storage.next = WriteGate();
      final saving = app.persist(cache: false);
      await gate.entered.future;
      final favorites = [imported];
      final first = app.records.importBackup(
        RecordBackup(favorites, [watch(20)]),
      );
      favorites.clear();
      final watching = app.records.saveWatch(watch(30));
      final next = app.records.importBackup(RecordBackup([added], [watch(25)]));
      gate.release.complete();
      await Future.wait([
        saving,
        first,
        watching,
        next,
      ]).timeout(const Duration(seconds: 5));
      final restored = create(storage.files);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.history[watched.key]!.positionMs, 30);
      expect(
        restored.records.favorites.keys,
        containsAll([watched.key, imported.key, added.key]),
      );
    },
  );

  test(
    'failed import leaves reminders intact and a queued read is durable',
    () async {
      await app.records.toggleSeasonReminder(watched);
      await app.records.observeSeasons(watched, const CatalogSearchResult([]));
      await app.records.observeSeasons(
        watched,
        const CatalogSearchResult([second]),
      );
      final gate = storage.next = WriteGate(fail: true);
      final importing = app.records.importBackup(RecordBackup([imported], []));
      final failed = expectLater(
        importing,
        throwsA(isA<FileSystemException>()),
      );
      await gate.entered.future;
      final reading = app.records.markSeasonRead(second.key);
      gate.release.complete();
      await failed;
      await reading;
      await app.records.importBackup(RecordBackup([added], []));
      final restored = create(storage.files);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.seasonReminders[watched.key]!.unreadCount, 0);
      expect(restored.records.favorites.keys, contains(added.key));
      expect(restored.records.favorites.keys, isNot(contains(imported.key)));
    },
  );

  test(
    'metadata writes wait behind import without resurrecting failed rows',
    () async {
      final gate = storage.next = WriteGate(fail: true);
      final importing = app.records.importBackup(
        RecordBackup([imported], [watch(20)]),
      );
      final failed = expectLater(
        importing,
        throwsA(isA<FileSystemException>()),
      );
      await gate.entered.future;
      final updating = app.records.updateDrama(
        const Drama(id: 'a', source: DramaSource.hongguo, title: '新资料'),
      );
      final baseline = app.records.episodesUpdated(watched, [
        Episode.fromJson({'id': 'e'}, 0),
      ]);
      gate.release.complete();
      await failed;
      await Future.wait([updating, baseline]);
      final restored = create(storage.files);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.history[watched.key]!.positionMs, 10);
      expect(restored.records.history[watched.key]!.drama.title, '新资料');
      expect(restored.records.episodeSeenIds[watched.key], {'e'});
      expect(restored.records.favorites.keys, isNot(contains(imported.key)));
    },
  );

  test(
    'record collections and seen sets cannot bypass the write queue',
    () async {
      expect(
        () => app.records.favorites[added.key] = added,
        throwsUnsupportedError,
      );
      expect(() => app.records.history.clear(), throwsUnsupportedError);
      expect(() => app.records.seasonReminders.clear(), throwsUnsupportedError);
      await app.records.markEpisodesSeen(watched, [
        Episode.fromJson({'id': 'e'}, 0),
      ]);
      expect(
        () => app.records.episodeSeenIds[watched.key]!.add('other'),
        throwsUnsupportedError,
      );
      expect(
        () => app.records.restore(RecordBackup([], []), {}),
        throwsStateError,
      );
    },
  );

  test(
    'operations accepted before disposal finish without late notifications',
    () async {
      final closing = create(storage);
      await closing.load();
      final gate = storage.next = WriteGate();
      final importing = closing.records.importBackup(
        RecordBackup([imported], []),
      );
      await gate.entered.future;
      final saving = closing.records.saveWatch(watch(30));
      closing.dispose();
      gate.release.complete();
      await Future.wait([importing, saving]);
      await expectLater(closing.records.saveWatch(watch(40)), throwsStateError);
      final restored = create(storage.files);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.history[watched.key]!.positionMs, 30);
      expect(restored.records.favorites.keys, contains(imported.key));
    },
  );
}
