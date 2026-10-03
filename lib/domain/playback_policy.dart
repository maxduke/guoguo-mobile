enum RecoveryAction { alternative, refresh, stop }

/// One budget per selected episode, reset only by an explicit user retry.
class PlaybackRecovery {
  int _attempts = 0;
  bool _refreshed = false;
  void reset() {
    _attempts = 0;
    _refreshed = false;
  }

  RecoveryAction next({required bool alternative}) {
    if (_attempts >= 3) return RecoveryAction.stop;
    if (alternative) {
      _attempts++;
      return RecoveryAction.alternative;
    }
    if (!_refreshed) {
      _attempts++;
      _refreshed = true;
      return RecoveryAction.refresh;
    }
    return RecoveryAction.stop;
  }
}

class PlaybackHealth {
  Duration? _position;
  DateTime? _progressAt;
  void reset() {
    _position = null;
    _progressAt = null;
  }

  bool stalled(
    Duration position,
    DateTime now, {
    required bool watching,
    Duration timeout = const Duration(seconds: 20),
  }) {
    if (!watching || position != _position) {
      _position = position;
      _progressAt = now;
      return false;
    }
    _progressAt ??= now;
    return now.difference(_progressAt!) >= timeout;
  }
}

bool shouldPrefetch({
  required Duration position,
  required Duration duration,
  required Duration bufferedAhead,
  required bool playing,
  required bool buffering,
  required bool local,
}) =>
    playing &&
    !buffering &&
    duration > Duration.zero &&
    position >= const Duration(seconds: 2) &&
    (local || bufferedAhead >= const Duration(seconds: 5)) &&
    (position.inMilliseconds >= duration.inMilliseconds ~/ 2 ||
        duration - position <= const Duration(seconds: 45));
