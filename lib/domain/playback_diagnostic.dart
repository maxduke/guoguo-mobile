import 'models.dart';

enum PlaybackResult { started, failed, cancelled }

/// Explicit fields only: never store upstream URLs, keys or exception strings.
class PlaybackDiagnostic {
  const PlaybackDiagnostic({
    required this.source,
    required this.episode,
    required this.at,
    required this.result,
    required this.local,
    required this.preloaded,
    required this.resolveMs,
    required this.prepareMs,
    required this.setupMs,
    required this.waitMs,
    required this.elapsedMs,
    this.preparation = 'direct',
    this.compatibilityFallback = false,
  });
  final DramaSource source;
  final int episode, resolveMs, prepareMs, setupMs, waitMs, elapsedMs;
  final DateTime at;
  final PlaybackResult result;
  final bool local, preloaded;
  final String preparation;
  final bool compatibilityFallback;
  Map<String, dynamic> toJson() => {
    'source': source.name,
    'episode': episode,
    'at': at.toIso8601String(),
    'result': result.name,
    'local': local,
    'preloaded': preloaded,
    'resolveMs': resolveMs,
    'prepareMs': prepareMs,
    'setupMs': setupMs,
    'waitMs': waitMs,
    'elapsedMs': elapsedMs,
    'preparation': preparation,
    'compatibilityFallback': compatibilityFallback,
  };
  factory PlaybackDiagnostic.fromJson(Map<String, dynamic> json) =>
      PlaybackDiagnostic(
        source: DramaSource.parse(json['source']),
        episode: json['episode'] as int,
        at: DateTime.parse(json['at'] as String),
        result: PlaybackResult.values.byName(json['result'] as String),
        local: json['local'] == true,
        preloaded: json['preloaded'] == true,
        resolveMs: json['resolveMs'] as int,
        prepareMs: json['prepareMs'] as int,
        setupMs: json['setupMs'] as int,
        waitMs: json['waitMs'] as int,
        elapsedMs: json['elapsedMs'] as int,
        preparation:
            const {
              'direct',
              'complete',
              'progressive',
            }.contains(json['preparation'])
            ? json['preparation'] as String
            : 'direct',
        compatibilityFallback: json['compatibilityFallback'] == true,
      );
}

class PreparationTiming {
  int resolveMs = 0, prepareMs = 0, setupMs = 0;
  bool local = false, compatibilityFallback = false;
  String preparation = 'direct';
}

class PlaybackAttempt {
  PlaybackAttempt({
    required this.source,
    required this.episode,
    required this.preloaded,
  });
  final DramaSource source;
  final int episode;
  final bool preloaded;
  final DateTime at = DateTime.now();
  final Stopwatch clock = Stopwatch()..start();
  PreparationTiming timing = PreparationTiming();
  int waitMs = 0;
  Duration? initialPosition;
  bool finished = false;
  PlaybackDiagnostic? finish(PlaybackResult result) {
    if (finished) return null;
    finished = true;
    clock.stop();
    return PlaybackDiagnostic(
      source: source,
      episode: episode,
      at: at,
      result: result,
      local: timing.local,
      preloaded: preloaded,
      resolveMs: timing.resolveMs,
      prepareMs: timing.prepareMs,
      setupMs: timing.setupMs,
      waitMs: waitMs,
      elapsedMs: clock.elapsedMilliseconds,
      preparation: timing.preparation,
      compatibilityFallback: timing.compatibilityFallback,
    );
  }
}
