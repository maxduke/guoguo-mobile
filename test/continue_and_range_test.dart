import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/download_range_sheet.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'widget_test.dart' show NoNetwork;

class RangeDownloads extends DownloadStore {
  RangeDownloads(super.app);
  final added = <int>[];
  @override
  Future<void> enqueue(Drama drama, Episode episode, int index) async {
    added.add(index);
  }
}

class Routes extends NavigatorObserver {
  Route<dynamic>? last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    last = route;
  }
}

const drama = Drama(id: 'serial', source: DramaSource.hongguo, title: '续播示例');
List<Episode> chapters() =>
    List.generate(20, (i) => Episode.fromJson({'id': 'e$i'}, i));
AppStore fixture({
  bool completed = false,
  String status = '',
  String episodeId = 'e4',
  int index = 4,
}) {
  final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
    ..offline = true;
  store.catalog.episodeCache[drama.key] = chapters();
  store.records.restore(
    RecordBackup([], [
      WatchRecord(
        drama: Drama.fromJson({...drama.toJson(), 'status': status}),
        episodeId: episodeId,
        episodeIndex: index,
        episodeCompleted: completed,
        positionMs: 15000,
        durationMs: 60000,
        updatedAt: DateTime.now(),
      ),
    ]),
    {},
  );
  return store;
}

