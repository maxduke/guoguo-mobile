import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/discovery_cache.dart';
import 'package:guoguo_mobile/data/preferences_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/source_selector.dart';

class _Provider implements ProviderClient {
  final calls = <String>[];
  Map<String, dynamic>? catalog;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add(method);
    if (method == 'catalog' && catalog != null) return catalog!;
    throw StateError('unexpected request $method');
  }
}

class _Storage extends MemoryStorage {
  int writes = 0;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    await super.write(value);
  }
}

class _PendingStorage extends MemoryStorage {
  Completer<void> gate = Completer<void>();
  @override
  Future<void> write(Map<String, dynamic> value) async {
    await gate.future;
    await super.write(value);
  }
}

AppStore _store({
  LocalStorage? storage,
  _Provider? provider,
  DateTime Function()? now,
}) => AppStore(
  storage: storage ?? MemoryStorage(),
  provider: provider ?? _Provider(),
  now: now,
);

Widget _app(
  AppStore store,
  List<DramaSource?> choices, {
  double scale = 1,
  double keyboard = 0,
}) => MaterialApp(
  theme: ThemeData.dark(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: ListenableBuilder(
      listenable: store.catalog,
      builder: (context, _) => SourceSelector(
        value: store.catalog.source,
        preferences: store.preferences,
        catalog: store.catalog,
        onChanged: (source) {
          choices.add(source);
          if (source != null) unawaited(store.catalog.selectSource(source));
        },
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester, {bool manage = false}) async {
  await tester.tap(
    find.descendant(
      of: find.byType(SourceSelector),
      matching: find.byType(OutlinedButton),
    ),
  );
  await tester.pumpAndSettle();
  if (manage) {
    await tester.tap(find.byTooltip('管理站源'));
    await tester.pumpAndSettle();
  }
}

Future<void> _fixture(
  WidgetTester tester,
  List<AppStore> stores, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final store in stores) {
      final storage = store.storage;
      if (storage is _PendingStorage && !storage.gate.isCompleted) {
        storage.gate.complete();
      }
    }
    await tester.pump();
    for (final store in stores) {
      store.dispose();
    }
  });
}

