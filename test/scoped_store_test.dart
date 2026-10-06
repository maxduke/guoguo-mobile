import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';

const drama = Drama(id: 'a', source: DramaSource.hongguo, title: '独立状态第一季');
WatchRecord watch(int position) => WatchRecord(
  drama: drama,
  episodeId: 'e1',
  episodeIndex: 0,
  positionMs: position,
  durationMs: 100000,
  updatedAt: DateTime.utc(2026, 10, 6),
);

class Provider implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'catalog') {
      return {
        'items': [drama.toJson()],
        'hasMore': false,
      };
    }
    throw StateError('unexpected request $method');
  }
}

class FailingStorage extends MemoryStorage {
  bool fail = false;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw StateError('disk full');
    await super.write(value);
  }
}

void main() {
  test(
    'catalog, records, watch progress, preferences and theme notify independently',
    () async {
      final store = AppStore(storage: MemoryStorage(), provider: Provider());
      addTearDown(store.dispose);
      var status = 0,
          catalog = 0,
          records = 0,
          progress = 0,
          preferences = 0,
          theme = 0;
      store.addListener(() => status++);
      store.catalog.addListener(() => catalog++);
      store.records.addListener(() => records++);
      store.records.progress.addListener(() => progress++);
      store.preferences.addListener(() => preferences++);
      store.preferences.theme.addListener(() => theme++);

      await store.catalog.refresh();
      expect(catalog, 2);
      expect([status, records, progress, preferences, theme], [0, 0, 0, 0, 0]);
      await store.records.toggleFavorite(drama);
      expect(records, 1);
      await store.records.saveWatch(watch(42000));
      await store.records.saveWatch(watch(42000));
      expect(progress, 1);
      expect([catalog, records, preferences], [2, 1, 0]);
      await store.preferences.setPlayback(speed: 1.5);
      expect([catalog, records, progress, preferences, theme], [2, 1, 1, 1, 0]);
      await store.preferences.setTheme(ThemeMode.dark);
      expect([preferences, theme, status], [2, 1, 0]);
    },
  );

  test(
    'recovering record persistence clears the status without notifying preferences',
    () async {
      final storage = FailingStorage();
      final store = AppStore(storage: storage, provider: Provider());
      addTearDown(store.dispose);
      var status = 0, preferences = 0;
      store.addListener(() => status++);
      store.preferences.addListener(() => preferences++);
      storage.fail = true;
      await expectLater(store.records.saveWatch(watch(1)), throwsStateError);
      expect(store.persistenceError, isNotNull);
      storage.fail = false;
      await store.records.saveWatch(watch(1));
      expect(store.persistenceError, isNull);
      expect(status, 2);
      expect(preferences, 0);
    },
  );

  testWidgets(
    'progress and favorites update locally without rebuilding the app or catalog search',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(storage: MemoryStorage(), provider: Provider());
      store.catalog.catalogs[DramaSource.hongguo] = [drama];
      await store.records.saveWatch(watch(1000));
      final downloads = DownloadStore(store);
      await tester.pumpWidget(
        GuoguoApp(store: store, downloads: downloads, autoLoad: false),
      );
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final search = tester.widget<TextField>(find.byType(TextField));
      final heading = tester.widget<Text>(find.text('发现好剧'));
      expect(find.textContaining('已看 1%'), findsOneWidget);

      await store.records.saveWatch(watch(42000));
      await tester.pumpAndSettle();
      expect(find.textContaining('已看 42%'), findsOneWidget);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
      expect(tester.widget<TextField>(find.byType(TextField)), same(search));
      expect(tester.widget<Text>(find.text('发现好剧')), same(heading));

      await store.records.toggleFavorite(drama);
      await tester.pumpAndSettle();
      expect(
        tester.widget<DramaCard>(find.byType(DramaCard).first).favorite,
        true,
      );
      expect(tester.widget<TextField>(find.byType(TextField)), same(search));
      await store.preferences.setPlayback(speed: 1.5);
      await tester.pumpAndSettle();
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));

      await store.catalog.refresh();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)),
        isNot(same(search)),
      );
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
      await store.preferences.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
}
