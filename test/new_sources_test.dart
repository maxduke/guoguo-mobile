import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class SourceProvider implements ProviderClient {
  final calls = <Map<String, dynamic>>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (method == 'cancelSearch') return Future.value({});
    calls.add({'method': method, ...args});
    if (method == 'categories') {
      return Future.value({
        'items': [
          {'id': '', 'name': '全部'},
          {'id': 'romance', 'name': '爱情'},
        ],
      });
    }
    final gate = Completer<Map<String, dynamic>>();
    pending.add(gate);
    return gate.future;
  }
}

Map<String, dynamic> page(
  String id, {
  bool more = true,
  DramaSource source = DramaSource.huangju,
}) => {
  'items': [
    Drama(id: '${source.name}:$id', source: source, title: id).toJson(),
  ],
  'hasMore': more,
};

void main() {
  for (final source in DramaSource.values.skip(6)) {
    test(
      '${source.name} routes catalog and search and restores offline',
      () async {
        final provider = SourceProvider();
        final storage = MemoryStorage();
        final store = AppStore(storage: storage, provider: provider);
        await store.selectSource(source);
        final catalog = store.refresh();
        expect(provider.calls.last, containsPair('source', source.name));
        expect(provider.calls.last, containsPair('method', 'catalog'));
        provider.pending.last.complete(page('catalog', source: source));
        await catalog;
        expect(store.library.single.source, source);
        final search = store.searchCatalog(source, '故事', page: 2);
        expect(provider.calls.last, containsPair('method', 'search'));
        expect(provider.calls.last, containsPair('source', source.name));
        expect(provider.calls.last, containsPair('page', 2));
        provider.pending.last.complete(
          page('search', source: source, more: false),
        );
        expect((await search).items.single.id, '${source.name}:search');
        expect(store.library.single.id, '${source.name}:catalog');
        final restored = AppStore(storage: storage, provider: provider);
        await restored.load();
        restored.offline = true;
        expect(restored.source, source);
        expect(restored.library.single.id, '${source.name}:catalog');
        expect(restored.source.rankings, isTrue);
        store.dispose();
        restored.dispose();
      },
    );
  }

  testWidgets(
    'sixteen sources remain accessible and new sources paginate online search',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = SourceProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.selectSource(DramaSource.huangju);
      final downloads = DownloadStore(store);
      await tester.pumpWidget(
        GuoguoApp(store: store, downloads: downloads, autoLoad: false),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('榜单'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '帝果'), findsOneWidget);
      final lastSource = find.widgetWithText(ChoiceChip, '伍果');
      await tester.ensureVisible(lastSource);
      await tester.pumpAndSettle();
      expect(lastSource.hitTestable(), findsOneWidget);
      await tester.enterText(find.byType(TextField), '样本');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(provider.calls.last['method'], 'search');
      expect(provider.calls.last['source'], 'huangju');
      provider.pending.last.complete(page('result-one'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('加载更多结果'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('加载更多结果'));
      await tester.pump();
      expect(provider.calls.last['page'], 2);
      provider.pending.last.complete(page('result-two', more: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('加载更多结果'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  test(
    'categories isolate late responses, retries, search and persisted pages',
    () async {
      final provider = SourceProvider();
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: provider);
      await store.selectSource(DramaSource.huangju);
      final all = store.refresh();
      final romance = store.selectCategory('romance');
      provider.pending[1].complete(page('romance-one'));
      await romance;
      provider.pending[0].complete(page('all-one'));
      await all;
      expect(store.library.single.title, 'romance-one');
      final search = store.searchCatalog(DramaSource.huangju, 'test', page: 2);
      expect(provider.calls.last['page'], 2);
      provider.pending[2].complete(page('search-only'));
      expect((await search).hasMore, isTrue);
      expect(store.library.single.title, 'romance-one');
      final failed = store.loadMore();
      expect(provider.calls.last['page'], 2);
      provider.pending[3].completeError(const ProviderException('offline'));
      await failed;
      expect(store.libraryError, contains('offline'));
      expect(store.library.single.title, 'romance-one');
      final retry = store.loadMore();
      expect(provider.calls.last['page'], 2);
      provider.pending[4].complete(page('romance-two', more: false));
      await retry;
      expect(store.library.length, 2);
      expect(store.libraryHasMore, isFalse);
      await store.selectCategory('');
      expect(store.library.single.title, 'all-one');
      final restored = AppStore(storage: storage, provider: provider);
      await restored.load();
      expect(restored.sourceCategories[DramaSource.huangju]!.last.name, '爱情');
      expect(restored.library.single.title, 'all-one');
      await restored.selectCategory('romance');
      expect(restored.library.length, 2);
      expect(restored.libraryHasMore, isFalse);
    },
  );

  test(
    'failed refresh retains category contents and successful refresh replaces',
    () async {
      final provider = SourceProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.selectSource(DramaSource.huangju);
      var request = store.refresh();
      provider.pending.last.complete(page('old'));
      await request;
      request = store.refresh();
      provider.pending.last.completeError(const ProviderException('failed'));
      await request;
      expect(store.library.single.title, 'old');
      request = store.refresh();
      provider.pending.last.complete(page('new'));
      await request;
      expect(store.library.single.title, 'new');
      expect(store.libraryError, isNull);
    },
  );

  test(
    'new sources round trip in backups and media expiry has safety margin',
    () {
      for (final source in DramaSource.values) {
        final drama = Drama(
          id: '${source.name}:1',
          source: source,
          title: source.label,
        );
        expect(
          RecordBackup.fromJson(
            RecordBackup([drama], []).toJson(),
          ).favorites.single.source,
          source,
        );
      }
      final media = ResolvedMedia.fromJson({
        'url': 'http://localhost/a',
        'remoteUrl': 'https://example.com/a',
        'expiresAt': 10000,
      });
      expect(media.freshAt(DateTime.fromMillisecondsSinceEpoch(4999)), isTrue);
      expect(media.freshAt(DateTime.fromMillisecondsSinceEpoch(5000)), isFalse);
      expect(
        ResolvedMedia.fromJson({
          'url': 'x',
          'remoteUrl': 'x',
        }).freshAt(DateTime.now()),
        isTrue,
      );
    },
  );
}
