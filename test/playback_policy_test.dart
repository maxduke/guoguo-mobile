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
      await store.setPlayback(advance: false, speed: 1.5);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      expect(restored.autoAdvance, false);
      expect(restored.playbackSpeed, 1.5);
      storage.value!.remove('autoAdvance');
      storage.value!.remove('playbackSpeed');
      final legacy = AppStore(storage: storage, provider: NoNetwork());
      await legacy.load();
      expect(legacy.autoAdvance, true);
      expect(legacy.playbackSpeed, 1);
      store.dispose();
      restored.dispose();
      legacy.dispose();
    },
  );
}
