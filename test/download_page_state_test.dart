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

Future<({AppStore store, _Downloads downloads, _Routes routes})> _mount(
  WidgetTester tester,
  List<DownloadEntry> entries, {
  bool home = false,
}) async {
  tester.view.physicalSize = const Size(1024, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
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
  return (store: store, downloads: downloads, routes: routes);
}

IconButton _play(WidgetTester tester, int number) => tester.widget<IconButton>(
  find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == '播放第 $number 集',
  ),
);

void main() {
  testWidgets('repeated play checks once and opens one sparse offline queue', (
    tester,
  ) async {
    final (:downloads, :routes, store: _) = await _mount(tester, [
      _entry(4),
      _entry(1),
      _entry(2, ready: false),
    ]);
    await tester.tap(find.text('已完成 2'));
    await tester.pumpAndSettle();
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

  testWidgets(
    'another route opened during the check is not replaced by a player',
    (tester) async {
      final (:downloads, :routes, store: _) = await _mount(tester, [_entry(1)]);
      _play(tester, 1).onPressed!();
      routes.navigator!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/cover'),
          builder: (_) => const Scaffold(body: Text('另一页面')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      downloads.checks.single.complete('/offline.mp4');
      await tester.pumpAndSettle();
      expect(find.text('另一页面'), findsOneWidget);
      expect(routes.players, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the downloads tab invalidates an old check after returning',
    (tester) async {
      final (:downloads, :routes, store: _) = await _mount(tester, [
        _entry(1),
      ], home: true);
      _play(tester, 1).onPressed!();
      await tester.pump();
      await tester.tap(find.text('剧库'));
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
      expect(find.text('第 2 集'), findsOneWidget);
      expect(find.text('第 1 集'), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '未完成 1'))
            .selected,
        isTrue,
      );
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
      expect(find.text('未完成 1'), findsOneWidget);
      expect(find.text('已完成 2'), findsOneWidget);
      expect(find.text('删除 (1)'), findsOneWidget);
      first.ready = true;
      downloads.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('删除 (0)'), findsOneWidget);
      await tester.tap(find.text('已完成 3'));
      await tester.pumpAndSettle();
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
      await tester.tap(find.text('全部 3'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('第 4 集'));
      await tester.pumpAndSettle();
      expect(find.text('删除 (1)'), findsOneWidget);
      await tester.tap(find.text('全部站源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('黄果'));
      await tester.pumpAndSettle();
      expect(find.text('删除 (0)'), findsOneWidget);
      expect(find.text('全部 1'), findsOneWidget);
      expect(find.text('本地测试'), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('黄果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部站源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按剧空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地测试'));
      await tester.pumpAndSettle();
      expect(find.text('正在查看单部剧 · 显示全部'), findsOneWidget);
      expect(find.text('全部 2'), findsOneWidget);
      expect(find.text('未完成 1'), findsOneWidget);
      expect(find.text('已完成 1'), findsOneWidget);
      expect(find.text('另一站的剧'), findsNothing);
      expect(
        tester.getTopLeft(find.text('第 1 集')).dy,
        lessThan(tester.getTopLeft(find.text('第 4 集')).dy),
      );
      await tester.tap(find.text('正在查看单部剧 · 显示全部'));
      await tester.pumpAndSettle();
      expect(find.text('全部 3'), findsOneWidget);
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
      await tester.tap(find.text('失败 2'));
      await tester.pumpAndSettle();
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
      expect(find.text('失败 2'), findsOneWidget);
      expect(find.text('删除 (1)'), findsOneWidget);
      expect(find.textContaining('1 个已重试，1 个未完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
