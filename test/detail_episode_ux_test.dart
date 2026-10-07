import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/episode_grid.dart';

import 'widget_test.dart' show NoNetwork;

const drama = Drama(
  id: 'detail-ux',
  source: DramaSource.hongguo,
  title: '山海有归期',
  description: '一段很长的故事。\n一段很长的故事。\n一段很长的故事。',
  episodes: 70,
);

List<Episode> episodes([int count = 70]) => [
  for (var i = 0; i < count; i++)
    Episode.fromJson({'id': 'e$i', 'currentEpisode': (i + 1) * 2}, i),
];

class FakeDownloads extends DownloadStore {
  FakeDownloads(super.app);
}

void main() {
  testWidgets('range stays chosen across resume changes and locates current', (
    tester,
  ) async {
    var rows = episodes();
    var current = 4;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return EpisodeGrid(
                episodes: rows,
                initialIndex: current,
                onJump: (_) {},
                builder: (_, index) => Text('分集 ${rows[index].number}'),
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('2–60 集'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('62–120 集').last);
    await tester.pumpAndSettle();
    update(() => current = 65);
    await tester.pump();
    expect(find.text('62–120 集'), findsOneWidget);
    update(() {
      rows = [
        for (var i = 0; i < 30; i++)
          Episode.fromJson({'id': 'new$i', 'currentEpisode': 1000 + i}, i),
        ...rows,
      ];
      current = 95;
    });
    await tester.pump();
    // The chosen range remains anchored to e30 after new episodes are added.
    expect(find.text('62–120 集'), findsOneWidget);
    await tester.tap(find.text('定位当前'));
    await tester.pump();
    expect(find.text('122–140 集'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.selected == true &&
            widget.properties.label == '第 132 集',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large text and existing history remain safe while episodes load',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      store.catalog.episodeCache[drama.key] = episodes();
      store.records.restore(
        RecordBackup([], [
          WatchRecord(
            drama: drama,
            episodeId: 'e35',
            episodeIndex: 35,
            positionMs: 3000,
            durationMs: 60000,
            updatedAt: DateTime.now(),
          ),
        ]),
        {},
      );
      final downloads = FakeDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: DetailPage(store: store, downloads: downloads, drama: drama),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.text('继续第 72 集'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('定位当前'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(390, 700),
    const Size(640, 320),
    const Size(1024, 700),
  ]) {
    testWidgets('detail keeps actions visible and updates resume at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      store.catalog.episodeCache[drama.key] = episodes();
      final downloads = FakeDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(store: store, downloads: downloads, drama: drama),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-primary-play')), findsOneWidget);
      expect(find.text('开始观看'), findsOneWidget);
      expect(find.byTooltip('选择下载分集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await store.records.saveWatch(
        WatchRecord(
          drama: drama,
          episodeId: 'e35',
          episodeIndex: 35,
          positionMs: 3000,
          durationMs: 60000,
          updatedAt: DateTime.now(),
        ),
      );
      await tester.pump();
      expect(find.text('继续第 72 集'), findsOneWidget);
      if (size.width < 900) {
        await tester.scrollUntilVisible(
          find.text('定位当前'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('detail-primary-play')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    });
  }
}
