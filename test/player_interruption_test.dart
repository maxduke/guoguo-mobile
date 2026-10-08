import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/player_gestures.dart';
import 'package:guoguo_mobile/ui/player_transport.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  for (final interruption in [
    'cancel',
    'disabled',
    'media changed',
    'background',
    'removed',
  ]) {
    testWidgets('slider $interruption cancels without seeking', (tester) async {
      final seeks = <double>[];
      final scrubs = <bool>[];
      var enabled = true;
      var mediaIdentity = 0;
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PlayerTransport(
                mediaIdentity: mediaIdentity,
                duration: 100000,
                position: 1000,
                playing: true,
                enabled: enabled,
                speed: 1,
                onPlay: () {},
                onEpisodes: () {},
                onSpeed: (_) {},
                onScrub: scrubs.add,
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      );

      await mount();
      final rect = tester.getRect(find.byType(Slider));
      final drag = await tester.startGesture(
        rect.centerLeft + const Offset(40, 0),
      );
      await drag.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(scrubs, [true]);
      expect(seeks, isEmpty);
      switch (interruption) {
        case 'cancel':
          await drag.cancel();
        case 'disabled':
          enabled = false;
          await mount();
        case 'media changed':
          mediaIdentity++;
          await mount();
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
        case 'removed':
          await tester.pumpWidget(const SizedBox());
      }
      expect(scrubs, [true, false]);
      expect(seeks, isEmpty);
      enabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await mount();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1000);
      if (interruption != 'cancel') {
        await drag.moveBy(const Offset(40, 0));
        await drag.up();
        await tester.pump();
        expect(seeks, isEmpty);
      }
      await tester.drag(find.byType(Slider), const Offset(100, 0));
      await tester.pump();
      expect(seeks, hasLength(1));
      expect(scrubs, [true, false, true, false]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final interruption in [
    'disabled',
    'media changed',
    'background',
    'removed',
  ]) {
    for (final boost in [false, true]) {
      testWidgets(
        'video ${boost ? 'boost' : 'scrub'} $interruption releases state',
        (tester) async {
          final seeks = <double>[];
          final boosts = <bool>[];
          final scrubs = <bool>[];
          var enabled = true;
          var mediaIdentity = 0;
          Future<void> mount() => tester.pumpWidget(
            MaterialApp(
              home: PlayerGestures(
                mediaIdentity: mediaIdentity,
                enabled: enabled,
                position: () => 50000,
                duration: () => 100000,
                onSeek: seeks.add,
                onBoost: boosts.add,
                onScrub: scrubs.add,
                onTap: () {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          );
          await mount();
          final drag = await tester.startGesture(const Offset(300, 300));
          if (boost) {
            await tester.pump(const Duration(milliseconds: 600));
            expect(boosts, [true]);
          } else {
            await drag.moveBy(const Offset(80, 0));
            await drag.moveBy(const Offset(80, 0));
            await tester.pump();
            expect(find.textContaining('松手跳转'), findsOneWidget);
          }
          switch (interruption) {
            case 'disabled':
              enabled = false;
              await mount();
            case 'media changed':
              mediaIdentity++;
              await mount();
            case 'background':
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
              await tester.pump();
            case 'removed':
              await tester.pumpWidget(const SizedBox());
          }
          expect(seeks, isEmpty);
          expect(scrubs.last, false);
          expect(boosts, boost ? [true, false] : isEmpty);
          enabled = true;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await mount();
          await drag.moveBy(const Offset(80, 0));
          await drag.up();
          await tester.pump();
          expect(seeks, isEmpty);
          expect(find.textContaining('松手跳转'), findsNothing);
          expect(find.textContaining('2 倍速'), findsNothing);
          await tester.drag(find.byType(PlayerGestures), const Offset(160, 0));
          await tester.pump();
          expect(seeks, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a speed menu cannot apply its selection to replacement media', (
    tester,
  ) async {
    final speeds = <double>[];
    final scrubs = <bool>[];
    var mediaIdentity = 0;
    Future<void> mount() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerTransport(
            mediaIdentity: mediaIdentity,
            duration: 100000,
            position: 1000,
            playing: true,
            enabled: true,
            speed: 1,
            onPlay: () {},
            onEpisodes: () {},
            onSpeed: speeds.add,
            onScrub: scrubs.add,
            onSeek: (_) => fail('choosing speed must not seek'),
          ),
        ),
      ),
    );
    await mount();
    await tester.tap(find.byTooltip('播放倍速'));
    await tester.pumpAndSettle();
    expect(scrubs, [true]);
    mediaIdentity++;
    await mount();
    expect(scrubs, [true, false]);
    await tester.tap(find.text('1.5 倍速'));
    await tester.pumpAndSettle();
    expect(speeds, isEmpty);
    expect(scrubs, [true, false]);
    await tester.tap(find.byTooltip('播放倍速'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5 倍速'));
    await tester.pumpAndSettle();
    expect(speeds, [1.5]);
    expect(scrubs, [true, false, true, false]);
    expect(tester.takeException(), isNull);
  });
}
