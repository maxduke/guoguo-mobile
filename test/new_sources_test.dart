import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/source_selector.dart';

class SourceProvider implements ProviderClient {
  final calls = <Map<String, dynamic>>[];
  final cancellations = <Map<String, dynamic>>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (method == 'cancelSearch') {
      cancellations.add(args);
      return Future.value({});
    }
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
        await store.preferences.setSourceHidden(source, false);
        await store.catalog.selectSource(source);
        final catalog = store.catalog.refresh();
        expect(provider.calls.last, containsPair('source', source.name));
        expect(provider.calls.last, containsPair('method', 'catalog'));
        provider.pending.last.complete(page('catalog', source: source));
        await catalog;
        expect(store.catalog.library.single.source, source);
        final search = store.catalog.searchCatalog(source, '故事', page: 2);
        expect(provider.calls.last, containsPair('method', 'search'));
        expect(provider.calls.last, containsPair('source', source.name));
        expect(provider.calls.last, containsPair('page', 2));
        provider.pending.last.complete(
          page('search', source: source, more: false),
        );
        expect((await search).items.single.id, '${source.name}:search');
        expect(store.catalog.library.single.id, '${source.name}:catalog');
        final restored = AppStore(storage: storage, provider: provider);
        await restored.load();
        restored.offline = true;
        expect(restored.catalog.source, source);
        expect(restored.catalog.library.single.id, '${source.name}:catalog');
        expect(restored.catalog.source.rankings, isTrue);
        store.dispose();
        restored.dispose();
      },
    );
  }

  testWidgets(
    'all source identities remain searchable and healthy sources paginate online search',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = SourceProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.catalog.selectSource(DramaSource.huangju);
      final downloads = DownloadStore(store);
      await tester.pumpWidget(
        GuoguoApp(store: store, downloads: downloads, autoLoad: false),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('查看全部栏目'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(SourceSelector),
          matching: find.byType(OutlinedButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '帝果'), findsOneWidget);
      final lastSource = find.widgetWithText(ChoiceChip, '伍果');
      expect(lastSource.hitTestable(), findsOneWidget);
      for (final label in ['超果', '爽果']) {
        expect(find.widgetWithText(ChoiceChip, label), findsNothing);
      }
      for (final label in ['超果', '米果', '爽果']) {
        await tester.enterText(find.byType(TextField), label);
        await tester.pumpAndSettle();
        final choice = find.widgetWithText(ChoiceChip, label);
        expect(choice, findsOneWidget);
        await tester.ensureVisible(choice);
        expect(choice.hitTestable(), findsOneWidget);
      }
      await tester.tap(find.byTooltip('关闭站源选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索剧名'));
      await tester.pumpAndSettle();
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

  testWidgets(
    'source selection cancels the previous search and isolates its late result',
    (tester) async {
      final provider = SourceProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.catalog.selectSource(DramaSource.huangju);
      final downloads = DownloadStore(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        GuoguoApp(store: store, downloads: downloads, autoLoad: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索剧名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '迟到');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      final previous = provider.pending.last;
      final request = provider.calls.last;
      expect(request['method'], 'search');
      await tester.tap(
        find.descendant(
          of: find.byType(SourceSelector),
          matching: find.byType(OutlinedButton),
        ),
      );
      // The old search spinner remains active while the sheet animates in.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        provider.cancellations,
        contains(
          allOf(
            containsPair('source', 'huangju'),
            containsPair('requestId', request['requestId']),
          ),
        ),
      );
      expect(store.catalog.source, DramaSource.wuguo);
      await tester.pumpAndSettle();
      previous.complete(page('旧源结果'));
      await tester.pumpAndSettle();
      expect(provider.calls.last['method'], 'search');
      expect(find.text('旧源结果'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      // The discovery preview does not fetch the directory; entering the
      // library loads only the newly selected source.
      expect(provider.calls.last['method'], 'search');
      await tester.tap(find.text('完整剧库'));
      await tester.pump();
      expect(provider.calls.last['method'], 'catalog');
      expect(provider.calls.last['source'], 'wuguo');
      provider.pending.last.complete(page('伍果目录', source: DramaSource.wuguo));
      await tester.pumpAndSettle();
      expect(store.catalog.library.single.title, '伍果目录');
      expect(find.text('伍果目录'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'categories isolate late responses, retries, search and persisted pages',
    () async {
      final provider = SourceProvider();
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: provider);
      await store.catalog.selectSource(DramaSource.huangju);
      final all = store.catalog.refresh();
      final romance = store.catalog.selectCategory('romance');
      provider.pending[1].complete(page('romance-one'));
      await romance;
      provider.pending[0].complete(page('all-one'));
      await all;
      expect(store.catalog.library.single.title, 'romance-one');
      final search = store.catalog.searchCatalog(
        DramaSource.huangju,
        'test',
        page: 2,
      );
      expect(provider.calls.last['page'], 2);
      provider.pending[2].complete(page('search-only'));
      expect((await search).hasMore, isTrue);
      expect(store.catalog.library.single.title, 'romance-one');
      final failed = store.catalog.loadMore();
      expect(provider.calls.last['page'], 2);
      provider.pending[3].completeError(const ProviderException('offline'));
      await failed;
      expect(store.catalog.libraryError, '更多短剧加载失败，请重试');
      expect(store.catalog.library.single.title, 'romance-one');
      final retry = store.catalog.loadMore();
      expect(provider.calls.last['page'], 2);
      provider.pending[4].complete(page('romance-two', more: false));
      await retry;
      expect(store.catalog.library.length, 2);
      expect(store.catalog.libraryHasMore, isFalse);
      await store.catalog.selectCategory('');
      expect(store.catalog.library.single.title, 'all-one');
      final restored = AppStore(storage: storage, provider: provider);
      await restored.load();
      expect(
        restored.catalog.sourceCategories[DramaSource.huangju]!.last.name,
        '爱情',
      );
      expect(restored.catalog.library.single.title, 'all-one');
      await restored.catalog.selectCategory('romance');
      expect(restored.catalog.library.length, 2);
      expect(restored.catalog.libraryHasMore, isFalse);
    },
  );

  test(
    'failed refresh retains category contents and successful refresh replaces',
    () async {
      final provider = SourceProvider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      await store.catalog.selectSource(DramaSource.huangju);
      var request = store.catalog.refresh();
      provider.pending.last.complete(page('old'));
      await request;
      request = store.catalog.refresh();
      provider.pending.last.completeError(const ProviderException('failed'));
      await request;
      expect(store.catalog.library.single.title, 'old');
      request = store.catalog.refresh();
      provider.pending.last.complete(page('new'));
      await request;
      expect(store.catalog.library.single.title, 'new');
      expect(store.catalog.libraryError, isNull);
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
