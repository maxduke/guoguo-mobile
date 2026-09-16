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
AppStore fixture() {
  final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
    ..offline = true;
  store.episodeCache[drama.key] = chapters();
  store.history[drama.key] = WatchRecord(
    drama: drama,
    episodeId: 'e4',
    episodeIndex: 4,
    positionMs: 15000,
    durationMs: 60000,
    updatedAt: DateTime.now(),
  );
  return store;
}

void main() {
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
