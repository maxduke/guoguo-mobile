import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/playback_policy.dart';
import 'package:guoguo_mobile/platform/episode_buffer.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  test('recovery tries alternatives, refreshes once and stops', () {
    final recovery = PlaybackRecovery();
    expect(recovery.next(alternative: true), RecoveryAction.alternative);
    expect(recovery.next(alternative: true), RecoveryAction.alternative);
    expect(recovery.next(alternative: false), RecoveryAction.refresh);
    expect(recovery.next(alternative: true), RecoveryAction.stop);
    recovery.reset();
    expect(recovery.next(alternative: false), RecoveryAction.refresh);
    expect(recovery.next(alternative: false), RecoveryAction.stop);
  });

  test('pause, seek and lifecycle changes restart the stall interval', () {
    final health = PlaybackHealth();
    final start = DateTime(2026);
    bool stalled(int seconds, {bool watching = true, int position = 5}) =>
        health.stalled(
          Duration(seconds: position),
          start.add(Duration(seconds: seconds)),
          watching: watching,
        );
    expect(stalled(0), false);
    expect(stalled(19), false);
    expect(stalled(20), true);
    expect(stalled(21, position: 6), false);
    expect(stalled(50, watching: false), false);
    expect(stalled(51), false);
    health.reset();
    expect(stalled(100), false);
  });

  test(
    'progressive waiting at zero uses the shorter interval and resets on progress',
    () {
      final health = PlaybackHealth();
      final start = DateTime(2026);
      bool stalled(int seconds, {int position = 0, bool watching = true}) =>
          health.stalled(
            Duration(seconds: position),
            start.add(Duration(seconds: seconds)),
            watching: watching,
            timeout: const Duration(seconds: 10),
          );
      expect(stalled(0), isFalse);
      expect(stalled(9), isFalse);
      expect(stalled(10), isTrue);
      expect(stalled(11, position: 1), isFalse);
      expect(stalled(20, position: 1), isFalse);
      expect(stalled(21, position: 1), isTrue);
      expect(stalled(22, watching: false), isFalse);
      expect(stalled(40, watching: false), isFalse);
      expect(stalled(41), isFalse);
      expect(stalled(49), isFalse);
      expect(stalled(50), isTrue);
    },
  );

  test(
    'preload waits for progress and buffered headroom, even near the end',
    () {
      bool ready(
        int position, {
        int buffer = 8,
        bool local = false,
        bool buffering = false,
      }) => shouldPrefetch(
        position: Duration(seconds: position),
        duration: const Duration(seconds: 120),
        bufferedAhead: Duration(seconds: buffer),
        playing: true,
        buffering: buffering,
        local: local,
      );
      expect(ready(1), false);
      expect(ready(30), false);
      expect(ready(60), true);
      expect(ready(100, buffer: 2), false);
      expect(ready(100, buffering: true), false);
      expect(ready(100, buffer: 0, local: true), true);
    },
  );

  test('expired prepared routes are released and resolved again', () async {
    var fresh = true, loads = 0;
    final released = <int>[];
    final buffer = EpisodeBuffer<int>(
      load: (_, _) async => ++loads,
      release: (value) async => released.add(value),
      isReusable: (_) => fresh,
    );
    expect(await buffer.prepare(0), 1);
    expect(await buffer.prepare(0), 1);
    fresh = false;
    expect(await buffer.prepare(0), 2);
    expect(released, [1]);
    buffer.close();
  });

  test(
    'playback preferences survive restart and old records keep defaults',
    () async {
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      expect(store.progressivePreparation, isFalse);
      await store.setPlayback(advance: false, speed: 1.5, progressive: true);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      expect(restored.autoAdvance, false);
      expect(restored.playbackSpeed, 1.5);
      expect(restored.progressivePreparation, isTrue);
      storage.value!.remove('autoAdvance');
      storage.value!.remove('playbackSpeed');
      storage.value!.remove('progressivePreparation');
      final legacy = AppStore(storage: storage, provider: NoNetwork());
      await legacy.load();
      expect(legacy.autoAdvance, true);
      expect(legacy.playbackSpeed, 1);
      expect(legacy.progressivePreparation, isFalse);
      store.dispose();
      restored.dispose();
      legacy.dispose();
    },
  );
}
