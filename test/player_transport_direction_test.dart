import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/player_transport.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/theme.dart';

void main() {
  for (final sample in [
    (const Size(640, 360), 1.0, true),
    (const Size(720, 480), 1.0, true),
    (const Size(720, 480), 1.8, true),
    (const Size(960, 540), 1.8, false),
  ]) {
    for (final firstEpisode in [true, false]) {
      testWidgets(
        'TV transport follows visual rows at $sample first=$firstEpisode',
        (tester) async {
          tester.view.physicalSize = sample.$1;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final play = FocusNode();
          addTearDown(play.dispose);
          var opened = 0, changed = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: guoguoTheme(Brightness.dark, television: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(sample.$2)),
                child: TelevisionScope(
                  enabled: true,
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.select):
                          ActivateIntent(),
                    },
                    child: child!,
                  ),
                ),
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    child: PlayerTransport(
                      duration: 120000,
                      position: 10000,
                      playing: true,
                      enabled: true,
                      speed: 1,
                      playFocusNode: play,
                      onPlay: () => changed++,
                      onPrevious: firstEpisode ? null : () => changed++,
                      onNext: () => changed++,
                      onEpisodes: () => opened++,
                      onSpeed: (_) {},
                      onScrub: (_) {},
                      onSeek: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final episodes = find.widgetWithText(TextButton, '选集');
          final speed = find.byTooltip('播放倍速');
          final wrapped =
              tester.getCenter(episodes).dy > tester.getCenter(speed).dy + 30;
          expect(wrapped, sample.$3);
          play.requestFocus();
          await tester.pump();
          Future<void> key(LogicalKeyboardKey value) async {
            await tester.sendKeyEvent(value);
            await tester.pumpAndSettle();
          }

          bool focused(String label) =>
              Focus.of(tester.element(find.text(label))).hasPrimaryFocus;
          await key(LogicalKeyboardKey.arrowRight);
          expect(focused('下一集'), true);
          await key(LogicalKeyboardKey.arrowRight);
          expect(focused('1.0x'), true);
          await key(LogicalKeyboardKey.arrowRight);
          if (wrapped) {
            expect(focused('1.0x'), true);
            await key(LogicalKeyboardKey.arrowDown);
            expect(focused('选集'), true);
            await key(LogicalKeyboardKey.arrowLeft);
            expect(focused('选集'), true);
            await key(LogicalKeyboardKey.arrowUp);
            expect(
              FocusManager.instance.primaryFocus!.rect.center.dy,
              lessThan(tester.getCenter(episodes).dy),
            );
            expect(focused('上一集'), !firstEpisode);
            await key(LogicalKeyboardKey.arrowDown);
          }
          expect(focused('选集'), true);
          await key(LogicalKeyboardKey.arrowRight);
          expect(focused('选集'), true);
          await key(LogicalKeyboardKey.select);
          expect(opened, 1);
          expect(changed, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
