import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/playback_policy.dart';
import 'package:guoguo_mobile/platform/playback_lifecycle.dart';
import 'package:guoguo_mobile/platform/playback_recovery.dart';
import 'package:guoguo_mobile/platform/playback_session.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

class _Timer implements Timer {
  _Timer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
  @override
  void cancel() => _active = false;
  void fire({bool force = false}) {
    if (!force && !_active) return;
    _active = false;
    callback();
  }
}

class _Provider implements ProviderClient {
  int resolves = 0, fallbacks = 0;
  bool failFallback = false;
  Completer<Map<String, dynamic>>? fallbackGate;
  final releases = <String>[];
  Map<String, dynamic> plan(String id) => {
    'url': 'https://example.test/$id.mp4',
    'remoteUrl': 'https://example.test/$id.mp4',
    'session': id,
    'routeCount': 4,
  };
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    switch (method) {
      case 'resolve':
        return plan('resolve-${++resolves}');
      case 'fallback':
        fallbacks++;
        if (failFallback) throw StateError('fallback failed');
        return fallbackGate == null
            ? plan('fallback-$fallbacks')
            : await fallbackGate!.future;
      case 'release':
        releases.add(args['id'] as String);
        return {};
      case 'cancelPrefetch':
        return {};
      default:
        throw StateError(method);
    }
  }
}

class _Fixture {
  final provider = _Provider();
  final events = <String>[];
  final timers = <_Timer>[];
  final restores = <({bool play, Duration? position})>[];
  bool active = true, streaming = true, loading = false;
  Duration position = const Duration(seconds: 8);
  Completer<void>? pauseGate;
  final actions = <RecoveryAction>[];
  final replacements = <ResolvedMedia?>[];
  int failures = 0;
  late final session = PlaybackSessionController(
    provider: provider,
    drama: const Drama(id: 'fixture', source: DramaSource.hongguo, title: '交接'),
    episodes: [
      Episode.fromJson({'id': '1'}, 0),
    ],
    localFile: (_) async => null,
    canResolve: () => true,
    progressive: (_) => false,
    completePrefetch: () => true,
    onPhase: (_, _) {},
  );
  late final recovery = PlaybackRecoveryController(session, provider);
  late final lifecycle = PlaybackLifecycleController(
    session: session,
    snapshot: () => PlaybackLifecycleSnapshot(
      active: active,
      streaming: streaming,
      loading: loading,
      position: position,
    ),
    save: () => events.add('save'),
    pause: () async => events.add('pause'),
    play: () async => events.add('play'),
    cancelProgressive: () async => events.add('cancel'),
    restoreComplete: (play, position) async {
      restores.add((play: play, position: position));
      return true;
    },
    cancelPrefetch: () => events.add('stop-prefetch'),
    trim: () => events.add('trim'),
    schedulePrefetch: () => events.add('prefetch'),
    syncPage: () => events.add('sync'),
    timerFactory: (duration, callback) {
      final timer = _Timer(duration, callback);
      timers.add(timer);
      return timer;
    },
  );
  _Fixture() {
    addTearDown(() async {
      lifecycle.close();
      recovery.close();
      session.close();
      await settle();
    });
  }
  Future<void> prepare() async {
    await session.prepare(0, ticket: session.invalidate());
  }

  Future<void> recover() => recovery.recover(
    0,
    pause: () async {
      await pauseGate?.future;
    },
    onAction: actions.add,
    restart: replacements.add,
    onFailure: () => failures++,
  );
}

