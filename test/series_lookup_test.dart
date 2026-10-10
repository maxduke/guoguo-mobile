import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/series_lookup.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

import 'season_reminders_test.dart' show firstSeason, secondSeason, thirdSeason;

class SeriesProvider implements ProviderClient {
  final searches = <Map<String, dynamic>>[];
  final cancelled = <String>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? search;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? progress;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? chapters;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'search') {
      searches.add(Map.of(args));
      return search?.call(args) ??
          {
            'items': [secondSeason.toJson()],
          };
    }
    if (method == 'cancelSearch') {
      cancelled.add(args['requestId'] as String);
      return {};
    }
    if (method == 'searchProgress') {
      return progress?.call(args) ?? {'items': []};
    }
    if (method == 'chapters') return chapters?.call(args) ?? {'items': []};
    return {};
  }
}

AppStore searchStore(SeriesProvider provider) =>
    AppStore(storage: MemoryStorage(), provider: provider);

void main() {
  test(
    'season cursors continue limited pages until a complete check',
    () async {
      final provider = SeriesProvider()
        ..search = (args) async => {
          'items': [(args['page'] == 1 ? secondSeason : thirdSeason).toJson()],
          'hasMore': args['page'] == 1,
          'limited': args['page'] == 1,
          'continuation': args['page'] == 1 ? 'cursor-one' : '',
        };
      final store = searchStore(provider);
      addTearDown(store.dispose);
      await store.records.toggleSeasonReminder(firstSeason);
      final result = await store.catalog.lookupSeries(firstSeason).result;
      expect(provider.searches.length, 2);
      expect(provider.searches.last['continuation'], 'cursor-one');
      expect(result.items.map((d) => d.key), [
        secondSeason.key,
        thirdSeason.key,
      ]);
      expect(result.hasMore, isFalse);
      expect(result.limited, isFalse);
      await store.records.observeSeasons(firstSeason, result);
      expect(
        store.records.seasonReminders[firstSeason.key]!.initialized,
        isTrue,
      );
      expect(store.records.seasonReminders[firstSeason.key]!.unreadCount, 0);
      expect(store.catalog.recentSearches, isEmpty);
      expect(
        store.catalog.searchCache.toJson().toString(),
        isNot(contains('cursor-one')),
      );
    },
  );

  test('cursor page limit keeps a season reminder baseline pending', () async {
    final provider = SeriesProvider()
      ..search = (args) async => {
        'items': [secondSeason.toJson()],
        'hasMore': true,
        'limited': true,
        'continuation': 'cursor-${args['page']}',
      };
    final store = searchStore(provider);
    addTearDown(store.dispose);
    await store.records.toggleSeasonReminder(firstSeason);
    final result = await store.catalog.lookupSeries(firstSeason).result;
    expect(provider.searches.length, 3);
    expect(provider.searches.last['continuation'], 'cursor-2');
    expect(result.hasMore, isTrue);
    expect(result.limited, isTrue);
    await store.records.observeSeasons(firstSeason, result);
    expect(
      store.records.seasonReminders[firstSeason.key]!.initialized,
      isFalse,
    );
  });

  test(
    'persisted unfinished season results restart the native search',
    () async {
      final provider = SeriesProvider();
      final store = searchStore(provider);
      addTearDown(store.dispose);
      store.catalog.searchCache.put(
        'hongguo|山海|1',
        const CatalogSearchResult(
          [secondSeason],
          hasMore: true,
          continuation: 'old-core-cursor',
        ),
        store.now(),
      );
      expect(
        store.catalog.searchCache.toJson().toString(),
        isNot(contains('old-core-cursor')),
      );
      final result = await store.catalog.lookupSeries(firstSeason).result;
      expect(provider.searches.length, 1);
      expect(provider.searches.single['continuation'], isNull);
      expect(result.items.single.key, secondSeason.key);
    },
  );

  test(
    'a read made during a check survives while another newly found season is retained',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider()..search = (_) => pending.future;
      final store = searchStore(provider);
      await store.records.toggleSeasonReminder(firstSeason);
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([secondSeason]),
      );
      await store.records.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason]),
      );
      final checking = store.records.checkFavoriteUpdates();
      await store.records.markSeasonRead(thirdSeason.key);
      const fourth = Drama(
        id: 'four',
        source: DramaSource.hongguo,
        title: '山海第四季',
      );
      pending.complete({
        'items': [thirdSeason.toJson(), fourth.toJson()],
      });
      await checking;
      final reminder = store.records.seasonReminders[firstSeason.key]!;
      expect(reminder.seasons[thirdSeason.key]!.read, isTrue);
      expect(reminder.seasons[fourth.key]!.read, isFalse);
      expect(reminder.unreadCount, 1);
    },
  );

  test(
    'result budget is visible and does not create a baseline from truncated seasons',
    () async {
      final provider = SeriesProvider()
        ..search = (_) async => {
          'items': [
            for (var i = 0; i < 201; i++)
              Drama(
                id: 'version-$i',
                source: DramaSource.hongguo,
                title: '山海第二季',
              ).toJson(),
          ],
        };
      final store = searchStore(provider);
      await store.records.toggleSeasonReminder(firstSeason);
      final result = await store.catalog.lookupSeries(firstSeason).result;
      expect(result.items.length, 200);
      expect(result.limited, isTrue);
      await store.records.observeSeasons(firstSeason, result);
      expect(
        store.records.seasonReminders[firstSeason.key]!.initialized,
        isFalse,
      );
      provider.search = (_) async => {'items': []};
      final cachedResult = await store.catalog
          .lookupSeries(firstSeason, refresh: true)
          .result;
      expect(cachedResult.items.length, 200);
      expect(cachedResult.limited, isTrue);
    },
  );

  test(
    'lookup searches base title, preserves pagination and never adds automatic recent queries',
    () async {
      final provider = SeriesProvider()
        ..search = (args) async => {
          'items': [
            (args['page'] == 1 ? secondSeason : thirdSeason).toJson(),
            const Drama(
              id: 'noise',
              source: DramaSource.hongguo,
              title: '山海传奇第二季',
            ).toJson(),
          ],
          'hasMore': args['page'] == 1,
        };
      final store = searchStore(provider);
      final result = await store.catalog.lookupSeries(firstSeason).result;
      expect(result.items.map((d) => d.key), [
        secondSeason.key,
        thirdSeason.key,
      ]);
      expect(result.hasMore, isFalse);
      expect(provider.searches.map((r) => r['query']), ['山海', '山海']);
      expect(provider.searches.map((r) => r['page']), [1, 2]);
      expect(store.catalog.recentSearches, isEmpty);
      expect(
        store.catalog.searchCache
            .read('hongguo|山海|1', DateTime.now())!
            .result
            .hasMore,
        isTrue,
      );
    },
  );

  test(
    'offline lookup uses persisted candidates without establishing baseline',
    () async {
      final provider = SeriesProvider();
      final store = searchStore(provider)..offline = true;
      store.catalog.catalogs[DramaSource.hongguo] = [secondSeason];
      await store.records.toggleSeasonReminder(firstSeason);
      final result = await store.catalog.lookupSeries(firstSeason).result;
      await store.records.observeSeasons(firstSeason, result);
      expect(result.items.single.key, secondSeason.key);
      expect(result.limited, isTrue);
      expect(provider.searches, isEmpty);
      expect(
        store.records.seasonReminders[firstSeason.key]!.initialized,
        isFalse,
      );
    },
  );

  test(
    'cancelled lookup completes promptly and its late native result cannot enter catalogs',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider()..search = (_) => pending.future;
      final store = searchStore(provider);
      final lookup = store.catalog.lookupSeries(firstSeason);
      final check = expectLater(
        lookup.result,
        throwsA(isA<SeriesLookupCancelled>()),
      );
      lookup.cancel();
      await check;
      expect(
        provider.cancelled,
        contains(provider.searches.single['requestId']),
      );
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await Future<void>.delayed(Duration.zero);
      expect(store.catalog.relatedTo(firstSeason), isEmpty);
      expect(store.catalog.searchCache.dramas, isEmpty);
      expect(store.catalog.recentSearches, isEmpty);
    },
  );

  test(
    'owners of the same query have separate cancellation and result lifetimes',
    () async {
      final pending = <Completer<Map<String, dynamic>>>[];
      final provider = SeriesProvider()
        ..search = (_) {
          final next = Completer<Map<String, dynamic>>();
          pending.add(next);
          return next.future;
        };
      final store = searchStore(provider);
      final one = store.catalog.lookupSeries(firstSeason);
      final two = store.catalog.lookupSeries(firstSeason);
      expect(
        provider.searches[0]['requestId'],
        isNot(provider.searches[1]['requestId']),
      );
      final cancelled = expectLater(
        one.result,
        throwsA(isA<SeriesLookupCancelled>()),
      );
      one.cancel();
      await cancelled;
      pending[1].complete({
        'items': [thirdSeason.toJson()],
      });
      expect((await two.result).items.single.key, thirdSeason.key);
      pending[0].complete({
        'items': [secondSeason.toJson()],
      });
      await Future<void>.delayed(Duration.zero);
      expect(store.catalog.relatedTo(firstSeason).map((d) => d.key), [
        thirdSeason.key,
      ]);
    },
  );

  test(
    'lookup stops at the page budget and leaves first-check baseline pending',
    () async {
      final provider = SeriesProvider()
        ..search = (args) async => {
          'items': [secondSeason.toJson()],
          'hasMore': true,
        };
      final store = searchStore(provider);
      await store.records.toggleSeasonReminder(firstSeason);
      final result = await store.catalog.lookupSeries(firstSeason).result;
      expect(provider.searches.length, 3);
      expect(result.hasMore, isTrue);
      await store.records.observeSeasons(firstSeason, result);
      expect(
        store.records.seasonReminders[firstSeason.key]!.initialized,
        isFalse,
      );
    },
  );

  testWidgets(
    'twenty-second budget cancels native lookup even if it never replies',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider()..search = (_) => pending.future;
      final store = searchStore(provider);
      final lookup = store.catalog.lookupSeries(firstSeason);
      final result = expectLater(
        lookup.result,
        throwsA(isA<ProviderException>()),
      );
      await tester.pump(const Duration(seconds: 20));
      await result;
      expect(
        provider.cancelled,
        contains(provider.searches.single['requestId']),
      );
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await tester.pump();
      expect(store.catalog.searchCache.dramas, isEmpty);
    },
  );

  testWidgets(
    'progress polls do not overlap and cannot publish after cancellation',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final peek = Completer<Map<String, dynamic>>();
      var polls = 0, partials = 0;
      final provider = SeriesProvider();
      provider.search = (_) => pending.future;
      provider.progress = (_) {
        polls++;
        return peek.future;
      };
      final store = searchStore(provider);
      final lookup = store.catalog.lookupSeries(
        firstSeason,
        onPartial: (_) => partials++,
      );
      final cancelled = expectLater(
        lookup.result,
        throwsA(isA<SeriesLookupCancelled>()),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(seconds: 3));
      expect(polls, 1);
      lookup.cancel();
      await cancelled;
      peek.complete({
        'source': 'hongguo',
        'query': '山海',
        'items': [thirdSeason.toJson()],
      });
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await tester.pump();
      expect(partials, 0);
      expect(store.catalog.relatedTo(firstSeason), isEmpty);
    },
  );

  test(
    'update checks reuse same-unit search across anchors and still include that search anchor',
    () async {
      final provider = SeriesProvider()
        ..search = (_) async => {
          'items': [thirdSeason.toJson(), firstSeason.toJson()],
        };
      final store = searchStore(provider);
      await store.records.toggleSeasonReminder(secondSeason);
      await store.records.toggleSeasonReminder(firstSeason);
      await store.records.checkFavoriteUpdates();
      expect(provider.searches.length, 1);
      expect(
        store.records.seasonReminders[firstSeason.key]!.seasons.keys,
        contains(secondSeason.key),
      );
      expect(store.records.seasonReminders[secondSeason.key]!.seasons.keys, [
        thirdSeason.key,
      ]);
    },
  );

  test(
    'cancelling an update check prevents late baseline updates and later queries',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider()..search = (_) => pending.future;
      final store = searchStore(provider);
      await store.records.toggleSeasonReminder(firstSeason);
      await store.records.toggleSeasonReminder(
        const Drama(id: 'else', source: DramaSource.hongguo, title: '另一部第一季'),
      );
      final checking = store.records.checkFavoriteUpdates();
      store.records.cancelUpdateChecks();
      expect(await checking, isFalse);
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await Future<void>.delayed(Duration.zero);
      expect(provider.searches.length, 1);
      expect(
        store.records.seasonReminders.values.every((r) => !r.initialized),
        isTrue,
      );
      expect(store.records.checkingUpdates, isFalse);
    },
  );
}
