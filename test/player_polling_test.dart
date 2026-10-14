import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _tick = Duration(milliseconds: 300);

class _NativePlayer {
  static const channel = MethodChannel('better_player_channel');
  static const events = MethodChannel('better_player_channel/videoEvents7');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Completer<void>? playGate, seekGate;
  Completer<int>? positionGate, absoluteGate;
  int creates = 0, plays = 0, polls = 0, absolutePolls = 0, disposals = 0;

  void install() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          creates++;
          return {'textureId': 7};
        case 'setDataSource':
          scheduleMicrotask(
            () => emit('initialized', {
              'duration': 30000,
              'width': 320.0,
              'height': 180.0,
            }),
          );
          return null;
        case 'play':
          plays++;
          await playGate?.future;
          return null;
        case 'position':
          polls++;
          return await positionGate?.future ?? 1000;
        case 'absolutePosition':
          absolutePolls++;
          return await absoluteGate?.future;
        case 'seekTo':
          await seekGate?.future;
          return null;
        case 'dispose':
          disposals++;
          return null;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  }

  void emit(String event, [Map<String, Object?> extra = const {}]) {
    messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': event,
        ...extra,
      }),
      (_) {},
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  }
}

Future<void> _source(
  WidgetTester tester,
  BetterPlayerController player, [
  int episode = 0,
]) async {
  final setup = player.setupDataSource(
    BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.test/episode-$episode.mp4',
    ),
  );
  await tester.pump();
  await setup;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativePlayer native;
  late BetterPlayerController player;

  setUp(() {
    native = _NativePlayer()..install();
    player = BetterPlayerController(
      const BetterPlayerConfiguration(autoDispose: false),
    );
  });
  tearDown(() => native.uninstall());

  Future<void> dispose(WidgetTester tester) async {
    final controller = player.videoPlayerController!;
    // Stream cancellation can complete outside the widget-test fake clock.
    // Await actual teardown while native play/position gates remain unresolved.
    await tester.runAsync(() async {
      player.dispose(forceDispose: true);
      await controller.dispose();
    });
    await tester.pump();
    expect(native.disposals, 1);
  }

  testWidgets('overlapping app and native plays share one polling timer', (
    tester,
  ) async {
    await _source(tester, player);
    native.playGate = Completer<void>();
    final first = player.play();
    final second = player.play();
    native.emit('play');
    await tester.pump();
    expect(native.plays, 3);
    native.playGate!.complete();
    await tester.pump();
    await Future.wait([first, second]);
    await tester.pump(_tick);
    expect(native.polls, 1);
    expect(native.absolutePolls, 1);
    await player.pause();
    await tester.pump(_tick);
    expect(native.polls, 1);
    await dispose(tester);
  });

  for (final transition in ['pause', 'source', 'dispose', 'completed']) {
    testWidgets('late play cannot restart polling after $transition', (
      tester,
    ) async {
      await _source(tester, player);
      native.playGate = Completer<void>();
      final pending = player.play();
      await tester.pump();
      switch (transition) {
        case 'pause':
          native.emit('pause');
          await tester.pump();
        case 'source':
          await _source(tester, player, 1);
        case 'dispose':
          await dispose(tester);
        case 'completed':
          native.emit('completed');
          await tester.pump();
      }
      native.playGate!.complete();
      await tester.pump();
      await pending;
      await tester.pump(_tick);
      expect(native.polls, 0);
      if (transition != 'dispose') {
        expect(player.videoPlayerController!.value.isPlaying, isFalse);
        await dispose(tester);
      }
    });
  }

  for (final pendingAbsolute in [false, true]) {
    for (final transition in ['pause', 'source', 'dispose']) {
      testWidgets(
        'late ${pendingAbsolute ? 'absolute' : 'relative'} position is ignored after $transition',
        (tester) async {
          await _source(tester, player);
          if (pendingAbsolute) {
            native.absoluteGate = Completer<int>();
          } else {
            native.positionGate = Completer<int>();
          }
          await player.play();
          await tester.pump(_tick);
          final controller = player.videoPlayerController!;
          switch (transition) {
            case 'pause':
              await player.pause();
            case 'source':
              await _source(tester, player, 1);
            case 'dispose':
              await dispose(tester);
          }
          final value = controller.value;
          native.positionGate?.complete(17000);
          native.absoluteGate?.complete(1700000000000);
          await tester.pump();
          await tester.pump(_tick);
          expect(identical(controller.value, value), isTrue);
          expect(native.polls, 1);
          expect(native.absolutePolls, pendingAbsolute ? 1 : 0);
          if (transition != 'dispose') await dispose(tester);
        },
      );
    }
  }

  testWidgets('a position notification may synchronously pause playback', (
    tester,
  ) async {
    await _source(tester, player);
    final controller = player.videoPlayerController!;
    Object? pausedValue;
    void pauseOnPosition() {
      if (controller.value.isPlaying &&
          controller.value.position > Duration.zero) {
        unawaited(player.pause());
        pausedValue = controller.value;
      }
    }

    controller.addListener(pauseOnPosition);
    native.absoluteGate = Completer<int>()..complete(1700000000000);
    await player.play();
    await tester.pump(_tick);
    expect(pausedValue, isNotNull);
    expect(identical(controller.value, pausedValue), isTrue);
    await tester.pump(_tick);
    expect(native.polls, 1);
    controller.removeListener(pauseOnPosition);
    await dispose(tester);
  });

  testWidgets('disposed controls and stale polling errors are ignored', (
    tester,
  ) async {
    await _source(tester, player);
    native.positionGate = Completer<int>();
    await player.play();
    await tester.pump(_tick);
    final controller = player.videoPlayerController!;
    await dispose(tester);
    final plays = native.plays;
    await controller.play();
    await controller.pause();
    native.positionGate!.completeError(PlatformException(code: 'disposed'));
    await tester.pump(_tick);
    expect(native.plays, plays);
    expect(native.polls, 1);
    expect(native.absolutePolls, 0);
  });

  testWidgets('a disposal notification shares the same cleanup future', (
    tester,
  ) async {
    await _source(tester, player);
    final controller = player.videoPlayerController!;
    var reentered = false;
    Future<void>? reentrantDisposal;
    controller.addListener(() {
      if (!controller.value.initialized && !reentered) {
        reentered = true;
        reentrantDisposal = controller.dispose();
      }
    });
    await tester.runAsync(() async {
      player.dispose(forceDispose: true);
      final disposal = controller.dispose();
      expect(reentered, isTrue);
      expect(identical(disposal, reentrantDisposal), isTrue);
      await disposal;
    });
    await tester.pump();
    expect(native.disposals, 1);
  });

  testWidgets('slow polling stays bounded across ticks and source changes', (
    tester,
  ) async {
    await _source(tester, player);
    native.positionGate = Completer<int>();
    await player.play();
    await tester.pump(_tick);
    for (var i = 0; i < 10; i++) {
      await tester.pump(_tick);
    }
    expect(native.polls, 1);
    await _source(tester, player, 1);
    await player.play();
    await tester.pump(_tick);
    expect(native.polls, 1);
    native.positionGate!.complete(17000);
    native.positionGate = null;
    await tester.pump();
    expect(player.videoPlayerController!.value.position, Duration.zero);
    await tester.pump(_tick);
    expect(native.polls, 2);
    expect(native.absolutePolls, 1);
    expect(
      player.videoPlayerController!.value.position,
      const Duration(seconds: 1),
    );
    await dispose(tester);
  });

  testWidgets('late seek cannot resume after pause or update a new source', (
    tester,
  ) async {
    await _source(tester, player);
    for (final replace in [false, true]) {
      await player.play();
      native.seekGate = Completer<void>();
      final seek = player.videoPlayerController!.seekTo(
        const Duration(seconds: 12),
      );
      await tester.pump();
      if (replace) {
        await _source(tester, player, 1);
      } else {
        await player.pause();
      }
      final plays = native.plays;
      native.seekGate!.complete();
      await tester.pump();
      await seek;
      await tester.pump(_tick);
      expect(native.plays, plays);
      expect(player.videoPlayerController!.value.isPlaying, isFalse);
      expect(player.videoPlayerController!.value.position, Duration.zero);
    }
    await dispose(tester);
  });

  testWidgets('many episodes retain one player and a constant polling rate', (
    tester,
  ) async {
    for (var episode = 0; episode < 80; episode++) {
      await _source(tester, player, episode);
      native.playGate = Completer<void>();
      final commands = [player.play(), player.play()];
      native.emit('play');
      await tester.pump();
      native.playGate!.complete();
      await tester.pump();
      await Future.wait(commands);
      final before = native.polls;
      await tester.pump(_tick);
      expect(native.polls - before, 1, reason: 'episode $episode');
      await player.pause();
      await tester.pump(_tick);
      expect(native.polls - before, 1, reason: 'paused episode $episode');
    }
    expect(native.creates, 1);
    await dispose(tester);
    final polls = native.polls;
    await tester.pump(const Duration(seconds: 3));
    expect(native.polls, polls);
  });
}
