import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Provider implements ProviderClient {
  final requests = <Map<String, dynamic>>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  Completer<Map<String, dynamic>>? categories;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (method == 'categories') {
      return categories?.future ??
          Future.value({
            'items': [
              {'id': '', 'name': '全部'},
              {'id': 'romance', 'name': '爱情'},
            ],
          });
    }
    requests.add(args);
    final request = Completer<Map<String, dynamic>>();
    pending.add(request);
    return request.future;
  }
}

Map<String, dynamic> _page(
  DramaSource source,
  String id, {
  bool more = true,
  Object? warning,
}) => {
  'items': [
    Drama(id: '${source.name}:$id', source: source, title: id).toJson(),
  ],
  'hasMore': more,
  'warning': ?warning,
};

class _CacheFailure extends MemoryStorage implements PartitionedStorage {
  bool fail = false;
  @override
  String? get cacheReadError => null;
  @override
  Future<void> writeRecords(Map<String, dynamic> value) => super.write(value);
  @override
  Future<void> writeCache(Map<String, dynamic> value) async {
    if (fail) throw const FileSystemException('secret');
  }
}

void main() {
  for (final source in [DramaSource.hongguo, DramaSource.huangju]) {
    test(
      '${source.name} malformed tags preserve the installed page and cursor',
      () async {
        final provider = _Provider();
        final store = AppStore(storage: MemoryStorage(), provider: provider);
        addTearDown(store.dispose);
        await store.catalog.selectSource(source);
        var request = store.catalog.refresh();
        provider.pending.last.complete(_page(source, 'old'));
        await request;
        request = store.catalog.loadMore();
        final invalid = _page(source, 'bad', more: false);
        (invalid['items'] as List).single['tags'] = ['valid', 1];
        provider.pending.last.complete(invalid);
        await request;
        expect(store.catalog.library.single.title, 'old');
        expect(store.catalog.libraryHasMore, isTrue);
        expect(store.catalog.libraryCanRetry, isTrue);
        expect(store.catalog.catalogs[source]!.single.title, 'old');
      },
    );

    test(
      '${source.name} refresh retry preserves the operation and malformed metadata preserves rows',
      () async {
        final provider = _Provider();
        final store = AppStore(storage: MemoryStorage(), provider: provider);
        addTearDown(store.dispose);
        await store.catalog.selectSource(source);
        var request = store.catalog.refresh();
        provider.pending.last.complete(_page(source, 'old'));
        await request;
        request = store.catalog.loadMore();
        provider.pending.last.complete(_page(source, 'second'));
        await request;
        request = store.catalog.refresh();
        provider.pending.last.complete(
          _page(source, 'invalid', more: false, warning: 123),
        );
        await request;
        expect(store.catalog.library.map((d) => d.title), ['old', 'second']);
        expect(store.catalog.libraryHasMore, isTrue);
        expect(store.catalog.libraryCanRetry, isTrue);
        expect(store.catalog.libraryError, '剧库更新失败，已保留现有内容');
        final failedRequest = provider.requests.last;
        request = store.catalog.retryLibrary();
        await store.catalog.retryLibrary();
        expect(provider.requests.last, failedRequest);
        expect(provider.requests.length, 4);
        provider.pending.last.complete(_page(source, 'new'));
        await request;
        expect(store.catalog.libraryCanRetry, isFalse);
        expect(store.catalog.libraryError, isNull);
      },
    );

    test(
      '${source.name} append failure retries its cursor and successful warnings remain pageable',
      () async {
        final provider = _Provider();
        final store = AppStore(storage: MemoryStorage(), provider: provider);
        addTearDown(store.dispose);
        await store.catalog.selectSource(source);
        var request = store.catalog.refresh();
        provider.pending.last.complete(
          _page(source, 'old', warning: '部分分类暂时不可用'),
        );
        await request;
        expect(store.catalog.libraryCanRetry, isFalse);
        request = store.catalog.loadMore();
        provider.pending.last.completeError(StateError('secret'));
        await request;
        expect(store.catalog.library.single.title, 'old');
        expect(store.catalog.libraryError, '更多短剧加载失败，请重试');
        request = store.catalog.retryLibrary();
        expect(provider.requests.last['page'], 2);
        provider.pending.last.complete(_page(source, 'new', more: false));
        await request;
        expect(store.catalog.library.map((d) => d.title), ['old', 'new']);
        expect(store.catalog.libraryHasMore, isFalse);
        expect(store.catalog.libraryCanRetry, isFalse);
      },
    );

    test(
      '${source.name} cache write failure does not retry an already installed page',
      () async {
        final provider = _Provider();
        final storage = _CacheFailure()..fail = true;
        final store = AppStore(storage: storage, provider: provider);
        addTearDown(store.dispose);
        final request = store.catalog.refresh(source);
        provider.pending.last.complete(_page(source, 'loaded'));
        await request;
        await store.catalog.selectSource(source);
        expect(store.catalog.library.single.title, 'loaded');
        expect(store.catalog.libraryCanRetry, isFalse);
        expect(store.catalog.libraryError, isNull);
        expect(store.cachePersistenceError, isNotNull);
      },
    );
  }

  test('category failures and retries belong to the selected slice', () async {
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    addTearDown(store.dispose);
    await store.catalog.selectSource(DramaSource.huangju);
    final request = store.catalog.selectCategory('romance');
    provider.pending.last.completeError(StateError('secret'));
    await request;
    final all = store.catalog.selectCategory('');
    provider.pending.last.complete(_page(DramaSource.huangju, 'all'));
    await all;
    expect(store.catalog.libraryCanRetry, isFalse);
    await store.catalog.retryLibrary();
    expect(provider.requests.length, 2);
    await store.catalog.selectCategory('romance');
    final retry = store.catalog.retryLibrary();
    expect(provider.requests.last['category'], 'romance');
    expect(provider.requests.last['page'], 1);
    provider.pending.last.complete(_page(DramaSource.huangju, 'romance'));
    await retry;
    expect(store.catalog.library.single.title, 'romance');
  });

  test(
    'categories retain usable choices on failure and suppress duplicate retry',
    () async {
      final provider = _Provider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      addTearDown(store.dispose);
      await store.catalog.selectSource(DramaSource.huangju);
      await store.catalog.loadCategories();
      provider.categories = Completer();
      final request = store.catalog.loadCategories();
      expect(store.catalog.categoriesLoading, isTrue);
      await store.catalog.loadCategories();
      provider.categories!.completeError(StateError('secret'));
      await request;
      expect(store.catalog.categoryErrors[DramaSource.huangju], '分类暂时无法加载，请重试');
      expect(
        store.catalog.sourceCategories[DramaSource.huangju]!.last.name,
        '爱情',
      );
      expect(store.catalog.categoriesLoading, isFalse);
      provider.categories = null;
      await store.catalog.loadCategories();
      expect(store.catalog.categoryErrors, isEmpty);
    },
  );

  for (final fail in [false, true]) {
    test(
      'disposed catalog ignores late pagination ${fail ? 'failure' : 'success'}',
      () async {
        final provider = _Provider();
        final store = AppStore(storage: MemoryStorage(), provider: provider);
        var request = store.catalog.refresh();
        provider.pending.last.complete(_page(DramaSource.hongguo, 'old'));
        await request;
        request = store.catalog.loadMore();
        store.dispose();
        if (fail) {
          provider.pending.last.completeError(StateError('secret'));
        } else {
          provider.pending.last.complete(_page(DramaSource.hongguo, 'late'));
        }
        await request;
        expect(store.catalog.library.single.title, 'old');
        expect(store.catalog.libraryError, isNull);
        expect(store.catalog.catalogPages[DramaSource.hongguo], 1);
      },
    );
  }

  testWidgets('library offers the failed refresh instead of a new append', (
    tester,
  ) async {
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    final downloads = DownloadStore(store);
    addTearDown(() {
      downloads.dispose();
      store.dispose();
    });
    var request = store.catalog.refresh();
    provider.pending.last.complete(_page(DramaSource.hongguo, 'cached'));
    await request;
    request = store.catalog.refresh();
    provider.pending.last.completeError(StateError('secret'));
    await request;
    await tester.pumpWidget(
      GuoguoApp(store: store, downloads: downloads, autoLoad: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('完整剧库'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('重试加载剧库'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('重试加载剧库'));
    await tester.pump();
    expect(provider.requests.last, {'source': 'hongguo'});
    provider.pending.last.complete(
      _page(DramaSource.hongguo, 'recovered', more: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试加载剧库'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
