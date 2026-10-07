import 'models.dart';

enum WatchStatus { watching, nextEpisode, waiting, completed, episodeCompleted }

/// Resolves against the full catalog by ID, never a sparse download queue.
class WatchResume {
  factory WatchResume(WatchRecord? record, List<Episode>? episodes) {
    final rows = episodes ?? const <Episode>[];
    final saved = record == null
        ? -1
        : rows.indexWhere((episode) => episode.id == record.episodeId);
    var resumeIndex = saved < 0 ? 0 : saved;
    var state = WatchStatus.watching;
    if (record != null && record.episodeCompleted) {
      if (saved >= 0 && saved + 1 < rows.length) {
        resumeIndex = saved + 1;
        state = WatchStatus.nextEpisode;
      } else if (saved >= 0 && record.drama.status == 'ongoing') {
        state = WatchStatus.waiting;
      } else if (saved >= 0 &&
          const {'finished', 'completed'}.contains(record.drama.status)) {
        resumeIndex = 0;
        state = WatchStatus.completed;
      } else {
        state = WatchStatus.episodeCompleted;
      }
    }
    return WatchResume._(
      resumeIndex,
      state,
      rows.isEmpty ? null : rows[resumeIndex],
    );
  }

  const WatchResume._(this.index, this.status, this.episode);

  final int index;
  final WatchStatus status;
  final Episode? episode;

  bool get canContinue =>
      status == WatchStatus.watching || status == WatchStatus.nextEpisode;
}
