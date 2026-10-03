import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/related_series_section.dart';

import 'season_reminders_test.dart'
    show firstSeason, secondSeason, thirdSeason, baseline;
import 'series_lookup_test.dart' show SeriesProvider;

class DelayedStorage extends MemoryStorage {
  final saved = Completer<void>();
  @override
  Future<void> write(Map<String, dynamic> next) async {
    await saved.future;
    await super.write(next);
  }
}

Future<void> mountSection(
  WidgetTester tester,
  AppStore store, {
  Future<void> Function(Drama)? onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: RelatedSeriesSection(
          store: store,
          drama: firstSeason,
          onOpen: onOpen ?? (_) async {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'finishing reminder persistence after background does not start a new lookup',
    (tester) async {
      final storage = DelayedStorage();
      final provider = SeriesProvider();
      final store = AppStore(storage: storage, provider: provider);
      await mountSection(tester, store);
      await tester.tap(find.text('提醒新季'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      storage.saved.complete();
      await tester.pumpAndSettle();
      expect(provider.searches, isEmpty);
      expect(store.seasonReminders[firstSeason.key]!.initialized, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    },
  );

  testWidgets(
    'partial native results appear while loading and are not a baseline',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider();
      provider.search = (_) => pending.future;
      provider.progress = (_) async => {
        'source': 'hongguo',
        'query': '山海',
        'items': [secondSeason.toJson()],
      };
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.toggleSeasonReminder(firstSeason);
      await mountSection(tester, store);
      await tester.tap(find.text('联网补全'));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.text(secondSeason.title), findsOneWidget);
      expect(store.seasonReminders[firstSeason.key]!.initialized, isFalse);
      await tester.tap(find.text('取消补全'));
      await tester.pump();
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await tester.pump();
      expect(store.searchCache.dramas, isEmpty);
      expect(find.text(thirdSeason.title), findsNothing);
    },
  );

  testWidgets(
    'entering background cancels manual completion without a late update',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider()..search = (_) => pending.future;
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await mountSection(tester, store);
      await tester.tap(find.text('联网补全'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(provider.cancelled, isNotEmpty);
      expect(find.text('取消补全'), findsNothing);
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await tester.pump();
      expect(store.relatedTo(firstSeason), isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached series appear immediately without starting a network request',
    (tester) async {
      final provider = SeriesProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      store.catalogs[DramaSource.hongguo] = [secondSeason];
      await mountSection(tester, store);
      expect(find.text(secondSeason.title), findsOneWidget);
      expect(find.text('联网补全'), findsOneWidget);
      expect(provider.searches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual completion establishes opted-in baseline and renders new-season notices',
    (tester) async {
      var rows = [secondSeason];
      final provider = SeriesProvider()
        ..search = (_) async => {'items': rows.map((d) => d.toJson()).toList()};
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await mountSection(tester, store);
      await tester.tap(find.text('提醒新季'));
      await tester.pumpAndSettle();
      expect(store.favorites, isEmpty);
      expect(store.seasonReminders[firstSeason.key]!.initialized, isTrue);
      expect(find.text('新季'), findsNothing);
      rows = [secondSeason, thirdSeason];
      await tester.tap(find.text('联网补全'));
      await tester.pumpAndSettle();
      expect(find.text(thirdSeason.title), findsOneWidget);
      expect(find.text('新季'), findsOneWidget);
      await tester.tap(find.text('关闭新季提醒'));
      await tester.pumpAndSettle();
      expect(store.seasonReminders, isEmpty);
    },
  );

  testWidgets(
    'leaving section cancels search and late completion cannot modify its baseline',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final provider = SeriesProvider()..search = (_) => pending.future;
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.toggleSeasonReminder(firstSeason);
      await mountSection(tester, store);
      await tester.tap(find.text('联网补全'));
      await tester.pump();
      expect(find.text('取消补全'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(provider.cancelled, isNotEmpty);
      pending.complete({
        'items': [thirdSeason.toJson()],
      });
      await tester.pump();
      expect(store.seasonReminders[firstSeason.key]!.initialized, isFalse);
      expect(store.relatedTo(firstSeason), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline and large text keep series and reminder controls usable on narrow screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(
        storage: MemoryStorage(),
        provider: SeriesProvider(),
      )..offline = true;
      store.catalogs[DramaSource.hongguo] = [secondSeason];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: RelatedSeriesSection(
                  store: store,
                  drama: firstSeason,
                  onOpen: (_) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('提醒新季'));
      await tester.pumpAndSettle();
      expect(store.seasonReminders[firstSeason.key]!.initialized, isFalse);
      expect(find.text(secondSeason.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening a season detail marks only that season read for all relevant reminders',
    (tester) async {
      final store = AppStore(
        storage: MemoryStorage(),
        provider: SeriesProvider(),
      )..offline = true;
      await baseline(store);
      await store.observeSeasons(
        firstSeason,
        const CatalogSearchResult([thirdSeason]),
      );
      await store.toggleSeasonReminder(secondSeason);
      await store.observeSeasons(secondSeason, const CatalogSearchResult([]));
      await store.observeSeasons(
        secondSeason,
        const CatalogSearchResult([thirdSeason]),
      );
      store.episodeCache[thirdSeason.key] = [
        Episode.fromJson({'id': 'episode'}, 0),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            store: store,
            downloads: DownloadStore(store),
            drama: thirdSeason,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        store.seasonReminders[firstSeason.key]!.seasons[thirdSeason.key]!.read,
        isTrue,
      );
      expect(
        store.seasonReminders[secondSeason.key]!.seasons[thirdSeason.key]!.read,
        isTrue,
      );
      expect(store.favorites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'personal page shows reminders without requiring any favorites and can check new seasons',
    (tester) async {
      final provider = SeriesProvider()
        ..search = (_) async => {
          'items': [thirdSeason.toJson()],
        };
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await baseline(store);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            store: store,
            downloads: DownloadStore(store),
            autoLoad: false,
          ),
        ),
      );
      await tester.tap(find.text('追剧').last);
      await tester.pumpAndSettle();
      expect(find.text('新季提醒'), findsOneWidget);
      await tester.ensureVisible(find.text('检查更新'));
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(store.seasonReminders[firstSeason.key]!.unreadCount, 1);
      expect(find.text('发现 1 部新季'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
