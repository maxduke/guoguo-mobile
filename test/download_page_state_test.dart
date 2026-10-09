import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/player_page.dart';

import 'widget_test.dart' show NoNetwork;
import 'support/download_page_actions.dart';

DownloadEntry _entry(int number, {bool ready = true, String? failure}) =>
    DownloadEntry(
      id: '$number',
      drama: const Drama(
        id: 'test',
        source: DramaSource.hongguo,
        title: '本地测试',
      ),
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
      ready: ready,
      failure: failure,
    );

class _Downloads extends DownloadStore {
  _Downloads(super.app);
  final checks = <Completer<String?>>[];
  final checked = <String>[];
  final retries = <String>[];
  final retryFailures = <String>{};
  Completer<void>? reloadGate, retryGate;
  int reloads = 0;

  @override
  Future<void> refreshUsage() async {}

  @override
  Future<String?> localFile(Drama drama, Episode episode) {
    checked.add(episode.id);
    final check = Completer<String?>();
    checks.add(check);
    return check.future;
  }

  @override
  Future<void> reload({bool verifyFiles = true}) async {
    reloads++;
    await reloadGate?.future;
    notifyListeners();
  }

  @override
  Future<void> retry(DownloadEntry entry) async {
    retries.add(entry.id);
    await retryGate?.future;
    if (retryFailures.contains(entry.id)) throw StateError('retry failed');
    entry.failure = null;
    entry.status = TaskStatus.enqueued;
    notifyListeners();
  }
}

class _Routes extends NavigatorObserver {
  final players = <MaterialPageRoute<void>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == null && route is MaterialPageRoute<void>) {
      players.add(route);
    }
  }
}

class _NoRequests extends NoNetwork {
  final methods = <String>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    methods.add(method);
    throw StateError('local playback must not contact the provider');
  }
}

Future<({AppStore store, _Downloads downloads, _Routes routes})> _mount(
  WidgetTester tester,
  List<DownloadEntry> entries, {
  bool home = false,
  bool expand = true,
  Size size = const Size(1024, 1400),
  double textScale = 1,
  NoNetwork? provider,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = AppStore(
    storage: MemoryStorage(),
    provider: provider ?? NoNetwork(),
  );
  final downloads = _Downloads(store)..entries = entries;
  final routes = _Routes();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final check in downloads.checks) {
      if (!check.isCompleted) check.complete(null);
    }
    if (downloads.reloadGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    if (downloads.retryGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    await tester.idle();
    downloads.dispose();
    store.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      navigatorObservers: [routes],
      home: home
          ? HomePage(store: store, downloads: downloads, autoLoad: false)
          : Scaffold(
              body: DownloadsPage(
                store: store,
                downloads: downloads,
                onOpen: (_) {},
              ),
            ),
    ),
  );
  await tester.pumpAndSettle();
  if (home) {
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
  }
  if (expand && entries.isNotEmpty) {
    await expandDownloadGroup(tester, dramaKey: entries.first.drama.key);
  }
  return (store: store, downloads: downloads, routes: routes);
}

IconButton _play(WidgetTester tester, int number) => tester.widget<IconButton>(
  find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == '播放第 $number 集',
  ),
);

