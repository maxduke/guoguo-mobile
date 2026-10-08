import 'dart:async';

import '../domain/models.dart';

/// Owns the selected episode and watch-record snapshots across playback paths.
/// Native completion evidence and positions are supplied by the player page.
class PlaybackProgressController {
  PlaybackProgressController({
    required this.drama,
    required List<Episode> episodes,
    required int initialIndex,
    required this.saveWatch,
    List<int>? episodeIndices,
    DateTime Function()? now,
  }) : episodes = List.unmodifiable(episodes),
       episodeIndices = episodeIndices == null
           ? null
           : List.unmodifiable(episodeIndices),
       _index = initialIndex,
       _now = now ?? DateTime.now;

  final Drama drama;
  final List<Episode> episodes;
  final List<int>? episodeIndices;
  final Future<void> Function(WatchRecord) saveWatch;
  final DateTime Function() _now;
  int _index;
  bool completed = false;
  DateTime? _lastSaved;

  int get index => _index;

  void select(int index) {
    if (index == _index) return;
    _index = index;
    completed = false;
  }

  /// Periodic updates are bounded; transitions and explicit actions save now.
  void save(Duration position, Duration duration, {bool force = true}) {
    final at = _now();
    if (!force &&
        _lastSaved != null &&
        at.difference(_lastSaved!) < const Duration(seconds: 10)) {
      return;
    }
    _lastSaved = at;
    final episode = episodes[_index];
    final record = WatchRecord(
      drama: drama,
      episodeId: episode.id,
      episodeIndex: episodeIndices?[_index] ?? _index,
      episodeNumber: episode.number,
      episodeCompleted: completed,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      updatedAt: at,
    );
    // RecordStore reports persistence failures and owns its write queue.
    unawaited(saveWatch(record).catchError((Object _) {}));
  }
}
