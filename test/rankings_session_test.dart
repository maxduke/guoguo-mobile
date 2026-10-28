import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/rankings_page.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Read {
  _Read(this.board, this.page, this.refresh);
  final String board;
  final int page;
  final bool refresh;
  final result = Completer<Map<String, dynamic>>();
}

class _Provider implements ProviderClient {
  final reads = <_Read>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'boards') {
      return {
        'items': [
          {'id': 'a', 'name': '总榜'},
          {'id': 'b', 'name': '真人榜'},
          {'id': 'c', 'name': '漫剧榜'},
        ],
      };
    }
    if (method != 'ranking') throw StateError('Unexpected $method');
    final read = _Read(
      arguments['board'] as String,
      arguments['page'] as int,
      arguments['refresh'] == true,
    );
    reads.add(read);
    return read.result.future;
  }

  _Read pending(String board) => reads.lastWhere(
    (read) => read.board == board && !read.result.isCompleted,
  );

  void finish(
    String board,
    String title,
    DateTime now, {
    bool more = false,
    bool stale = false,
  }) {
    final read = pending(board);
    read.result.complete({
      'boardId': board,
      'page': read.page,
      'kind': 'ranking',
      'items': [
        {
          'rank': read.page,
          'drama': Drama(
            id: '$board-${read.page}-$title',
            source: DramaSource.hongguo,
            title: title,
          ).toJson(),
        },
      ],
      'hasMore': more,
      'fetchedAt': now.toIso8601String(),
      'stale': stale,
    });
  }

  void release() {
    for (final read in reads) {
      if (!read.result.isCompleted) {
        read.result.complete({'items': [], 'hasMore': false});
      }
    }
  }
}

void main() {
  late _Provider provider;
  late AppStore store;
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 28, 7);
    provider = _Provider();
  });
  tearDown(() {
    provider.release();
    store.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    // Persistence queues must be created inside the widget test's async zone.
    store = AppStore(
      storage: MemoryStorage(),
      provider: provider,
      now: () => now,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RankingsPage(store: store, onOpen: (_) {}),
      ),
    );
    await tester.pump();
    expect(provider.reads.map((read) => read.board), ['a']);
  }

  Future<void> select(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(ChoiceChip, name));
    await tester.pump();
  }

  testWidgets(
    'switching boards keeps in-flight results and fresh columns need no call',
    (tester) async {
      await mount(tester);
      provider.finish('a', '总榜旧内容', now);
      await tester.pumpAndSettle();
      await select(tester, '真人榜');
      await select(tester, '总榜');
      expect(find.text('总榜旧内容'), findsOneWidget);
      expect(provider.reads.map((read) => read.board), ['a', 'b']);
      provider.finish('b', '真人新内容', now);
      await tester.pumpAndSettle();
      expect(
        store.catalog.discoveryCache
            .ranking(DramaSource.hongguo, 'b')!
            .rows
            .single
            .drama
            .title,
        '真人新内容',
      );
      await select(tester, '真人榜');
      expect(find.text('真人新内容'), findsOneWidget);
      expect(provider.reads, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'expired column stays visible while renewing and manual refresh is forced',
    (tester) async {
      await mount(tester);
      provider.finish('a', '总榜旧内容', now);
      await tester.pumpAndSettle();
      await select(tester, '真人榜');
      provider.finish('b', '真人内容', now);
      await tester.pumpAndSettle();
      now = now.add(const Duration(minutes: 6));
      await select(tester, '总榜');
      expect(find.text('总榜旧内容'), findsOneWidget);
      expect(find.text('正在后台更新…'), findsOneWidget);
      expect(provider.reads.map((read) => read.board), ['a', 'b', 'a']);
      provider.finish('a', '总榜已更新', now);
      await tester.pumpAndSettle();
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(provider.reads.last.refresh, true);
      expect(find.text('总榜已更新'), findsOneWidget);
      provider.finish('a', '手动更新', now);
      await refresh;
      await tester.pumpAndSettle();
      expect(find.text('手动更新'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'page in flight is reused after a board switch and retains all rows',
    (tester) async {
      await mount(tester);
      provider.finish('a', '第一页', now, more: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(provider.reads.last.page, 2);
      await select(tester, '真人榜');
      await select(tester, '总榜');
      expect(provider.reads.where((read) => read.board == 'a'), hasLength(2));
      provider.finish('a', '第二页', now);
      provider.finish('b', '真人内容', now);
      await tester.pumpAndSettle();
      expect(find.text('第一页'), findsOneWidget);
      expect(find.text('第二页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('loading a later page keeps the first page age for freshness', (
    tester,
  ) async {
    await mount(tester);
    final firstPageAt = now;
    provider.finish('a', '第一页', now, more: true);
    await tester.pumpAndSettle();
    now = now.add(const Duration(minutes: 4));
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    provider.finish('a', '第二页', now);
    await tester.pumpAndSettle();
    expect(
      store.catalog.discoveryCache.ranking(DramaSource.hongguo, 'a')!.savedAt,
      firstPageAt,
    );
    await select(tester, '真人榜');
    provider.finish('b', '真人内容', now);
    await tester.pumpAndSettle();
    now = now.add(const Duration(minutes: 2));
    await select(tester, '总榜');
    expect(provider.reads.where((read) => read.board == 'a'), hasLength(3));
    provider.finish('a', '重新读取首页', now);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replacing the store ignores an older board request', (
    tester,
  ) async {
    await mount(tester);
    final oldStore = store, oldProvider = provider;
    provider = _Provider();
    store = AppStore(
      storage: MemoryStorage(),
      provider: provider,
      now: () => now,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RankingsPage(store: store, onOpen: (_) {}),
      ),
    );
    await tester.pump();
    oldProvider.finish('a', '旧来源迟到结果', now);
    await tester.pump();
    expect(find.text('旧来源迟到结果'), findsNothing);
    expect(
      oldStore.catalog.discoveryCache.ranking(DramaSource.hongguo, 'a'),
      isNull,
    );
    provider.finish('a', '新来源内容', now);
    await tester.pumpAndSettle();
    expect(find.text('新来源内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    oldStore.dispose();
  });

  testWidgets(
    'failed renewal preserves the original data timestamp and allows retry',
    (tester) async {
      await mount(tester);
      final original = now;
      provider.finish('a', '原内容', now);
      await tester.pumpAndSettle();
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      provider
          .pending('a')
          .result
          .completeError(const ProviderException('private upstream response'));
      await refresh;
      await tester.pumpAndSettle();
      expect(find.text('原内容'), findsOneWidget);
      expect(find.textContaining('栏目刷新失败'), findsOneWidget);
      expect(
        store.catalog.discoveryCache.ranking(DramaSource.hongguo, 'a')!.savedAt,
        original,
      );
      expect(find.textContaining('private'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(provider.reads.last.refresh, true);
      provider.finish('a', '重试成功', now);
      await tester.pumpAndSettle();
      expect(find.text('重试成功'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
