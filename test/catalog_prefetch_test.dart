import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/catalog_prefetch_scheduler.dart';
import 'package:guoguo_mobile/ui/library_page.dart';

class _Provider implements ProviderClient {
  final requests = <Map<String, dynamic>>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  final cancellations = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (method == 'categories') return Future.value({'items': <dynamic>[]});
    if (method == 'cancelCatalog') {
      cancellations.add(args);
      return Future.value({'ok': true});
    }
    if (method != 'catalog') throw StateError('unexpected $method');
    requests.add(Map.of(args));
    final pendingCall = Completer<Map<String, dynamic>>();
    pending.add(pendingCall);
    return pendingCall.future;
  }
}

Map<String, dynamic> _page(
  String id, {
  bool more = true,
  String warning = '',
}) => {
  'items': [
    Drama(id: 'huangju:$id', source: DramaSource.huangju, title: id).toJson(),
  ],
  'hasMore': more,
  'warning': warning,
};

void main() {
  late _Provider provider;
  late AppStore store;
  var now = DateTime(2026, 10, 10);
  void fixture() {
    now = DateTime(2026, 10, 10);
    provider = _Provider();
    store = AppStore(
      storage: MemoryStorage(),
      provider: provider,
      now: () => now,
    );
  }

  setUp(fixture);
  tearDown(() => store.dispose());
  Future<void> seed() async {
    await store.catalog.selectSource(DramaSource.huangju);
    final initial = store.catalog.refresh();
    provider.pending.last.complete(_page('first'));
    await initial;
  }

  test(
    'one prefetch installs the next page once and foreground continues after it',
    () async {
      await seed();
      final read = store.catalog.prefetchLibrary(isActive: () => true);
      expect(provider.requests.last['page'], 2);
      expect(provider.requests.last['background'], true);
      expect(await store.catalog.prefetchLibrary(isActive: () => true), false);
      provider.pending.last.complete(_page('second'));
      expect(await read, true);
      expect(store.catalog.library.map((d) => d.title), ['first', 'second']);
      final next = store.catalog.loadMore();
      expect(provider.requests.last['page'], 3);
      expect(provider.requests.last.containsKey('background'), false);
      provider.pending.last.complete(_page('third', more: false));
      await next;
      expect(store.catalog.libraryHasMore, false);
    },
  );

  test(
    'manual refresh takes over immediately and late prefetch cannot advance cursor',
    () async {
      await seed();
      final read = store.catalog.prefetchLibrary(isActive: () => true);
      final old = provider.pending.last;
      final refresh = store.catalog.refresh();
      expect(provider.requests.last['page'], 1);
      expect(
        provider.cancellations.single['requestId'],
        provider.requests[1]['requestId'],
      );
      expect(await read, false);
      provider.pending.last.complete(_page('fresh'));
      await refresh;
      old.complete(_page('late'));
      await Future<void>.delayed(Duration.zero);
      expect(store.catalog.library.single.title, 'fresh');
      final next = store.catalog.loadMore();
      expect(provider.requests.last['page'], 2);
      provider.pending.last.complete(_page('next'));
      await next;
    },
  );

  test(
    'category change cancels an owned page and rejects its late completion',
    () async {
      await seed();
      final read = store.catalog.prefetchLibrary(isActive: () => true);
      final old = provider.pending.last;
      final change = store.catalog.selectCategory('romance');
      expect(await read, false);
      expect(provider.requests.last['category'], 'romance');
      provider.pending.last.complete(_page('category'));
      await change;
      old.complete(_page('late'));
      await Future<void>.delayed(Duration.zero);
      expect(store.catalog.library.single.title, 'category');
      expect(
        store.catalog.catalogs[DramaSource.huangju]!.any(
          (d) => d.title == 'late',
        ),
        false,
      );
    },
  );

  for (final failure in ['warning', 'exception', 'malformed']) {
    test(
      '$failure keeps page and applies a bounded backoff without a visible retry error',
      () async {
        await seed();
        final read = store.catalog.prefetchLibrary(isActive: () => true);
        if (failure == 'exception') {
          provider.pending.last.completeError(
            const ProviderException('secret'),
          );
        } else if (failure == 'malformed') {
          provider.pending.last.complete({
            'items': [1],
          });
        } else {
          provider.pending.last.complete(_page('fallback', warning: 'partial'));
        }
        expect(await read, false);
        expect(store.catalog.library.single.title, 'first');
        expect(store.catalog.libraryCanRetry, false);
        expect(store.catalog.libraryError, isNull);
        expect(
          await store.catalog.prefetchLibrary(isActive: () => true),
          false,
        );
        now = now.add(const Duration(seconds: 31));
        final retry = store.catalog.prefetchLibrary(isActive: () => true);
        expect(provider.requests.last['page'], 2);
        provider.pending.last.complete(_page('second'));
        expect(await retry, true);
      },
    );
  }

  test(
    'inactive and offline results are discarded, aggregate catalogs never prefetch',
    () async {
      await seed();
      var active = true;
      final read = store.catalog.prefetchLibrary(isActive: () => active);
      active = false;
      provider.pending.last.complete(_page('discarded'));
      expect(await read, false);
      store.setOffline(true);
      expect(await store.catalog.prefetchLibrary(isActive: () => true), false);
      store.setOffline(false);
      await store.catalog.selectSource(DramaSource.hongguo);
      expect(await store.catalog.prefetchLibrary(isActive: () => true), false);
    },
  );

  testWidgets(
    'settling allows one page and resets only after scroll or cancellation',
    (tester) async {
      var count = 0;
      final scheduler = CatalogPrefetchScheduler(onIdle: () => count++);
      addTearDown(scheduler.dispose);
      scheduler.layout();
      await tester.pump(const Duration(milliseconds: 349));
      expect(count, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(count, 1);
      scheduler.layout();
      await tester.pump(const Duration(seconds: 1));
      expect(count, 1);
      scheduler.scrolled();
      await tester.pump(const Duration(milliseconds: 200));
      scheduler.scrolled();
      await tester.pump(const Duration(milliseconds: 350));
      expect(count, 2);
      scheduler.scrolled();
      scheduler.reset();
      await tester.pump(const Duration(seconds: 1));
      expect(count, 2);
    },
  );

  testWidgets(
    'Wi-Fi idle page prefetches once and turning preference off cancels',
    (tester) async {
      store.dispose();
      fixture();
      await seed();
      store.setWifi(true);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(store: store, onOpen: (_) {}, onSearch: () {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(provider.requests.length, 2);
      expect(provider.requests.last['background'], true);
      await store.preferences.setCatalogPrefetch(false);
      await tester.pump();
      expect(provider.cancellations, hasLength(1));
      provider.pending.last.complete(_page('discarded'));
      await tester.pump();
      expect(store.catalog.library.single.title, 'first');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unknown network never starts a speculative request', (
    tester,
  ) async {
    store.dispose();
    fixture();
    await seed();
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(store: store, onOpen: (_) {}, onSearch: () {}),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(provider.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
