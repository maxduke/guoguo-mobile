import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class FakeProvider implements ProviderClient {
  final Map<String, Completer<Map<String, dynamic>>> requests = {};
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) => (requests[arguments['source'] as String? ?? method] ??= Completer())
      .future;
}

const red = Drama(id: '42', source: DramaSource.hongguo, title: '同名短剧');
const yellow = Drama(id: '42', source: DramaSource.huangguo, title: '同名短剧');
WatchRecord watch(int position, DateTime time) => WatchRecord(
  drama: red,
  episodeId: 'episode-1',
  episodeIndex: 0,
  positionMs: position,
  durationMs: 100000,
  updatedAt: time,
);

void main() {
  test(
    'identical upstream IDs from different providers remain independent',
    () async {
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: FakeProvider());
      await store.toggleFavorite(red);
      await store.toggleFavorite(yellow);
      expect(store.favorites.length, 2);
      final restored = AppStore(storage: storage, provider: FakeProvider());
      await restored.load();
      expect(restored.favorites.keys, containsAll([red.key, yellow.key]));
    },
  );
  test(
    'late source result cannot replace the currently selected library',
    () async {
      final provider = FakeProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      final loadRed = store.refresh(DramaSource.hongguo);
      await store.selectSource(DramaSource.huangguo);
      final loadYellow = store.refresh(DramaSource.huangguo);
      provider.requests['huangguo']!.complete({
        'items': [yellow.toJson()],
      });
      await loadYellow;
      provider.requests['hongguo']!.complete({
        'items': [red.toJson()],
      });
      await loadRed;
      expect(store.library.single.source, DramaSource.huangguo);
      expect(store.catalogs[DramaSource.hongguo]!.single.key, red.key);
    },
  );
  test(
    'backup merges by actual watch time, not greatest playback position',
    () async {
      final store = AppStore(
        storage: MemoryStorage(),
        provider: FakeProvider(),
      );
      await store.saveWatch(watch(80000, DateTime.utc(2026, 9, 1)));
      await store.importBackup(
        RecordBackup([red], [watch(5000, DateTime.utc(2026, 9, 2))]),
      );
      expect(store.history[red.key]!.positionMs, 5000);
      await store.importBackup(
        RecordBackup([red], [watch(99000, DateTime.utc(2026, 8, 1))]),
      );
      expect(store.history[red.key]!.positionMs, 5000);
      final json = jsonDecode(store.exportBackup()) as Map;
      expect(
        json.keys,
        unorderedEquals(['format', 'version', 'favorites', 'history']),
      );
    },
  );
  test('invalid backup fails atomically and preserves existing data', () async {
    final store = AppStore(storage: MemoryStorage(), provider: FakeProvider());
    await store.toggleFavorite(red);
    final raw = jsonEncode({
      'format': 'guoguo.records',
      'version': 1,
      'favorites': [
        yellow.toJson(),
        {'id': 'invalid'},
      ],
      'history': [],
    });
    expect(() => store.inspectBackup(raw), throwsFormatException);
    expect(store.favorites.keys, [red.key]);
  });
  test('failed refresh preserves cached entries and exposes error', () async {
    final provider = FakeProvider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    store.catalogs[DramaSource.hongguo] = [red];
    final future = store.refresh();
    provider.requests['hongguo']!.completeError(const ProviderException('离线'));
    await future;
    expect(store.library.single.key, red.key);
    expect(store.sourceErrors[DramaSource.hongguo], '离线');
  });
  test('default network policy is Wi-Fi only and survives restart', () async {
    final storage = MemoryStorage();
    final store = AppStore(storage: storage, provider: FakeProvider());
    expect(store.cellularDownloads, false);
    expect(store.cellularPrefetch, false);
    await store.setNetwork(downloads: true);
    final restored = AppStore(storage: storage, provider: FakeProvider());
    await restored.load();
    expect(restored.cellularDownloads, true);
    expect(restored.cellularPrefetch, false);
  });
}
