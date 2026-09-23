import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'widget_test.dart' show NoNetwork;

class _Downloads extends DownloadStore {
  _Downloads(super.app);
  final removed = <String>[];
  final retried = <String>[];
  final retryFailures = <String>{};
  @override
  Future<void> retry(DownloadEntry entry) async {
    retried.add(entry.id);
    if (retryFailures.contains(entry.id)) throw StateError('fixture failure');
    entry.failure = null;
    entry.status = TaskStatus.enqueued;
    notifyListeners();
  }

  @override
  Future<void> refreshUsage() async {
    for (final entry in entries) {
      bytesByEntry.putIfAbsent(entry.id, () => 0);
    }
  }

  @override
  Future<String?> localFile(Drama drama, Episode episode) async =>
      '/offline.mp4';
  @override
  Future<void> remove(DownloadEntry entry) async {
    removed.add(entry.id);
    entries.remove(entry);
    notifyListeners();
  }
}

DownloadEntry _entry(int number) => DownloadEntry(
  id: '$number',
  drama: const Drama(id: 'test', source: DramaSource.hongguo, title: '同一部剧'),
  episode: Episode(
    id: '$number',
    title: '第 $number 集',
    number: number,
    raw: {'id': '$number'},
  ),
  index: number - 1,
  directory: '/missing',
  input: 'video.mp4',
  contentKey: '',
  process: false,
  tasks: [],
  ready: true,
);

class _Routes extends NavigatorObserver {
  Route<dynamic>? last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    last = route;
  }
}

void main() {
  testWidgets(
    'space groups include all states and sort by disk use across sources',
    (tester) async {
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _Downloads(store);
      final other = DownloadEntry.fromJson({
        ..._entry(8).toJson(),
        'drama': const Drama(
          id: 'test',
          source: DramaSource.huangguo,
          title: '另一站的剧',
        ).toJson(),
      });
      downloads.entries = [_entry(1), _entry(2)..ready = false, other];
      downloads.bytesByEntry.addAll({'1': 1024, '2': 2048, '8': 8192});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              store: store,
              downloads: downloads,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('按剧空间'));
      await tester.pumpAndSettle();
      expect(find.text('11.0 KB'), findsOneWidget);
      expect(find.text('红果 · 已完成 1/2 集'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('另一站的剧')).dy,
        lessThan(tester.getTopLeft(find.text('同一部剧')).dy),
      );
      await tester.longPress(find.text('同一部剧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除 (2)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('涉及 1 部剧、2 集'), findsOneWidget);
      expect(find.textContaining('3.0 KB。'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(downloads.removed, ['1', '2']);
      expect(downloads.entries, [other]);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets('batch retry targets failures and reports partial success', (
    tester,
  ) async {
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
    final downloads = _Downloads(store)
      ..entries = [
        _entry(1)
          ..ready = false
          ..failure = '网络连接中断',
        _entry(2)
          ..ready = false
          ..failure = '存储写入失败',
        _entry(3)
          ..ready = false
          ..userPaused = true,
        _entry(4),
      ];
    downloads.retryFailures.add('2');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadsPage(
            store: store,
            downloads: downloads,
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试失败任务 (2)'));
    await tester.pumpAndSettle();
    expect(downloads.retried, ['1', '2']);
    expect(find.textContaining('1 个已重试，1 个未完成'), findsOneWidget);
    expect(downloads.entries[2].userPaused, isTrue);
    expect(downloads.entries[3].complete, isTrue);
    expect(find.text('重试失败任务 (1)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    store.dispose();
  });

  testWidgets(
    'storage selection remains usable with large text on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _Downloads(store)
        ..entries = [
          _entry(1),
          _entry(2)
            ..ready = false
            ..failure = '网络连接中断，请检查网络后重新下载',
        ];
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: DownloadsPage(
              store: store,
              downloads: downloads,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('按剧空间'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('同一部剧'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.longPress(find.text('同一部剧'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'download opens the selected local episode with original indices',
    (tester) async {
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _Downloads(store)
        ..entries = [_entry(4), _entry(1), _entry(2)..ready = false];
      final routes = _Routes();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Scaffold(
            body: DownloadsPage(
              store: store,
              downloads: downloads,
              onOpen: (_) => fail('must open player directly'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放第 4 集'));
      // Inspect the pushed route before mounting the platform video player.
      final route = routes.last! as MaterialPageRoute<void>;
      final player =
          route.builder(tester.element(find.byType(DownloadsPage)))
              as PlayerPage;
      expect(player.initialIndex, 1);
      expect(player.episodes.map((e) => e.number), [1, 4]);
      expect(player.episodeIndices, [0, 3]);
      expect(player.localOnly, isTrue);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'group selection, cancellation, and batch deletion on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _Downloads(store)..entries = [_entry(1), _entry(4)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              store: store,
              downloads: downloads,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('同一部剧'), findsOneWidget);
      expect(find.byTooltip('播放第 4 集'), findsOneWidget);
      await tester.longPress(find.text('第 4 集'));
      await tester.pumpAndSettle();
      expect(find.text('删除 (1)'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除 (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(downloads.removed, isEmpty);
      await tester.tap(find.text('删除 (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(downloads.removed, ['1', '4']);
      expect(find.text('还没有已完成的视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'swipe deletion requires confirmation and removes only that episode',
    (tester) async {
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _Downloads(store)..entries = [_entry(1), _entry(4)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              store: store,
              downloads: downloads,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('4')), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(downloads.removed, isEmpty);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(downloads.removed, ['4']);
      expect(find.text('第 1 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
}