void main() {
  test(
    'AirPlay permits AVPlayer control in background without suspending its media',
    () {
      final f = _Fixture()..streaming = false;
      f.lifecycle.setAirPlayActive(true);
      f.lifecycle.setForeground(false);
      expect(f.lifecycle.canPlay, true);
      expect(f.lifecycle.deferPlayback(), false);
      f.lifecycle.nativePlaying(false);
      expect(f.lifecycle.playIntent, false);
      f.lifecycle.setPipActive(true);
      f.lifecycle.setPipActive(false);
      expect(f.events, isNot(contains('pause')));
      expect(f.timers, isEmpty);
      f.lifecycle.setAirPlayActive(false);
      expect(f.lifecycle.canPlay, false);
    },
  );

  test(
    'AirPlay activation cancels a pending progressive background suspension',
    () {
      final f = _Fixture();
      f.lifecycle.setForeground(false);
      f.lifecycle.setAirPlayActive(true);
      f.timers.single.fire();
      expect(f.events, isNot(contains('cancel')));
      expect(f.lifecycle.canPlay, true);
    },
  );
  test(
    'late PiP and foreground cannot play the phone while TV owns playback',
    () {
      final f = _Fixture()..streaming = false;
      f.lifecycle.beginPipEntry(true);
      f.lifecycle.setExternalPlayback(true);
      f.lifecycle.setPlayIntent(true);
      expect(f.lifecycle.deferPlayback(), isTrue);
      f.lifecycle.nativePipStarted();
      f.lifecycle.setForeground(false);
      f.lifecycle.setForeground(true);
      expect(f.events, isNot(contains('play')));
      expect(f.restores, isEmpty);
      // The final TV state replaces the phone's old deferred playback intent.
      f.lifecycle.setExternalPlayback(false);
      f.lifecycle.setPlayIntent(false);
      expect(f.lifecycle.deferPlayback(), isFalse);
      expect(f.lifecycle.playIntent, isFalse);
    },
  );
  test(
    'old background grace cannot suspend or restore media during casting',
    () {
      final f = _Fixture();
      f.lifecycle.setForeground(false);
      f.lifecycle.setExternalPlayback(true);
      f.timers.single.fire(force: true);
      f.lifecycle.nativePipStarted();
      f.lifecycle.setForeground(true);
      expect(f.events, isNot(contains('trim')));
      expect(f.events, isNot(contains('cancel')));
      expect(f.restores, isEmpty);
    },
  );
  test(
    'foreground native pause updates intent, setup and background pauses do not',
    () {
      final f = _Fixture();
      f.lifecycle.nativePlaying(false);
      expect(f.lifecycle.playIntent, isFalse);
      f.lifecycle.nativePlaying(true);
      expect(f.lifecycle.playIntent, isTrue);
      f.loading = true;
      f.lifecycle.nativePlaying(false);
      expect(f.lifecycle.playIntent, isTrue);
      f.loading = false;
      f.lifecycle.setForeground(false);
      f.lifecycle.nativePlaying(false);
      expect(f.lifecycle.playIntent, isTrue);
      f.lifecycle.setForeground(true);
      f.lifecycle.nativePlaying(false);
      expect(f.lifecycle.playIntent, isFalse);
    },
  );

  for (final nativeFirst in [false, true]) {
    test(
      'timely automatic PiP preserves preparation: native first $nativeFirst',
      () {
        final f = _Fixture();
        if (nativeFirst) f.lifecycle.nativePipStarted();
        f.lifecycle.setForeground(false);
        if (!nativeFirst) {
          expect(f.timers.single.delay, const Duration(milliseconds: 800));
          f.lifecycle.nativePipStarted();
          f.timers.single.fire(force: true);
        }
        expect(f.lifecycle.canPlay, isTrue);
        expect(f.events, isNot(contains('cancel')));
        expect(f.events, isNot(contains('trim')));
        expect(f.restores, isEmpty);
      },
    );
  }

  for (final intent in [false, true]) {
    test('late automatic PiP restores complete source with intent $intent', () {
      final f = _Fixture();
      f.lifecycle.setPlayIntent(intent);
      f.lifecycle.setForeground(false);
      f.timers.single.fire();
      expect(f.events, containsAllInOrder(['trim', 'pause', 'cancel']));
      f.position = Duration.zero; // Closed native origin may reset its value.
      f.lifecycle.nativePipStarted();
      f.lifecycle.nativePipStarted();
      expect(f.restores, [
        (play: intent, position: const Duration(seconds: 8)),
      ]);
      expect(f.events, isNot(contains('play')));
    });
    test('foreground within grace retains origin and intent $intent', () {
      final f = _Fixture();
      f.lifecycle.setPlayIntent(intent);
      f.lifecycle.setForeground(false);
      f.lifecycle.setForeground(true);
      f.timers.single.fire(force: true);
      expect(f.events.where((e) => e == 'play').length, intent ? 1 : 0);
      expect(f.events, isNot(contains('cancel')));
      expect(f.events, containsAllInOrder(['sync', 'prefetch']));
      expect(f.restores, isEmpty);
    });
  }

  test(
    'source installed in background waits for a permitted playback context',
    () {
      final f = _Fixture()..streaming = false;
      f.lifecycle.setForeground(false);
      f.lifecycle.beginActivation(true);
      expect(f.lifecycle.deferPlayback(), isTrue);
      f.lifecycle.nativePipStarted();
      expect(f.events.where((e) => e == 'play'), hasLength(1));
      f.lifecycle.setForeground(true);
      expect(f.events.where((e) => e == 'play'), hasLength(1));
    },
  );

  test(
    'stream installed in background suspends then restores at its saved position',
    () {
      final f = _Fixture()..active = false;
      f.lifecycle.setForeground(false);
      f.lifecycle.beginActivation(true);
      f.active = true;
      expect(f.lifecycle.deferPlayback(), isTrue);
      f.lifecycle.nativePipStarted();
      expect(f.events, contains('cancel'));
      expect(f.events, isNot(contains('play')));
      expect(f.restores, [(play: true, position: f.position)]);
    },
  );

  test('PiP close clears pending playback and foreground stays paused', () {
    final f = _Fixture()..streaming = false;
    f.lifecycle.setForeground(false);
    f.lifecycle.setPipActive(true);
    f.lifecycle.setPipActive(false);
    f.lifecycle.setForeground(true);
    expect(f.lifecycle.playIntent, isFalse);
    expect(f.events, contains('pause'));
    expect(f.events, isNot(contains('play')));
  });

  test('explicit pause updates a suspended resume intent', () {
    final f = _Fixture();
    f.lifecycle.setForeground(false);
    f.timers.single.fire();
    f.lifecycle.setPlayIntent(false);
    f.lifecycle.setForeground(true);
    expect(f.restores, [(play: false, position: f.position)]);
  });

  test(
    'captured resume respects later intent changes but ignores setup pause',
    () {
      for (final initialIntent in [false, true]) {
        final f = _Fixture();
        f.lifecycle.setPlayIntent(initialIntent);
        final intent = f.lifecycle.captureIntent(true);
        f.lifecycle.setPipActive(true);
        f.loading = true;
        f.lifecycle.nativePlaying(false);
        expect(f.lifecycle.resumeIntent(intent), isTrue);
        f.lifecycle.setForeground(false);
        f.lifecycle.nativePipStopped();
        expect(f.lifecycle.resumeIntent(intent), isFalse);
        f.lifecycle.setPlayIntent(true);
        expect(f.lifecycle.resumeIntent(intent), isTrue);
        f.lifecycle.close();
        expect(f.lifecycle.resumeIntent(intent), isFalse);
      }
    },
  );

  test(
    'old grace callbacks cannot trim a later activation or a closed page',
    () {
      for (final mode in ['activation', 'selection', 'close']) {
        final f = _Fixture();
        f.lifecycle.setForeground(false);
        final previous = f.events.length;
        if (mode == 'close') {
          f.lifecycle.close();
        } else {
          if (mode == 'selection') f.lifecycle.selectionChanged();
          f.session.invalidate();
        }
        f.timers.single.fire(force: true);
        expect(f.events, hasLength(previous));
        if (mode == 'close') {
          f.lifecycle.nativePipStarted();
          f.lifecycle.nativePipStopped();
          f.lifecycle.setForeground(true);
          expect(f.lifecycle.deferPlayback(), isTrue);
          expect(f.events, hasLength(previous));
        }
      }
    },
  );

  test(
    'native PiP transition pause retains captured explicit entry intent',
    () {
      final f = _Fixture();
      f.lifecycle.beginPipEntry(true);
      f.lifecycle.setPipActive(true);
      f.lifecycle.nativePlaying(false);
      f.lifecycle.nativePipStarted();
      expect(f.events.where((e) => e == 'play'), hasLength(1));
      f.lifecycle.beginPipEntry(false);
      f.lifecycle.nativePipStarted();
      expect(f.events.where((e) => e == 'play'), hasLength(1));
      f.loading = true;
      f.lifecycle.nativePlaying(true);
      expect(f.lifecycle.playIntent, isFalse);
    },
  );

  test(
    'recovery budget survives automatic restarts and resets for explicit retry',
    () async {
      final f = _Fixture();
      await f.prepare();
      for (var i = 0; i < 4; i++) {
        await f.recover();
      }
      expect(f.provider.fallbacks, 3);
      expect(f.actions.last, RecoveryAction.stop);
      expect(f.replacements, hasLength(3));
      f.recovery.reset();
      await f.recover();
      expect(f.provider.fallbacks, 4);
      for (final media in f.replacements) {
        await f.session.releaseUnused(media);
      }
    },
  );

  test(
    'fallback failure uses a single refresh then exhausts the budget',
    () async {
      final f = _Fixture();
      f.provider.failFallback = true;
      await f.prepare();
      await f.recover();
      expect(f.replacements, [null]);
      await f.recover();
      expect(f.actions.last, RecoveryAction.stop);
      expect(f.replacements, hasLength(1));
      expect(f.failures, 0);
    },
  );

  test(
    'duplicate recovery is blocked while pause or fallback is pending',
    () async {
      final f = _Fixture();
      f.pauseGate = Completer();
      f.provider.fallbackGate = Completer();
      await f.prepare();
      final pending = f.recover();
      expect(f.recovery.recovering, isTrue);
      await f.recover();
      expect(f.actions, hasLength(1));
      f.pauseGate!.complete();
      await settle();
      await f.recover();
      expect(f.provider.fallbacks, 1);
      f.provider.fallbackGate!.complete(f.provider.plan('replacement'));
      await pending;
      expect(f.recovery.recovering, isFalse);
      expect(f.replacements.single?.session, 'replacement');
      await f.session.releaseUnused(f.replacements.single);
    },
  );

  test(
    'late fallback after selection or close is released without restart',
    () async {
      for (final close in [false, true]) {
        final f = _Fixture();
        f.provider.fallbackGate = Completer();
        await f.prepare();
        final pending = f.recover();
        await settle();
        if (close) {
          f.recovery.close();
          f.session.close();
        } else {
          f.session.invalidate();
        }
        f.provider.fallbackGate!.complete(f.provider.plan('late'));
        await pending;
        expect(f.provider.releases, contains('late'));
        expect(f.replacements, isEmpty);
        expect(f.failures, 0);
        expect(f.recovery.recovering, isFalse);
      }
    },
  );

  test('pause failure clears recovery guard for a later request', () async {
    final f = _Fixture();
    await f.prepare();
    await f.recovery.recover(
      0,
      pause: () async => throw StateError('pause failed'),
      onAction: f.actions.add,
      restart: f.replacements.add,
      onFailure: () => f.failures++,
    );
    expect(f.failures, 1);
    expect(f.recovery.recovering, isFalse);
    await f.recover();
    expect(f.replacements, hasLength(1));
    await f.session.releaseUnused(f.replacements.single);
  });

  test(
    'compatibility guard blocks duplicates and an older completion cannot clear a newer guard',
    () async {
      final f = _Fixture();
      final oldTicket = f.session.invalidate();
      final oldGate = Completer<bool>();
      final old = f.recovery.compatible(oldTicket, () => oldGate.future);
      expect(await f.recovery.compatible(oldTicket, () async => true), isFalse);
      final nextTicket = f.session.invalidate();
      final nextGate = Completer<bool>();
      final next = f.recovery.compatible(nextTicket, () => nextGate.future);
      oldGate.complete(false);
      expect(await old, isFalse);
      expect(f.recovery.recovering, isTrue);
      nextGate.complete(true);
      expect(await next, isTrue);
      expect(f.recovery.recovering, isFalse);
      f.recovery.close();
      expect(
        await f.recovery.compatible(nextTicket, () async => true),
        isFalse,
      );
    },
  );
}
