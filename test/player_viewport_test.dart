import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/player_viewport.dart';

void main() {
  testWidgets(
    'player fills portrait, landscape and tablet viewport after resize',
    (tester) async {
      final controller = BetterPlayerController(
        const BetterPlayerConfiguration(autoDispose: false),
      );
      final key = GlobalKey();
      for (final size in [
        const Size(390, 700),
        const Size(844, 390),
        const Size(768, 1024),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox.expand(
              child: PlayerViewport(controller: controller, playerKey: key),
            ),
          ),
        );
        await tester.pump();
        expect(
          controller.getAspectRatio(),
          closeTo(size.width / size.height, .001),
        );
        final viewport = tester.getSize(find.byType(PlayerViewport));
        expect(viewport, size);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose(forceDispose: true);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