void main() {
  test(
    'source selections are deduplicated, bounded, and persisted once without provider requests',
    () async {
      final storage = _Storage(), provider = _Provider();
      final store = _store(storage: storage, provider: provider);
      addTearDown(store.dispose);
      for (final source in DramaSource.values) {
        await store.catalog.selectSource(source);
      }
      await store.catalog.selectSource(DramaSource.huangdou);
      await store.catalog.selectSource(DramaSource.wuguo);
      expect(storage.writes, DramaSource.values.length + 2);
      expect(store.preferences.recentSources, [
        DramaSource.wuguo,
        DramaSource.huangdou,
        DramaSource.shuangguo,
        DramaSource.miguo,
        DramaSource.chaoguo,
        DramaSource.piguo,
      ]);
      final restored = _store(storage: storage);
      addTearDown(restored.dispose);
      await restored.load();
      expect(
        restored.preferences.recentSources,
        store.preferences.recentSources,
      );
      expect(restored.catalog.source, DramaSource.wuguo);
      expect(provider.calls, isEmpty);
      expect(
        () => store.preferences.recentSources.add(DramaSource.hongguo),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'source preferences survive removal of disposable cache and preserve saved records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'guoguo-source-preferences-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = AppFileStorage(directory),
          store = _store(storage: AppFileStorage(directory));
      addTearDown(store.dispose);
      const drama = Drama(
        id: 'saved',
        source: DramaSource.wuguo,
        title: '已保存故事',
      );
      await store.records.toggleFavorite(drama);
      await store.preferences.toggleFavoriteSource(DramaSource.wuguo);
      await store.preferences.setSourceHidden(DramaSource.wuguo, true);
      await store.catalog.selectSource(DramaSource.wuguo);
      await storage.writeCache({'catalogs': {}});
      final records =
          jsonDecode(
                await File('${directory.path}/records.json').readAsString(),
              )
              as Map;
      final cache =
          jsonDecode(
                await File(
                  '${directory.path}/catalog-cache.json',
                ).readAsString(),
              )
              as Map;
      expect(records['favoriteSources'], ['wuguo']);
      expect(records['hiddenSources'], ['wuguo']);
      expect((cache['cache'] as Map).containsKey('favoriteSources'), isFalse);
      await File('${directory.path}/catalog-cache.json').delete();
      final restored = _store(storage: storage);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.preferences.favoriteSources, {DramaSource.wuguo});
      expect(restored.preferences.hiddenSources, {DramaSource.wuguo});
      expect(restored.records.favorites.keys, [drama.key]);
      expect(
        () => restored.preferences.favoriteSources.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'invalid persisted source preferences cannot partially reset preferences',
    () async {
      final preferences = PreferencesStore(save: () async {});
      addTearDown(preferences.dispose);
      await preferences.setTheme(ThemeMode.dark);
      await preferences.toggleFavoriteSource(DramaSource.hongguo);
      for (final invalid in [
        {
          'favoriteSources': ['wuguo'],
          'hiddenSources': ['unknown'],
        },
        {'favoriteSources': false},
        {
          'recentSources': List.filled(
            DramaSource.values.length + 1,
            'hongguo',
          ),
        },
      ]) {
        expect(
          () => preferences.restore({'theme': 'light', ...invalid}),
          throwsA(anything),
        );
        expect(preferences.themeMode, ThemeMode.dark);
        expect(preferences.favoriteSources, {DramaSource.hongguo});
        expect(preferences.hiddenSources, isEmpty);
      }
    },
  );

  test(
    'content observation ignores board-only records, expired data and does not promote cache entries',
    () {
      var now = DateTime.utc(2026, 10, 9, 8);
      final cache = DiscoveryCache(now: () => now);
      cache.putBoards(DramaSource.huangdou, [
        const DiscoveryBoard('a', '公开栏目'),
      ], now);
      expect(cache.lastContentRetrieval(DramaSource.huangdou), isNull);
      cache.putRecommendations(
        RecommendationGenre.shortPlay,
        [],
        now.subtract(const Duration(minutes: 30)),
      );
      for (var i = 0; i < DiscoveryCache.maxColumns - 1; i++) {
        cache.putRanking(
          DramaSource.huangdou,
          '$i',
          CachedDiscoveryColumn([], savedAt: now, kind: DiscoveryKind.catalog),
        );
      }
      expect(
        cache.lastContentRetrieval(DramaSource.hongguo),
        now.subtract(const Duration(minutes: 30)),
      );
      cache.putRanking(
        DramaSource.huangdou,
        'new',
        CachedDiscoveryColumn([], savedAt: now, kind: DiscoveryKind.catalog),
      );
      expect(cache.recommendations(RecommendationGenre.shortPlay), isNull);
      expect(cache.lastContentRetrieval(DramaSource.huangdou), now);
      now = now.add(const Duration(days: 8));
      expect(cache.lastContentRetrieval(DramaSource.huangdou), isNull);
    },
  );

  testWidgets(
    'favorites, recents and current hidden source are reachable without duplicate choices',
    (tester) async {
      final store = _store(), choices = <DramaSource?>[];
      await _fixture(tester, [store]);
      await store.preferences.toggleFavoriteSource(DramaSource.wuguo);
      await store.catalog.selectSource(DramaSource.wuguo);
      await store.catalog.selectSource(DramaSource.hongguo);
      await store.preferences.setSourceHidden(DramaSource.hongguo, true);
      await tester.pumpWidget(_app(store, choices));
      await _open(tester);
      expect(find.text('常用站源'), findsOneWidget);
      expect(find.text('最近选择'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '伍果'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '红果'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '红果'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pumpAndSettle();
      expect(choices, [DramaSource.wuguo]);
      expect(store.catalog.source, DramaSource.wuguo);
      expect((store.provider as _Provider).calls, isEmpty);
    },
  );

  testWidgets(
    'hidden sources remain searchable and can be restored explicitly',
    (tester) async {
      final store = _store(), choices = <DramaSource?>[];
      await _fixture(tester, [store]);
      await store.preferences.setSourceHidden(DramaSource.wuguo, true);
      await tester.pumpWidget(_app(store, choices));
      await _open(tester);
      expect(find.widgetWithText(ChoiceChip, '伍果'), findsNothing);
      await tester.enterText(find.byType(TextField), ' WUGUO ');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '伍果'), findsOneWidget);
      await tester.tap(find.byTooltip('管理站源'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('恢复站源伍果'));
      await tester.pumpAndSettle();
      expect(store.preferences.hiddenSources, isEmpty);
      await tester.tap(find.byTooltip('返回站源选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pumpAndSettle();
      expect(choices, [DramaSource.wuguo]);
      expect((store.provider as _Provider).calls, isEmpty);
    },
  );

  testWidgets(
    'management shows actual capabilities, content timestamp and directory warning without probing',
    (tester) async {
      final now = DateTime.utc(2026, 10, 9, 8),
          provider = _Provider()
            ..catalog = {'items': [], 'hasMore': false, 'warning': '部分分类暂不可用'};
      final store = _store(provider: provider, now: () => now);
      await _fixture(tester, [store]);
      await store.catalog.refresh();
      provider.catalog = {'items': [], 'hasMore': false};
      await store.catalog.refresh(DramaSource.huangju);
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        [],
        now,
      );
      store.catalog.discoveryCache.putBoards(DramaSource.huangdou, [
        const DiscoveryBoard('a', '栏目'),
      ], now);
      await tester.pumpWidget(_app(store, []));
      await _open(tester, manage: true);
      expect(find.text('剧库提示：部分分类暂不可用'), findsOneWidget);
      expect(find.textContaining('栏目上次获取'), findsOneWidget);
      expect(find.text('本地搜名 · 本地分类 · 栏目入口'), findsOneWidget);
      expect(find.text('剧库提示：分类暂时无法加载，请重试'), findsOneWidget);
      expect(provider.calls, ['catalog', 'categories', 'catalog']);
      expect(find.text('健康'), findsNothing);
    },
  );

  testWidgets(
    'pending preference save is atomic and failures retry the same desired values',
    (tester) async {
      final storage = _PendingStorage();
      final working = _store(storage: storage);
      await _fixture(tester, [working]);
      await tester.pumpWidget(_app(working, []));
      await _open(tester, manage: true);
      await tester.tap(find.byTooltip('收藏站源红果'));
      await tester.pump();
      expect(working.preferences.favoriteSources, {DramaSource.hongguo});
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('隐藏站源红果'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      storage.gate.completeError(const FileSystemException('private path'));
      await tester.pumpAndSettle();
      expect(find.text('站源设置尚未保存，请重试'), findsOneWidget);
      expect(find.textContaining('private path'), findsNothing);
      storage.gate = Completer<void>();
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      storage.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('重试保存'), findsNothing);
      expect(working.preferences.favoriteSources, {DramaSource.hongguo});
      expect(storage.value!['favoriteSources'], ['hongguo']);
      expect(working.persistenceError, isNull);
    },
  );

  for (final manage in [false, true]) {
    testWidgets(
      'replacing dependencies ignores old sheet ${manage ? 'mutations' : 'selections'}',
      (tester) async {
        final old = _store(), next = _store(), choices = <DramaSource?>[];
        await _fixture(tester, [old, next]);
        await tester.pumpWidget(_app(old, choices));
        await _open(tester, manage: manage);
        await tester.pumpWidget(_app(next, choices));
        await tester.pumpAndSettle();
        await tester.tap(
          manage
              ? find.byTooltip('收藏站源红果')
              : find.widgetWithText(ChoiceChip, '伍果'),
        );
        await tester.pumpAndSettle();
        expect(find.text('页面已更新，请关闭后重新选择站源'), findsOneWidget);
        expect(choices, isEmpty);
        expect(old.preferences.favoriteSources, isEmpty);
        expect(next.preferences.favoriteSources, isEmpty);
        expect(next.catalog.source, DramaSource.hongguo);
        await tester.tap(find.byTooltip('关闭站源选择'));
        await tester.pumpAndSettle();
        await _open(tester, manage: manage);
        await tester.tap(
          manage
              ? find.byTooltip('收藏站源红果')
              : find.widgetWithText(ChoiceChip, '伍果'),
        );
        await tester.pumpAndSettle();
        if (manage) {
          expect(next.preferences.favoriteSources, {DramaSource.hongguo});
        } else {
          expect(choices, [DramaSource.wuguo]);
        }
        expect((old.provider as _Provider).calls, isEmpty);
        expect((next.provider as _Provider).calls, isEmpty);
      },
    );
  }

  testWidgets(
    'late saving failure after closing the sheet does not update a disposed view',
    (tester) async {
      final storage = _PendingStorage();
      final working = _store(storage: storage);
      await _fixture(tester, [working]);
      await tester.pumpWidget(_app(working, []));
      await _open(tester, manage: true);
      await tester.tap(find.byTooltip('收藏站源红果'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      storage.gate.completeError(const FileSystemException('private path'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in [
    (size: const Size(320, 740), scale: 2.0, keyboard: 300.0),
    (size: const Size(1024, 768), scale: 1.0, keyboard: 0.0),
  ]) {
    testWidgets('source management remains operable with $layout', (
      tester,
    ) async {
      final store = _store(), choices = <DramaSource?>[];
      await _fixture(tester, [store], size: layout.size);
      await tester.pumpWidget(
        _app(store, choices, scale: layout.scale, keyboard: layout.keyboard),
      );
      await _open(tester, manage: true);
      await tester.enterText(find.byType(TextField), '伍果');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byTooltip('收藏站源伍果'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('收藏站源伍果'));
      await tester.pumpAndSettle();
      expect(store.preferences.favoriteSources, {DramaSource.wuguo});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'configured groups fit large text and entering management resets its scroll',
    (tester) async {
      final store = _store();
      await _fixture(tester, [store], size: const Size(320, 740));
      await store.preferences.toggleFavoriteSource(DramaSource.wuguo);
      await store.preferences.setSourceHidden(DramaSource.niuguo, true);
      await store.catalog.selectSource(DramaSource.yaguo);
      await store.catalog.selectSource(DramaSource.hongguo);
      await tester.pumpWidget(_app(store, [], scale: 2, keyboard: 300));
      await _open(tester);
      await tester.scrollUntilVisible(
        find.text('已隐藏 1 个站源'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('已隐藏 1 个站源'));
      await tester.pumpAndSettle();
      expect(find.text('站源管理').hitTestable(), findsOneWidget);
      expect(find.byTooltip('返回站源选择').hitTestable(), findsOneWidget);
      expect((store.provider as _Provider).calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'record source filters retain hidden sources and the all-source option',
    (tester) async {
      final store = _store(), choices = <DramaSource?>[];
      await _fixture(tester, [store]);
      await store.preferences.setSourceHidden(DramaSource.wuguo, true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceFilter(value: null, onChanged: choices.add),
          ),
        ),
      );
      await _open(tester);
      expect(find.widgetWithText(ChoiceChip, '全部站源'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '伍果'), findsOneWidget);
      expect(find.byTooltip('管理站源'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pumpAndSettle();
      expect(choices, [DramaSource.wuguo]);
    },
  );
}
