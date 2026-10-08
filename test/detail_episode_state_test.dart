import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/download_range_sheet.dart';
import 'package:guoguo_mobile/ui/player_page.dart';

const _drama = Drama(id: 'state', source: DramaSource.hongguo, title: '分集状态');
const _failure = ProviderException(
  'provider failure https://example.test/?token=private',
);

List<Episode> _rows() => [
  for (var i = 1; i <= 3; i++)
    Episode.fromJson({'id': 'e$i', 'currentEpisode': i * 10}, i - 1),
];

class _Provider implements ProviderClient {
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'detail') return {'item': _drama.toJson()};
    if (method == 'chapters') {
      final request = Completer<Map<String, dynamic>>();
      requests.add(request);
      return request.future;
    }
    return {};
  }

  void complete(List<Episode> rows) =>
      requests.last.complete({'chapters': rows.map((e) => e.raw).toList()});
}

class _Downloads extends DownloadStore {
  _Downloads(super.store);
  final added = <(String, int)>[];
  Completer<void>? pending;
  @override
  Future<void> enqueue(Drama drama, Episode episode, int index) async {
    added.add((episode.id, index));
    await pending?.future;
  }
}

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

Finder _icon(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void main() {
  Future<(AppStore, _Downloads, _Provider, _Routes)> mount(
    WidgetTester tester, {
    bool cached = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    if (cached) {
      store.catalog.episodeCache[_drama.key] = _rows();
      store.catalog.episodeUpdatedAt[_drama.key] = store.now();
    }
    final downloads = _Downloads(store), routes = _Routes();
    addTearDown(() {
      downloads.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [routes],
        home: DetailPage(store: store, downloads: downloads, drama: _drama),
      ),
    );
    if (cached) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return (store, downloads, provider, routes);
  }

  Finder getPrimary() => find.byKey(const ValueKey('detail-primary-play'));

  testWidgets(
    'initial failure has fixed guidance and one retry restores all actions',
    (tester) async {
      final (store, _, provider, _) = await mount(tester, cached: false);
      expect(tester.widget<FilledButton>(getPrimary()).onPressed, isNull);
      expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNull);
      provider.requests.single.completeError(_failure);
      await tester.pumpAndSettle();
      expect(find.text('分集暂时没加载出来'), findsOneWidget);
      expect(find.textContaining('token=private'), findsNothing);
      store.setOffline(true);
      await tester.pump();
      expect(find.text('当前离线，联网后可重新加载分集'), findsOneWidget);
      store.setOffline(false);
      await tester.pump();
      expect(find.text('请检查网络后重试'), findsOneWidget);
      await tester.tap(find.text('重新加载'));
      await tester.pump();
      expect(provider.requests, hasLength(2));
      expect(tester.widget<FilledButton>(getPrimary()).onPressed, isNull);
      provider.complete(_rows());
      await tester.pumpAndSettle();
      expect(find.text('开始观看'), findsOneWidget);
      expect(tester.widget<FilledButton>(getPrimary()).onPressed, isNotNull);
      expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNotNull);
      expect(find.text('分集暂时没加载出来'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed refresh retains chapters with an inline retryable notice',
    (tester) async {
      final (_, _, provider, _) = await mount(tester);
      final refresh = tester.widget<IconButton>(_icon('刷新分集')).onPressed!;
      refresh();
      refresh();
      await tester.pump();
      expect(provider.requests, hasLength(1));
      expect(find.text('共 3 集'), findsOneWidget);
      expect(tester.widget<FilledButton>(getPrimary()).onPressed, isNotNull);
      expect(tester.widget<IconButton>(_icon('刷新分集')).onPressed, isNull);
      expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNull);
      provider.requests.single.completeError(_failure);
      await tester.pumpAndSettle();
      expect(find.text('共 3 集'), findsOneWidget);
      expect(find.text('暂未更新成功，正在显示缓存分集'), findsOneWidget);
      expect(find.textContaining('token=private'), findsNothing);
      expect(tester.widget<IconButton>(_icon('刷新分集')).onPressed, isNotNull);
      expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'refresh updates resume and download targets from the same queue',
    (tester) async {
      final (store, downloads, provider, _) = await mount(tester);
      await store.records.saveWatch(
        WatchRecord(
          drama: _drama,
          episodeId: 'e2',
          episodeIndex: 1,
          positionMs: 1000,
          durationMs: 20000,
          updatedAt: DateTime.now(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('继续第 20 集'), findsOneWidget);
      await tester.tap(_icon('刷新分集'));
      await tester.pump();
      final rows = [
        _rows()[2],
        _rows()[0],
        Episode.fromJson({'id': 'e2', 'currentEpisode': 25}, 2),
      ];
      provider.complete(rows);
      await tester.pumpAndSettle();
      expect(find.text('继续第 25 集'), findsOneWidget);
      await tester.tap(_icon('选择下载分集'));
      await tester.pumpAndSettle();
      final sheet = tester.widget<DownloadRangeSheet>(
        find.byType(DownloadRangeSheet),
      );
      expect(sheet.startIndex, 2);
      expect(sheet.episodes.map((e) => e.id), ['e3', 'e1', 'e2']);
      await tester.tap(find.text('加入下载（1 集）'));
      await tester.pumpAndSettle();
      expect(downloads.added, [('e2', 2)]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a playback route retains the episode snapshot chosen by its button',
    (tester) async {
      final (store, _, _, routes) = await mount(tester);
      await store.records.saveWatch(
        WatchRecord(
          drama: _drama,
          episodeId: 'e2',
          episodeIndex: 1,
          positionMs: 1000,
          durationMs: 20000,
          updatedAt: DateTime.now(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(getPrimary());
      store.catalog.episodeCache[_drama.key]!.removeAt(0);
      final route = routes.pushed.last as MaterialPageRoute<void>;
      final player =
          route.builder(tester.element(find.byType(DetailPage))) as PlayerPage;
      expect(player.initialIndex, 1);
      expect(player.episodes.map((e) => e.id), ['e1', 'e2', 'e3']);
      expect(player.episodes[player.initialIndex].id, 'e2');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'download selection blocks duplicate sheets and cancellation releases busy state',
    (tester) async {
      final (_, downloads, _, routes) = await mount(tester);
      final choose = tester.widget<IconButton>(_icon('选择下载分集')).onPressed!;
      choose();
      choose();
      await tester.pumpAndSettle();
      expect(routes.pushed.whereType<PopupRoute>(), hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      Navigator.of(tester.element(find.byType(DownloadRangeSheet))).pop();
      await tester.pumpAndSettle();
      expect(downloads.added, isEmpty);
      expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNotNull);
      expect(tester.widget<IconButton>(_icon('刷新分集')).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('bulk failures release controls and retain fixed guidance', (
    tester,
  ) async {
    final (_, downloads, _, _) = await mount(tester);
    downloads.pending = Completer<void>();
    await tester.tap(_icon('选择下载分集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入下载（3 集）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DownloadRangeSheet), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNull);
    expect(tester.widget<IconButton>(_icon('刷新分集')).onPressed, isNull);
    expect(tester.widget<FilledButton>(getPrimary()).onPressed, isNotNull);
    downloads.pending!.completeError(_failure);
    await tester.pumpAndSettle();
    expect(downloads.added, [('e1', 0), ('e2', 1), ('e3', 2)]);
    expect(find.text('3 集未加入队列，请检查网络和设备空间后重试'), findsOneWidget);
    expect(find.textContaining('token=private'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<IconButton>(_icon('选择下载分集')).onPressed, isNotNull);
    expect(tester.widget<IconButton>(_icon('刷新分集')).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving during a load ignores its late page update', (
    tester,
  ) async {
    final (_, _, provider, _) = await mount(tester, cached: false);
    await tester.pumpWidget(const SizedBox());
    provider.complete(_rows());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