void main() {
  testWidgets(
    'mixed downloads and new dramas stay visible with episodes collapsed',
    (tester) async {
      final entries = [
        _entry(4),
        _entry(1, ready: false, failure: '失败'),
        _entry(2, ready: false)..processing = true,
      ];
      final (:downloads, routes: _, store: _) = await _mount(
        tester,
        entries,
        expand: false,
      );
      expect(find.text('已下载 1 集 · 下载失败 1 集 · 正在整理视频 1 集'), findsOneWidget);
      expect(find.text('本地播放'), findsOneWidget);
      expect(find.byType(Dismissible), findsNothing);
      final other = DownloadEntry.fromJson({
        ..._entry(8).toJson(),
        'drama': const Drama(
          id: 'test',
          source: DramaSource.huangguo,
          title: '另一站的剧',
          episodes: 99,
        ).toJson(),
      });
      downloads.entries.add(other);
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('2 部剧 · 2 集可播放'), findsOneWidget);
      expect(find.text('查看分集'), findsNWidgets(2));
      expect(find.byType(Dismissible), findsNothing);
      expect(find.textContaining('/99'), findsNothing);
      entries[2]
        ..processing = false
        ..awaitingProcessing = true;
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('等待整理 1 集'), findsOneWidget);
      await expandDownloadGroup(tester, dramaKey: 'hongguo:test');
      expect(find.text('第 1 集'), findsOneWidget);
      expect(find.text('第 8 集'), findsNothing);
      await tester.tap(find.text('收起分集'));
      await tester.pumpAndSettle();
      expect(find.byType(Dismissible), findsNothing);
      expect(downloads.entries.map((e) => e.id), ['4', '1', '2', '8']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (episode: 4, completed: false, label: '继续观看', target: 4, index: 1),
    (episode: 4, completed: true, label: '继续观看', target: 5, index: 2),
    (episode: 1, completed: true, label: '重播第 1 集', target: 1, index: 0),
    (episode: 5, completed: true, label: '重播第 5 集', target: 5, index: 2),
    (episode: 2, completed: false, label: '本地播放', target: 1, index: 0),
  ]) {
    testWidgets(
      'card ${scenario.label} respects local gaps for saved episode ${scenario.episode}',
      (tester) async {
        final provider = _NoRequests();
        final (:downloads, :routes, :store) = await _mount(
          tester,
          [_entry(5), _entry(1), _entry(4), _entry(2, ready: false)],
          expand: false,
          provider: provider,
        );
        store.setOffline(scenario.completed);
        await store.records.saveWatch(
          WatchRecord(
            drama: downloads.entries.first.drama,
            episodeId: '${scenario.episode}',
            episodeIndex: 99,
            episodeCompleted: scenario.completed,
            positionMs: 12000,
            durationMs: 60000,
            updatedAt: DateTime.utc(2026, 10, 8),
          ),
        );
        await tester.pumpAndSettle();
        final element = tester.element(find.byType(DownloadsPage));
        final play = tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('download-play-hongguo:test')),
            )
            .onPressed!;
        expect(find.text(scenario.label), findsOneWidget);
        play();
        play();
        expect(downloads.checked, ['${scenario.target}']);
        downloads.checks.single.complete('/local.mp4');
        await tester.idle();
        final player = routes.players.single.builder(element) as PlayerPage;
        expect(player.initialIndex, scenario.index);
        expect(player.episodeIndices, [0, 3, 4]);
        expect(player.episodes.map((e) => e.number), [1, 4, 5]);
        expect(player.localOnly, isTrue);
        expect(provider.methods, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'removing history restores local play and card check failures are retryable',
    (tester) async {
      final (:downloads, :routes, :store) = await _mount(tester, [
        _entry(1),
      ], expand: false);
      await store.records.saveWatch(
        WatchRecord(
          drama: downloads.entries.single.drama,
          episodeId: '1',
          episodeIndex: 0,
          positionMs: 1000,
          durationMs: 60000,
          updatedAt: DateTime.utc(2026, 10, 8),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsOneWidget);
      await store.records.removeHistory('hongguo:test');
      await tester.pumpAndSettle();
      expect(find.text('本地播放'), findsOneWidget);
      await tester.tap(find.text('本地播放'));
      downloads.checks.single.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('视频文件已不存在，请重新下载'), findsOneWidget);
      expect(routes.players, isEmpty);
      await tester.tap(find.text('本地播放'));
      expect(downloads.checked, ['1', '1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'filters keep full card totals and scope collapsed selection; cancel and sorting retain it',
    (tester) async {
      final (:downloads, routes: _, store: _) = await _mount(tester, [
        _entry(1),
        _entry(2, ready: false),
      ], expand: false);
      downloads.bytesByEntry.addAll({'1': 1024, '2': 2048});
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      await setDownloadFilters(tester, status: '未完成 1');
      expect(find.text('红果 · 2 集下载 · 3.0 KB'), findsOneWidget);
      expect(find.text('已下载 1 集 · 排队中 1 集'), findsOneWidget);
      expect(find.text('1 部剧 · 1 集可播放'), findsOneWidget);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.text('删除 (1)'), findsOneWidget);
      await openDownloadFilters(tester);
      await tester.tap(find.text('已完成 1'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('删除 (1)'), findsOneWidget);
      expect(find.text('全部站源 · 未完成 · 最近添加'), findsOneWidget);
      await setDownloadFilters(tester, sort: '剧名排序');
      expect(find.text('删除 (1)'), findsOneWidget);
      await tester.tap(find.text('删除 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('删除 1 个下载？'), findsOneWidget);
      expect(find.textContaining('1 集，已保存文件占用 2.0 KB'), findsOneWidget);
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      await setDownloadFilters(tester, reset: true);
      expect(find.text('删除 (0)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cards, episodes and filters stay usable at 320px with large text',
    (tester) async {
      final (:downloads, :store, routes: _) = await _mount(
        tester,
        [_entry(1), _entry(4, ready: false, failure: '网络连接中断')],
        expand: false,
        size: const Size(320, 760),
        textScale: 1.6,
      );
      expect(find.text('本地播放').hitTestable(), findsOneWidget);
      expect(find.text('查看分集').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await openDownloadFilters(tester);
      expect(find.text('应用').hitTestable(), findsOneWidget);
      expect(find.text('重置筛选').hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await setDownloadFilters(tester, status: '失败 1');
      expect(find.text('本地播放'), findsOneWidget);
      await expandDownloadGroup(tester);
      await tester.ensureVisible(find.text('第 4 集'));
      expect(find.text('第 1 集'), findsNothing);
      expect(find.text('第 4 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await setDownloadFilters(tester, reset: true);
      expect(find.text('已下载 1 集 · 下载失败 1 集'), findsOneWidget);
      // Group selection stays within the card, including when episodes are open.
      await tester.scrollUntilVisible(
        find.text('多选'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Checkbox), findsWidgets);
      expect(downloads.entries, hasLength(2));
      expect(store.records.history, isEmpty);
    },
  );

  testWidgets(
    'space management uses shared cards and system back restores downloads',
    (tester) async {
      await _mount(tester, [_entry(1)], expand: false, home: true);
      await tester.tap(find.byTooltip('空间管理'));
      await tester.pumpAndSettle();
      expect(find.text('已保存文件占用'), findsOneWidget);
      expect(find.text('本地播放'), findsNothing);
      expect(find.byTooltip('删除整部剧下载'), findsOneWidget);
      final route = ModalRoute.of(tester.element(find.byType(HomePage)))!;
      expect(route.popDisposition, RoutePopDisposition.doNotPop);
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      expect(route.popDisposition, RoutePopDisposition.bubble);
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('我的下载'), findsOneWidget);
      expect(find.text('本地播放'), findsOneWidget);
      expect(find.byType(Dismissible), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('repeated play checks once and opens one sparse offline queue', (
    tester,
  ) async {
    final (:downloads, :routes, store: _) = await _mount(tester, [
      _entry(4),
      _entry(1),
      _entry(2, ready: false),
    ]);
    await setDownloadFilters(tester, status: '已完成 2');
    final element = tester.element(find.byType(DownloadsPage));
    final first = _play(tester, 4).onPressed!;
    final other = _play(tester, 1).onPressed!;
    first();
    first();
    other();
    await tester.pump();
    expect(downloads.checked, ['4']);
    expect(_play(tester, 4).onPressed, isNull);
    expect(_play(tester, 1).onPressed, isNull);
    downloads.checks.single.complete('/offline.mp4');
    // Inspect routes without mounting the platform video player.
    await tester.idle();
    expect(routes.players, hasLength(1));
    final player = routes.players.single.builder(element) as PlayerPage;
    expect(player.initialIndex, 1);
    expect(player.episodes.map((episode) => episode.number), [1, 4]);
    expect(player.episodeIndices, [0, 3]);
    expect(player.localOnly, isTrue);
    other();
    expect(downloads.checked, ['4']);
    routes.navigator!.removeRoute(routes.players.single);
    await tester.pumpAndSettle();
    expect(_play(tester, 1).onPressed, isNotNull);
    _play(tester, 1).onPressed!();
    expect(downloads.checked, ['4', '1']);
    expect(tester.takeException(), isNull);
  });

  for (final missing in [true, false]) {
    testWidgets(
      'file ${missing ? 'missing' : 'check failure'} releases play for retry',
      (tester) async {
        final (:downloads, :routes, store: _) = await _mount(tester, [
          _entry(1),
        ]);
        final play = _play(tester, 1).onPressed!;
        play();
        if (missing) {
          downloads.checks.single.complete(null);
        } else {
          downloads.checks.single.completeError(
            StateError('private-file-path'),
          );
        }
        await tester.pumpAndSettle();
        expect(routes.players, isEmpty);
        expect(downloads.reloads, missing ? 1 : 0);
        expect(
          find.text(missing ? '视频文件已不存在，请重新下载' : '视频暂时无法打开，请重试'),
          findsOneWidget,
        );
        expect(find.textContaining('private-file-path'), findsNothing);
        expect(_play(tester, 1).onPressed, isNotNull);
        play();
        downloads.checks.last.complete('/offline.mp4');
        await tester.idle();
        expect(downloads.checked, ['1', '1']);
        expect(routes.players, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'leaving during the file check rejects callbacks and late navigation',
    (tester) async {
      final (:downloads, :routes, store: _) = await _mount(tester, [_entry(1)]);
      final play = _play(tester, 1).onPressed!;
      play();
      await tester.pumpWidget(const SizedBox());
      play();
      downloads.checks.single.complete(null);
      await tester.idle();
      expect(downloads.checked, ['1']);
      expect(downloads.reloads, 0);
      expect(routes.players, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during missing-file reload does not show late feedback',
    (tester) async {
      final (:downloads, :routes, store: _) = await _mount(tester, [_entry(1)]);
      downloads.reloadGate = Completer<void>();
      _play(tester, 1).onPressed!();
      downloads.checks.single.complete(null);
      await tester.idle();
      expect(downloads.reloads, 1);
      await tester.pumpWidget(const SizedBox());
      downloads.reloadGate!.complete();
      await tester.idle();
      expect(routes.players, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final returnFirst in [false, true]) {
    testWidgets(
      returnFirst
          ? 'returning to the downloads tab does not revive a covered file check'
          : 'another route opened during the check is not replaced by a player',
      (tester) async {
        final (:downloads, :routes, store: _) = await _mount(tester, [
          _entry(1),
        ], home: returnFirst);
        _play(tester, 1).onPressed!();
        routes.navigator!.push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/cover'),
            builder: (_) => const Scaffold(body: Text('另一页面')),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        if (returnFirst) {
          routes.navigator!.pop();
          await tester.pumpAndSettle();
        }
        downloads.checks.single.complete('/offline.mp4');
        await tester.pumpAndSettle();
        expect(find.text(returnFirst ? '我的下载' : '另一页面'), findsOneWidget);
        expect(routes.players, isEmpty);
        if (returnFirst) {
          _play(tester, 1).onPressed!();
          downloads.checks.last.complete('/new.mp4');
          await tester.idle();
          expect(routes.players, hasLength(1));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'leaving the downloads tab invalidates an old check after returning',
    (tester) async {
      final (:downloads, :routes, store: _) = await _mount(tester, [
        _entry(1),
      ], home: true);
      _play(tester, 1).onPressed!();
      await tester.pump();
      await tester.tap(find.text('发现'));
      await tester.pump();
      await tester.tap(find.text('下载'));
      await tester.pump();
      expect(_play(tester, 1).onPressed, isNotNull);
      _play(tester, 1).onPressed!();
      await tester.pump();
      downloads.checks.first.complete('/old.mp4');
      await tester.idle();
      expect(routes.players, isEmpty);
      expect(_play(tester, 1).onPressed, isNull);
      downloads.checks.last.complete('/new.mp4');
      await tester.idle();
      expect(routes.players, hasLength(1));
      expect(downloads.checked, ['1', '1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacing downloads resets the default filter and invalidates old checks',
    (tester) async {
      final (:downloads, :routes, :store) = await _mount(tester, [_entry(1)]);
      _play(tester, 1).onPressed!();
      final replacement = _Downloads(store)
        ..entries = [_entry(2, ready: false)];
      addTearDown(replacement.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Scaffold(
            body: DownloadsPage(
              store: store,
              downloads: replacement,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      downloads.checks.single.complete('/old.mp4');
      await tester.pumpAndSettle();
      expect(routes.players, isEmpty);
      expect(find.text('第 2 集'), findsNothing);
      await expandDownloadGroup(tester);
      expect(find.text('第 2 集'), findsOneWidget);
      expect(find.text('第 1 集'), findsNothing);
      await openDownloadFilters(tester);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部 1'))
            .selected,
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      replacement.entries.single.progress = .5;
      replacement.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('50%'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final removed in [true, false]) {
    testWidgets(
      'a ${removed ? 'removed' : 'no longer complete'} entry cannot open after checking',
      (tester) async {
        final entry = _entry(1);
        final (:downloads, :routes, store: _) = await _mount(tester, [entry]);
        _play(tester, 1).onPressed!();
        if (removed) {
          downloads.entries.clear();
        } else {
          entry.ready = false;
        }
        downloads.notifyListeners();
        downloads.checks.single.complete('/offline.mp4');
        await tester.pumpAndSettle();
        expect(routes.players, isEmpty);
        expect(find.text('视频文件已不存在，请重新下载'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'progress retains selection and completed entries leave the pending selection',
    (tester) async {
      final first = _entry(1, ready: false), second = _entry(2, ready: false);
      final (:downloads, routes: _, store: _) = await _mount(tester, [
        first,
        second,
        _entry(3),
      ]);
      await setDownloadFilters(tester, status: '未完成 2');
      await tester.longPress(find.text('第 1 集'));
      await tester.pumpAndSettle();
      expect(find.text('删除 (1)'), findsOneWidget);
      first.progress = .5;
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('删除 (1)'), findsOneWidget);
      second.ready = true;
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('已下载 2 集 · 排队中 1 集'), findsOneWidget);
      expect(find.text('删除 (1)'), findsOneWidget);
      first.ready = true;
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('删除 (0)'), findsOneWidget);
      await setDownloadFilters(tester, status: '已完成 3');
      expect(find.text('删除 (0)'), findsOneWidget);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((box) => box.value == false),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source changes clear selection and focused groups scope task counts',
    (tester) async {
      final other = DownloadEntry.fromJson({
        ..._entry(8).toJson(),
        'drama': const Drama(
          id: 'test',
          source: DramaSource.huangguo,
          title: '另一站的剧',
        ).toJson(),
      });
      final entries = [_entry(4), _entry(1, ready: false), other];
      final (:downloads, routes: _, store: _) = await _mount(tester, entries);
      await tester.longPress(find.text('第 4 集'));
      await tester.pumpAndSettle();
      expect(find.text('删除 (1)'), findsOneWidget);
      await setDownloadFilters(tester, source: '黄果');
      expect(find.text('删除 (0)'), findsOneWidget);
      expect(find.text('本地测试'), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await setDownloadFilters(tester, reset: true);
      await tester.tap(find.byTooltip('空间管理'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('download-hongguo:test')),
          matching: find.text('查看分集'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('正在查看单部剧 · 显示全部'), findsOneWidget);
      expect(find.text('另一站的剧'), findsNothing);
      await openDownloadFilters(tester);
      for (final label in ['全部 2', '未完成 1', '已完成 1']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('第 1 集')).dy,
        lessThan(tester.getTopLeft(find.text('第 4 集')).dy),
      );
      await tester.tap(find.text('正在查看单部剧 · 显示全部'));
      await tester.pumpAndSettle();
      expect(find.text('2 部剧 · 2 集可播放'), findsOneWidget);
      expect(find.text('另一站的剧'), findsOneWidget);
      expect(downloads.entries.map((entry) => entry.id), ['4', '1', '8']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch retry keeps its targets and retains only failed selections',
    (tester) async {
      final first = _entry(1, ready: false, failure: '失败');
      final second = _entry(2, ready: false, failure: '失败');
      final (:downloads, routes: _, store: _) = await _mount(tester, [
        first,
        second,
      ]);
      downloads.retryFailures.add('2');
      downloads.retryGate = Completer<void>();
      await setDownloadFilters(tester, status: '失败 2');
      await tester.longPress(find.text('第 1 集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试 (2)'));
      await tester.pump();
      downloads.entries.add(_entry(3, ready: false, failure: '新失败'));
      downloads.notifyListeners();
      await tester.pump();
      downloads.retryGate!.complete();
      await tester.pumpAndSettle();
      expect(downloads.retries, ['1', '2']);
      expect(find.text('全部站源 · 失败 · 最近添加'), findsOneWidget);
      expect(find.text('删除 (1)'), findsOneWidget);
      expect(find.textContaining('1 个已重试，1 个未完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
