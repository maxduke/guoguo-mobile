import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/library_page.dart';

class _CountedDrama extends Drama {
  _CountedDrama(int index)
    : super(
        id: 'd$index',
        source: DramaSource.hongguo,
        title: '故事第${index + 1}季',
        category: '都市',
      );
  int titleReads = 0, categoryReads = 0;
  @override
  String get title {
    titleReads++;
    return super.title;
  }

  @override
  String get category {
    categoryReads++;
    return super.category;
  }
}

class _Provider implements ProviderClient {
  Completer<Map<String, dynamic>>? pending;
  Map<String, dynamic> response = {};
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => pending == null ? response : pending!.future;
}

void main() {
  Future<void> mount(WidgetTester tester, AppStore store) async {
    tester.view.physicalSize = const Size(1024, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          store: store,
          autoLoad: false,
          onOpen: (_) {},
          onSearch: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> filters(WidgetTester tester) async {
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
  }

  List<Drama> visible(WidgetTester tester) => tester
      .widgetList<DramaCard>(find.byType(DramaCard))
      .map((card) => card.drama)
      .toList();

  testWidgets(
    'status, loading and failed refresh reuse sorted rows and categories',
    (tester) async {
      final provider = _Provider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      addTearDown(store.dispose);
      final rows = [for (var i = 0; i < 100; i++) _CountedDrama(i)];
      store.catalog.catalogs[DramaSource.hongguo] = rows;
      await mount(tester, store);
      await filters(tester);
      await tester.tap(find.text('剧名'));
      await tester.pumpAndSettle();
      final measured = rows.last;
      expect(visible(tester).map((d) => d.key), isNot(contains(measured.key)));
      expect(measured.titleReads, greaterThan(0));
      final reads = (measured.titleReads, measured.categoryReads);
      store.setWifi(true);
      await tester.pump();
      provider.pending = Completer();
      final refreshing = store.catalog.refresh();
      await tester.pump();
      expect(store.catalog.libraryLoading, true);
      provider.pending!.completeError(const ProviderException('无法加载'));
      await refreshing;
      await tester.pumpAndSettle();
      expect(store.catalog.libraryCanRetry, true);
      store.setOffline(true);
      await tester.pump();
      expect((measured.titleReads, measured.categoryReads), reads);
      expect(visible(tester).first.key, rows.first.key);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'metadata updates and append replace the cached sort and categories',
    (tester) async {
      final provider = _Provider();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      addTearDown(store.dispose);
      final rows = [for (var i = 0; i < 100; i++) _CountedDrama(i)];
      provider.response = {
        'items': rows.map((d) => d.toJson()).toList(),
        'hasMore': true,
      };
      await store.catalog.refresh();
      await mount(tester, store);
      await filters(tester);
      await tester.tap(find.text('剧名'));
      await tester.pumpAndSettle();
      final updated = Drama(
        id: rows.last.id,
        source: DramaSource.hongguo,
        title: 'AAA',
        category: '新分类',
      );
      provider.response = {'item': updated.toJson()};
      await store.catalog.refreshDetail(rows.last, force: true);
      await tester.pumpAndSettle();
      expect(visible(tester).first.title, 'AAA');
      expect(find.widgetWithText(ChoiceChip, '新分类'), findsOneWidget);
      const appended = Drama(
        id: 'new',
        source: DramaSource.hongguo,
        title: '000',
        category: '分页分类',
      );
      provider.response = {
        'items': [appended.toJson()],
        'hasMore': false,
      };
      await store.catalog.loadMore();
      await tester.pumpAndSettle();
      expect(store.catalog.library.length, 101);
      expect(visible(tester).first.key, appended.key);
      expect(find.widgetWithText(ChoiceChip, '分页分类'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'category, sort, source, VIP and store changes invalidate their inputs',
    (tester) async {
      final store = AppStore(storage: MemoryStorage(), provider: _Provider());
      addTearDown(store.dispose);
      const city = Drama(
        id: 'city',
        source: DramaSource.hongguo,
        title: 'B',
        category: '都市',
      );
      const love = Drama(
        id: 'love',
        source: DramaSource.hongguo,
        title: 'A',
        category: '爱情',
      );
      const free = Drama(
        id: 'free',
        source: DramaSource.huangdou,
        title: 'A',
        vip: false,
      );
      const paid = Drama(
        id: 'paid',
        source: DramaSource.huangdou,
        title: 'B',
        vip: true,
      );
      store.catalog.catalogs[DramaSource.hongguo] = [city, love];
      store.catalog.catalogs[DramaSource.huangdou] = [free, paid];
      await mount(tester, store);
      await filters(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '爱情'));
      await tester.pumpAndSettle();
      expect(visible(tester).map((d) => d.key), [love.key]);
      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.tap(find.widgetWithText(ChoiceChip, '剧名'));
      await tester.pumpAndSettle();
      expect(visible(tester).map((d) => d.key), [love.key, city.key]);
      await store.catalog.selectSource(DramaSource.huangdou);
      await tester.pumpAndSettle();
      expect(visible(tester).map((d) => d.key), [free.key]);
      await store.catalog.setHideVip(false);
      await tester.pumpAndSettle();
      expect(visible(tester).map((d) => d.key), [free.key, paid.key]);
      final replacement = AppStore(
        storage: MemoryStorage(),
        provider: _Provider(),
      );
      addTearDown(replacement.dispose);
      replacement.catalog.catalogs[DramaSource.hongguo] = [city];
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(
            store: replacement,
            autoLoad: false,
            onOpen: (_) {},
            onSearch: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(visible(tester).map((d) => d.key), [city.key]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
