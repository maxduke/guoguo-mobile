import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/catalog_query.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/series_title.dart';

import 'widget_test.dart' show NoNetwork;

const firstSeason = Drama(
  id: 'one',
  source: DramaSource.hongguo,
  title: '山海第一季',
);
const secondSeason = Drama(
  id: 'two',
  source: DramaSource.hongguo,
  title: '山海第二季',
);
const thirdSeason = Drama(
  id: 'three',
  source: DramaSource.hongguo,
  title: '山海第三季',
);

class FailingStorage extends MemoryStorage {
  bool fail = false;
  @override
  Future<void> write(Map<String, dynamic> next) async {
    if (fail) throw const FileSystemExceptionForTest();
    await super.write(next);
  }
}

class FileSystemExceptionForTest implements Exception {
  const FileSystemExceptionForTest();
}

AppStore makeStore([LocalStorage? storage, DateTime Function()? now]) =>
    AppStore(
      storage: storage ?? MemoryStorage(),
      provider: NoNetwork(),
      now: now,
    );

Future<void> baseline(AppStore store) async {
  await store.records.toggleSeasonReminder(firstSeason);
  await store.records.observeSeasons(
    firstSeason,
    const CatalogSearchResult([secondSeason]),
  );
}

void main() {
  test(
    'backup merge rejects a combined reminder count above the saved-format limit atomically',
    () async {
      final store = makeStore();
      for (var i = 0; i < 1000; i++) {
        final anchor = Drama(
          id: 'anchor-$i',
          source: DramaSource.hongguo,
          title: '作品 $i 第一季',
        );
        store.records.seasonReminders[anchor.key] = SeasonReminder(
          anchor: anchor,
          updatedAt: DateTime.utc(2026),
        );
      }
      await expectLater(
        store.records.importBackup(
          RecordBackup(
            [firstSeason],
            [],
            seasonReminders: [
              SeasonReminder(
                anchor: firstSeason,
                updatedAt: DateTime.utc(2026),
              ),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(store.records.seasonReminders.length, 1000);
      expect(store.records.favorites, isEmpty);
    },
  );

  test(
    'series titles recognize numerals, width and punctuation without mixing units',
    () {
      for (final title in ['山海 第十季！', '山海第１０季', '山海第一〇季']) {
        final info = SeriesTitle.parse(title)!;
        expect(info.key, '山海');
        expect(info.season, 10);
        expect(info.unit, '季');
      }
      expect(SeriesTitle.parse('山海第两百季')!.season, 200);
      expect(SeriesTitle.parse('山海第201季'), isNull);
      expect(SeriesTitle.parse('山海第零季'), isNull);
      expect(SeriesTitle.parse('山海第十百季'), isNull);
      expect(SeriesTitle.parse('山海第1十季'), isNull);
      final rows = relatedSeries(firstSeason, [
        thirdSeason,
        secondSeason,
        secondSeason,
        const Drama(id: 'part', source: DramaSource.hongguo, title: '山海第二部'),
        const Drama(id: 'other', source: DramaSource.huangguo, title: '山海第二季'),
        const Drama(id: 'noise', source: DramaSource.hongguo, title: '山海传奇第二季'),
      ]);
      expect(rows.map((d) => d.id), ['two', 'three']);
    },
  );

  test(
    'bare title is a first season only with an unambiguous same-source unit',
    () {
      const bare = Drama(id: 'bare', source: DramaSource.hongguo, title: '山海');
      expect(
        relatedSeries(bare, [thirdSeason, secondSeason]).map((d) => d.id),
        ['two', 'three'],
      );
      expect(
        relatedSeries(bare, [
          secondSeason,
          const Drama(id: 'part', source: DramaSource.hongguo, title: '山海第二部'),
        ]),
        isEmpty,
      );
    },
  );

  test(
    'reminder is independent of favorites and initial complete check establishes baseline',
    () async {
      final store = makeStore();
      await store.records.toggleFavorite(firstSeason);
      expect(store.records.seasonReminders, isEmpty);
      await baseline(store);
      expect(
        store.records.seasonReminders[firstSeason.key]!.initialized,
        isTrue,
      );
      expect(store.records.seasonReminders[firstSeason.key]!.unreadCount, 0);
      await store.records.toggleFavorite(firstSeason);
      expect(store.records.seasonReminders, isNotEmpty);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason, secondSeason]),
      );
      expect(store.records.seasonReminders[firstSeason.key]!.unreadCount, 1);
      expect(store.records.favorites, isEmpty);
    },
  );

  test(
    'partial, warning and paged results cannot establish a misleading baseline',
    () async {
      final store = makeStore();
      await store.records.toggleSeasonReminder(firstSeason);
      for (final result in [
        const CatalogSearchResult([secondSeason], limited: true),
        const CatalogSearchResult([secondSeason], hasMore: true),
        const CatalogSearchResult([secondSeason], warning: '部分失败'),
      ]) {
        await store.records.observeSeasons(firstSeason, result);
        expect(
          store.records.seasonReminders[firstSeason.key]!.initialized,
          isFalse,
        );
        expect(store.records.seasonReminders[firstSeason.key]!.unreadCount, 0);
      }
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([secondSeason]),
      );
      expect(
        store
            .records
            .seasonReminders[firstSeason.key]!
            .seasons[secondSeason.key]!
            .read,
        isTrue,
      );
    },
  );

  test(
    'new-season notices survive missing results and preserve read status after restart',
    () async {
      final storage = MemoryStorage();
      final store = makeStore(storage);
      await baseline(store);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason], limited: true),
      );
      expect(store.records.seasonReminders[firstSeason.key]!.unreadCount, 1);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([]),
      );
      expect(store.records.seasonReminders[firstSeason.key]!.unreadCount, 1);
      await store.records.markSeasonRead(thirdSeason.key);
      final restored = makeStore(storage);
      await restored.load();
      await restored.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason]),
      );
      expect(restored.records.seasonReminders[firstSeason.key]!.unreadCount, 0);
      expect(
        restored.records.seasonReminders[firstSeason.key]!.seasons.keys,
        containsAll([secondSeason.key, thirdSeason.key]),
      );
    },
  );

  test(
    'a late observation cannot recreate a disabled or newly enabled reminder',
    () async {
      final store = makeStore();
      await baseline(store);
      final old = store.records.seasonReminders[firstSeason.key]!;
      await store.records.toggleSeasonReminder(firstSeason);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason]),
        expected: old,
      );
      expect(store.records.seasonReminders, isEmpty);
      await store.records.toggleSeasonReminder(firstSeason);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason]),
        expected: old,
      );
      expect(
        store.records.seasonReminders[firstSeason.key]!.initialized,
        isFalse,
      );
    },
  );

  test(
    'checking an older season cannot generate notices at or below its anchor',
    () async {
      final store = makeStore();
      await store.records.toggleSeasonReminder(thirdSeason);
      await store.records.observeSeasons(
        thirdSeason,
        const CatalogSearchResult([firstSeason, secondSeason]),
      );
      expect(store.records.seasonReminders[thirdSeason.key]!.seasons, isEmpty);
    },
  );

  test('record backups use v2 and preserve latest reminder state', () async {
    var date = DateTime.utc(2026, 10, 3);
    final source = makeStore(null, () => date);
    await baseline(source);
    date = date.add(const Duration(minutes: 1));
    await source.records.observeSeasons(
      firstSeason,
      const CatalogSearchResult([thirdSeason]),
    );
    final unread = source.records.inspectBackup(source.records.exportBackup());
    expect(jsonDecode(source.records.exportBackup())['version'], 2);
    date = date.add(const Duration(minutes: 1));
    await source.records.markSeasonRead(thirdSeason.key);
    final read = source.records.inspectBackup(source.records.exportBackup());
    final restored = makeStore();
    await restored.records.importBackup(unread);
    await restored.records.importBackup(read);
    await restored.records.importBackup(unread);
    expect(restored.records.seasonReminders[firstSeason.key]!.unreadCount, 0);
    final withoutReminders = restored.records.inspectBackup(
      jsonEncode(RecordBackup([firstSeason], []).toJson()),
    );
    await restored.records.importBackup(withoutReminders);
    expect(restored.records.favorites, contains(firstSeason.key));
    expect(restored.records.seasonReminders[firstSeason.key]!.unreadCount, 0);
  });

  test(
    'empty reminders retain the current schema and old versions are rejected',
    () async {
      final store = makeStore();
      final exported =
          jsonDecode(store.records.exportBackup()) as Map<String, dynamic>;
      expect(exported['version'], 2);
      expect(exported['seasonReminders'], isEmpty);
      expect(store.snapshot()['records'], exported);
      for (final version in [1, 99]) {
        expect(
          () => store.records.inspectBackup(
            jsonEncode({...exported, 'version': version}),
          ),
          throwsFormatException,
        );
      }
      exported.remove('seasonReminders');
      expect(
        () => store.records.inspectBackup(jsonEncode(exported)),
        throwsFormatException,
      );
    },
  );

  test(
    'invalid reminder backup is rejected before changing any existing record',
    () async {
      final store = makeStore();
      await baseline(store);
      final raw =
          jsonDecode(store.records.exportBackup()) as Map<String, dynamic>;
      raw['seasonReminders'][0]['seasons'][secondSeason.key]['drama']['title'] =
          '另一部第二季';
      expect(
        () => store.records.inspectBackup(jsonEncode(raw)),
        throwsFormatException,
      );
      expect(
        store
            .records
            .seasonReminders[firstSeason.key]!
            .seasons[secondSeason.key]!
            .drama
            .title,
        secondSeason.title,
      );
    },
  );

  test(
    'failed enable, read, observation and import restore previous reminder state',
    () async {
      final storage = FailingStorage();
      final store = makeStore(storage);
      storage.fail = true;
      await expectLater(
        store.records.toggleSeasonReminder(firstSeason),
        throwsA(isA<FileSystemExceptionForTest>()),
      );
      expect(store.records.seasonReminders, isEmpty);
      storage.fail = false;
      await baseline(store);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason]),
      );
      final old = store.records.seasonReminders[firstSeason.key];
      storage.fail = true;
      await expectLater(
        store.records.markSeasonRead(thirdSeason.key),
        throwsA(isA<FileSystemExceptionForTest>()),
      );
      expect(store.records.seasonReminders[firstSeason.key], same(old));
      await expectLater(
        store.records.observeSeasons(
          firstSeason,
          const CatalogSearchResult([]),
        ),
        throwsA(isA<FileSystemExceptionForTest>()),
      );
      expect(store.records.seasonReminders[firstSeason.key], same(old));
      await expectLater(
        store.records.importBackup(
          RecordBackup(
            [],
            [],
            seasonReminders: [
              SeasonReminder(
                anchor: thirdSeason,
                updatedAt: DateTime.utc(2026, 10, 4),
              ),
            ],
          ),
        ),
        throwsA(isA<FileSystemExceptionForTest>()),
      );
      expect(store.records.seasonReminders.keys, [firstSeason.key]);
    },
  );
}
