import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/preferences_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/catalog_search_controller.dart';

import 'widget_test.dart' show NoNetwork;

const unavailable = {
  DramaSource.niuguo,
  DramaSource.piguo,
  DramaSource.chaoguo,
  DramaSource.shuangguo,
};

void main() {
  test(
    'default unavailable sources are hidden while device-verified DSD stays enabled',
    () {
      final preferences = PreferencesStore(save: () async {});
      addTearDown(preferences.dispose);
      expect(preferences.hiddenSources, unavailable);
      expect(preferences.hiddenSources, isNot(contains(DramaSource.dsd)));
      expect(DramaSource.dsd.defaultDisabledReason, isNull);
      // Default policy stays separate from deliberate visibility preferences.
      expect(preferences.toJson()['hiddenSources'], isEmpty);
      expect(preferences.toJson()['enabledSources'], isEmpty);
    },
  );

  test(
    'explicit re-enable survives restart and hiding revokes that choice',
    () async {
      var saves = 0;
      final preferences = PreferencesStore(
        save: () async {
          saves++;
        },
      );
      final restored = PreferencesStore(save: () async {});
      addTearDown(preferences.dispose);
      addTearDown(restored.dispose);
      await preferences.setSourceHidden(DramaSource.shuangguo, false);
      expect(saves, 1);
      expect(
        preferences.hiddenSources,
        unavailable.difference({DramaSource.shuangguo}),
      );
      restored.restore(preferences.toJson());
      expect(restored.hiddenSources, preferences.hiddenSources);
      expect(restored.toJson()['enabledSources'], ['shuangguo']);
      await restored.setSourceHidden(DramaSource.shuangguo, true);
      expect(restored.hiddenSources, unavailable);
      expect(restored.toJson()['enabledSources'], isEmpty);
      await preferences.setSourceHidden(DramaSource.dsd, true);
      expect(preferences.toJson()['hiddenSources'], ['dsd']);
    },
  );

  for (final manuallyEnabled in [false, true]) {
    test(
      'saved unavailable selection ${manuallyEnabled ? 'honors manual enable' : 'falls back without losing records'}',
      () async {
        const drama = Drama(
          id: 'saved',
          source: DramaSource.shuangguo,
          title: '保存的收藏',
        );
        final storage = MemoryStorage()
          ..value = {
            'version': 1,
            'source': 'shuangguo',
            'hiddenSources': <String>[],
            if (manuallyEnabled) 'enabledSources': ['shuangguo'],
            'records': RecordBackup([drama], []).toJson(),
          };
        final store = AppStore(storage: storage, provider: NoNetwork());
        addTearDown(store.dispose);
        await store.load();
        expect(
          store.catalog.source,
          manuallyEnabled ? DramaSource.shuangguo : DramaSource.hongguo,
        );
        expect(store.records.favorites.keys, [drama.key]);
        expect(
          store.preferences.hiddenSources.contains(DramaSource.shuangguo),
          !manuallyEnabled,
        );
      },
    );
  }

  test('Shuangguo uses local search even when explicitly re-enabled', () async {
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
    addTearDown(store.dispose);
    await store.preferences.setSourceHidden(DramaSource.shuangguo, false);
    await store.catalog.selectSource(DramaSource.shuangguo);
    final search = CatalogSearchController(store.catalog);
    addTearDown(search.dispose);
    await search.submit('样本');
    expect(DramaSource.shuangguo.onlineSearch, isFalse);
    expect(search.loading, isFalse);
    expect(search.error, isNull);
    expect(search.query, '样本');
    expect(search.results, isNull);
  });
}
