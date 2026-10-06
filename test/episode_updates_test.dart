import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class Chapters implements ProviderClient {
  int calls = 0, count = 2;
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    calls++;
    await gate?.future;
    if (fail) throw const ProviderException('fixture offline');
    return {
      'chapters': [
        for (var i = 1; i <= count; i++) {'id': '$i', 'currentEpisode': i},
      ],
    };
  }
}

const updateDrama = Drama(
  id: 'serial',
  source: DramaSource.hongguo,
  title: '连载',
);
void main() {
  test('manual refresh reports a shared automatic request failure', () async {
    final provider = Chapters();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    await store.catalog.episodes(updateDrama);
    store.catalog.episodeUpdatedAt.clear();
    provider.fail = true;
    provider.gate = Completer<void>();
    final automatic = store.catalog.episodes(updateDrama);
    final manual = expectLater(
      store.catalog.episodes(updateDrama, refresh: true),
      throwsA(isA<ProviderException>()),
    );
    provider.gate!.complete();
    expect((await automatic).length, 2);
    await manual;
    expect(provider.calls, 2);
    store.dispose();
  });

  test('freshness, offline fallback, new IDs and persistence', () async {
    var now = DateTime(2026, 9, 17);
    final storage = MemoryStorage();
    final provider = Chapters();
    final store = AppStore(
      storage: storage,
      provider: provider,
      now: () => now,
    );
    final first = await store.catalog.episodes(updateDrama);
    await store.records.markEpisodesSeen(updateDrama, first);
    await store.catalog.episodes(updateDrama);
    expect(provider.calls, 1);
    now = now.add(const Duration(hours: 7));
    provider.count = 3;
    await store.catalog.episodes(updateDrama);
    expect(store.records.newEpisodeCount(updateDrama), 1);
    final restored = AppStore(
      storage: storage,
      provider: provider,
      now: () => now,
    );
    await restored.load();
    expect(restored.records.newEpisodeCount(updateDrama), 1);
    await restored.catalog.episodes(updateDrama);
    expect(provider.calls, 2);
    restored.setOffline(true);
    await restored.catalog.episodes(updateDrama);
    expect(provider.calls, 2);
    await expectLater(
      restored.catalog.episodes(updateDrama, refresh: true),
      throwsA(isA<ProviderException>()),
    );
    await restored.records.markEpisodesSeen(
      updateDrama,
      restored.catalog.episodeCache[updateDrama.key]!,
    );
    expect(restored.records.newEpisodeCount(updateDrama), 0);
    store.dispose();
    restored.dispose();
  });

  test(
    'concurrent refresh shares request; automatic failure keeps stale cache',
    () async {
      final provider = Chapters();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.catalog.episodes(updateDrama);
      provider.gate = Completer<void>();
      final a = store.catalog.episodes(updateDrama, refresh: true);
      final b = store.catalog.episodes(updateDrama, refresh: true);
      provider.gate!.complete();
      await Future.wait([a, b]);
      expect(provider.calls, 2);
      provider.fail = true;
      store.catalog.episodeUpdatedAt.clear();
      expect((await store.catalog.episodes(updateDrama)).length, 2);
      await expectLater(
        store.catalog.episodes(updateDrama, refresh: true),
        throwsA(isA<ProviderException>()),
      );
      expect(store.catalog.episodeCache[updateDrama.key]!.length, 2);
      store.dispose();
    },
  );

  test(
    'favorite update finishes with partial failures and preserves records',
    () async {
      final provider = Chapters();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.records.toggleFavorite(updateDrama);
      await store.records.checkFavoriteUpdates();
      provider.fail = true;
      await expectLater(
        store.records.checkFavoriteUpdates(),
        throwsA(isA<ProviderException>()),
      );
      expect(store.records.checkingUpdates, isFalse);
      expect(store.records.favorites.length, 1);
      expect(store.catalog.episodeCache[updateDrama.key]!.length, 2);
      store.dispose();
    },
  );
}
