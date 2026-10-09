import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/playback_diagnostic.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  test('preparation diagnostics round-trip and read legacy samples', () {
    final attempt =
        PlaybackAttempt(
            source: DramaSource.hongguo,
            episode: 1,
            preloaded: false,
          )
          ..timing.preparation = 'complete'
          ..timing.prefetchBytes = 4096
          ..timing.prefetchMs = 60
          ..timing.compatibilityFallback = true;
    final json = attempt.finish(PlaybackResult.started)!.toJson();
    final restored = PlaybackDiagnostic.fromJson(json);
    expect(restored.preparation, 'complete');
    expect(restored.compatibilityFallback, isTrue);
    expect(restored.prefetchBytes, 4096);
    expect(restored.prefetchMs, 60);
    json.remove('preparation');
    json.remove('compatibilityFallback');
    json.remove('prefetchBytes');
    json.remove('prefetchMs');
    json.remove('operation');
    json.remove('targetMs');
    final legacy = PlaybackDiagnostic.fromJson(json);
    expect(legacy.preparation, 'direct');
    expect(legacy.compatibilityFallback, isFalse);
    expect(legacy.prefetchBytes, 0);
    expect(legacy.prefetchMs, 0);
    expect(legacy.operation, 'startup');
    expect(legacy.targetMs, 0);
  });

  test(
    'diagnostics finish once, remain bounded and persist only explicit fields',
    () async {
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: NoNetwork());
      for (var i = 0; i < 35; i++) {
        final attempt =
            PlaybackAttempt(
                source: DramaSource.hongguo,
                episode: i,
                preloaded: true,
              )
              ..timing.resolveMs = 25
              ..timing.local = true;
        final sample = attempt.finish(PlaybackResult.started)!;
        expect(attempt.finish(PlaybackResult.failed), isNull);
        await store.recordPlayback(sample);
      }
      expect(store.playbackDiagnostics.length, 30);
      final restored = AppStore(storage: storage, provider: NoNetwork());
      await restored.load();
      expect(restored.playbackDiagnostics.first.episode, 34);
      expect(restored.playbackDiagnostics.first.toJson().keys.toSet(), {
        'source',
        'episode',
        'at',
        'result',
        'local',
        'preloaded',
        'resolveMs',
        'prepareMs',
        'setupMs',
        'waitMs',
        'elapsedMs',
        'preparation',
        'compatibilityFallback',
        'prefetchBytes',
        'prefetchMs',
        'operation',
        'targetMs',
      });
      await restored.clearPlaybackDiagnostics();
      expect(storage.value!['playbackDiagnostics'], isEmpty);
      store.dispose();
      restored.dispose();
    },
  );
}
