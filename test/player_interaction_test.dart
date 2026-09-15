import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  testWidgets(
    'default player hides chrome; tapping reveals controls within safe areas',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(
              'dev.fluttercommunity.plus/connectivity_status',
            ),
            (_) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'dev.fluttercommunity.plus/connectivity_status',
              ),
              null,
            ),
      );
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      final downloads = DownloadStore(store);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 44, bottom: 34),
            ),
            child: PlayerPage(
              store: store,
              downloads: downloads,
              drama: const Drama(
                id: '1',
                source: DramaSource.hongguo,
                title: '一部长标题短剧用于检查安全区域与控制条',
              ),
              episodes: [
                Episode.fromJson({'id': '1'}, 0),
              ],
              initialIndex: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回').hitTestable(), findsNothing);
      await tester.tapAt(const Offset(195, 300));
      // Resolve the single-vs-double-tap recognizer before checking chrome.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.byTooltip('返回')).dy,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getBottomRight(find.byType(PlayerTransport)).dy,
        lessThanOrEqualTo(810),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
  testWidgets(
    'vertical paging tracks the finger and settles onto the next episode',
    (tester) async {
      final pages = PageController();
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: EpisodePager(
            controller: pages,
            count: 3,
            onChanged: (index) => selected = index,
            builder: (context, index) => ColoredBox(
              color: Colors.black,
              child: Center(child: Text('episode$index')),
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(const Offset(400, 450));
      await drag.moveBy(const Offset(0, -150));
      await tester.pump();
      await drag.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(pages.page, greaterThan(0));
      expect(pages.page, lessThan(1));
      await drag.moveBy(const Offset(0, -200));
      await drag.up();
      await tester.pumpAndSettle();
      expect(selected, 1);
      await tester.pumpWidget(const SizedBox());
      pages.dispose();
    },
  );
  testWidgets(
    'transport fits a small phone and seeks only after scrub release',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final seeks = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PlayerTransport(
                duration: 100000,
                position: 1000,
                playing: true,
                enabled: true,
                speed: 1,
                onPlay: () {},
                onEpisodes: () {},
                onSpeed: (_) {},
                onScrub: (_) {},
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + 40, rect.center.dy),
      );
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(seeks, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(seeks, hasLength(1));
      expect(seeks.single, greaterThan(1000));
      expect(tester.takeException(), isNull);
    },
  );
}