void main() {
  testWidgets(
    'continue and history show original non-contiguous episode numbers',
    (tester) async {
      final store = fixture();
      store.catalog.episodeCache[drama.key] = [
        for (var i = 0; i < 20; i++)
          Episode.fromJson({'id': 'e$i', 'currentEpisode': (i + 1) * 2}, i),
      ];
      final downloads = RangeDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 10 集 · 已看 25%'), findsOneWidget);
      await tester.tap(find.text('追剧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史 1'));
      await tester.pumpAndSettle();
      expect(find.text('红果 · 第 10 集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'personal continue card follows source filter including empty source',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = fixture();
      const yellow = Drama(
        id: 'yellow',
        source: DramaSource.huangguo,
        title: '黄果记录',
      );
      store.records.restore(
        RecordBackup([], [
          WatchRecord(
            drama: yellow,
            episodeId: 'yellow-one',
            episodeIndex: 0,
            positionMs: 1000,
            durationMs: 60000,
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ]),
        {},
      );
      final downloads = RangeDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('追剧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部站源'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '黄果'));
      await tester.pumpAndSettle();
      expect(find.text('接着上次看 · 黄果'), findsOneWidget);
      expect(find.text('接着上次看 · 红果'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, '黄果'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '黄豆'));
      await tester.pumpAndSettle();
      expect(find.textContaining('接着上次看'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'continue card shows watched time when progressive total is unknown',
    (tester) async {
      final store = fixture();
      store.records.restore(
        RecordBackup([], [
          WatchRecord(
            drama: drama,
            episodeId: 'e4',
            episodeIndex: 4,
            positionMs: 65000,
            durationMs: 0,
            updatedAt: DateTime.now(),
          ),
        ]),
        {},
      );
      final downloads = RangeDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 5 集 · 已看 1分5秒'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets('continue card pushes player directly at saved episode', (
    tester,
  ) async {
    final store = fixture();
    final downloads = RangeDownloads(store);
    final routes = Routes();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [routes],
        home: HomePage(store: store, downloads: downloads, autoLoad: false),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('接着上次看 · 红果').hitTestable());
    final route = routes.last! as MaterialPageRoute<void>;
    final player =
        route.builder(tester.element(find.byType(HomePage))) as PlayerPage;
    expect(player.initialIndex, 4);
    expect(player.episodes[4].id, 'e4');
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    store.dispose();
  });

  testWidgets(
    'completed episode card and detail both continue at the next ID',
    (tester) async {
      final store = fixture(completed: true);
      final downloads = RangeDownloads(store);
      final routes = Routes();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 5 集已播完 · 接着看第 6 集'), findsOneWidget);
      await tester.tap(find.text('接着上次看 · 红果').hitTestable());
      final route = routes.last! as MaterialPageRoute<void>;
      final player =
          route.builder(tester.element(find.byType(HomePage))) as PlayerPage;
      expect(player.initialIndex, 5);
      expect(player.episodes[5].id, 'e5');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(store: store, downloads: downloads, drama: drama),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('继续第 6 集'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  for (final status in ['ongoing', 'finished', '']) {
    testWidgets(
      'completed last episode status=$status leaves continue cards and remains in history',
      (tester) async {
        final store = fixture(
          completed: true,
          status: status,
          episodeId: 'e19',
          index: 19,
        );
        final downloads = RangeDownloads(store);
        await tester.pumpWidget(
          MaterialApp(
            home: HomePage(store: store, downloads: downloads, autoLoad: false),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('接着上次看'), findsNothing);
        await tester.tap(find.text('追剧'));
        await tester.pumpAndSettle();
        expect(find.textContaining('接着上次看'), findsNothing);
        await tester.tap(find.text('历史 1'));
        await tester.pumpAndSettle();
        expect(
          find.text(switch (status) {
            'ongoing' => '红果 · 第 20 集 · 等待更新',
            'finished' => '红果 · 已看完',
            _ => '红果 · 第 20 集 · 本集已看完',
          }),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(store: store, downloads: downloads, drama: drama),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(status == 'finished' ? '重新观看' : '重看第 20 集'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      },
    );
  }

  for (final adjacent in [true, false]) {
    testWidgets(
      'offline completion advances only to an adjacent original slot: $adjacent',
      (tester) async {
        final store = fixture(completed: true)..catalog.episodeCache.clear();
        final downloads = RangeDownloads(store);
        for (final index in [4, adjacent ? 5 : 9]) {
          downloads.entries.add(
            DownloadEntry(
              id: 'saved-$index',
              drama: drama,
              episode: chapters()[index],
              index: index,
              directory: '/fixture',
              input: 'video.mp4',
              contentKey: '',
              process: false,
              tasks: [],
              ready: true,
            ),
          );
        }
        final routes = Routes();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [routes],
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => continueDrama(
                  context,
                  store,
                  downloads,
                  store.records.history[drama.key]!,
                ),
                child: const Text('continue'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('continue'));
        final route = routes.last! as MaterialPageRoute<void>;
        final player =
            route.builder(tester.element(find.byType(TextButton)))
                as PlayerPage;
        expect(player.localOnly, true);
        expect(player.initialIndex, adjacent ? 1 : 0);
        expect(player.episodeIndices, [4, adjacent ? 5 : 9]);
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      },
    );
  }

  testWidgets(
    'detail marks downloaded episodes and queues next ten from saved episode',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = fixture();
      final downloads = RangeDownloads(store)
        ..entries.add(
          DownloadEntry(
            id: 'saved',
            drama: drama,
            episode: chapters().first,
            index: 0,
            directory: '/fixture',
            input: 'video.mp4',
            contentKey: '',
            process: false,
            tasks: [],
            ready: true,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(store: store, downloads: downloads, drama: drama),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已下载'), findsOneWidget);
      await tester.tap(find.byTooltip('选择下载分集'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadRangeSheet), findsOneWidget);
      await tester.tap(find.text('加入下载（10 集）'));
      await tester.pumpAndSettle();
      expect(downloads.added, List.generate(10, (i) => i + 4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'range presets clamp to remaining episodes and allow whole drama',
    (tester) async {
      (int, int)? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showModalBottomSheet<(int, int)>(
                    context: context,
                    builder: (_) => DownloadRangeSheet(
                      episodes: chapters(),
                      startIndex: 18,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('加入下载（2 集）'), findsOneWidget);
      await tester.tap(find.text('整部下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入下载（20 集）'));
      await tester.pumpAndSettle();
      expect(selected, (0, 19));
      expect(tester.takeException(), isNull);
    },
  );
}
