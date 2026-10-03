import 'dart:async';

import 'playback_session.dart';

class PlaybackLifecycleSnapshot {
  const PlaybackLifecycleSnapshot({
    required this.active,
    required this.streaming,
    required this.loading,
    this.position,
  });
  final bool active, streaming, loading;
  final Duration? position;
}

class PlaybackResumeIntent {
  PlaybackResumeIntent._(this._revision, this._play);
  final int _revision;
  final bool _play;
}

/// Coordinates viewer intent, automatic PiP grace and complete-path resumption.
/// The page supplies native effects; no widget or system event is retained.
class PlaybackLifecycleController {
  PlaybackLifecycleController({
    required this.session,
    required this.snapshot,
    required this.save,
    required this.pause,
    required this.play,
    required this.cancelProgressive,
    required this.restoreComplete,
    required this.cancelPrefetch,
    required this.schedulePrefetch,
    required this.syncPage,
    required this.trim,
    Timer Function(Duration, void Function())? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  final PlaybackSessionController session;
  final PlaybackLifecycleSnapshot Function() snapshot;
  final void Function() save, cancelPrefetch, schedulePrefetch, syncPage, trim;
  final Future<void> Function() pause, play, cancelProgressive;
  final Future<bool> Function(bool, Duration?) restoreComplete;
  final Timer Function(Duration, void Function()) _timerFactory;
  Timer? _backgroundTimer;
  bool _closed = false;
  bool _foreground = true, _pipActive = false;
  bool _playIntent = true, _pendingPlay = false;
  bool _restoreOnResume = false, _resumePlay = false;
  Duration? _resumePosition;
  bool? _pipEntryWasPlaying;
  int _intentRevision = 0;

  bool get foreground => _foreground;
  bool get pipActive => _pipActive;
  bool get playIntent => _playIntent;
  bool get canPlay => !_closed && (_foreground || _pipActive);

  PlaybackResumeIntent captureIntent(bool play) =>
      PlaybackResumeIntent._(_intentRevision, play);
  bool resumeIntent(PlaybackResumeIntent intent) =>
      !_closed &&
      (intent._revision == _intentRevision ? intent._play : _playIntent);

  void _updateIntent(bool play) {
    // A renewed pause command also supersedes a captured request to play.
    _intentRevision++;
    _playIntent = play;
    if (_restoreOnResume) _resumePlay = play;
    if (!play) _pendingPlay = false;
  }

  void setPlayIntent(bool play) {
    if (_closed) return;
    _updateIntent(play);
    if (_pipEntryWasPlaying != null) _pipEntryWasPlaying = play;
  }

  void beginActivation(bool play) {
    if (_closed) return;
    _pendingPlay = false;
    _updateIntent(play);
  }

  void selectionChanged() {
    _restoreOnResume = false;
    _backgroundTimer?.cancel();
  }

  /// Called after installing an active source, before attempting playback.
  bool deferPlayback() {
    if (_closed) return true;
    final state = snapshot();
    if (!state.streaming) _restoreOnResume = false;
    if (canPlay) return false;
    _pendingPlay = _playIntent;
    if (state.streaming) _suspend(_playIntent);
    return true;
  }

  void nativePlaying(bool playing) {
    if (_closed) return;
    if (canPlay && !snapshot().loading) {
      _updateIntent(playing);
    }
  }

  void beginPipEntry(bool playing) => _pipEntryWasPlaying = playing;
  void cancelPipEntry() => _pipEntryWasPlaying = null;

  void nativePipStarted() {
    if (_closed) return;
    setPipActive(true);
    final wasPlaying = _pipEntryWasPlaying;
    _pipEntryWasPlaying = null;
    final state = snapshot();
    if (!_closed && wasPlaying == true && state.active && !state.loading) {
      unawaited(play());
    }
  }

  void nativePipStopped() {
    _pipEntryWasPlaying = null;
    setPipActive(false);
  }

  void setPipActive(bool active) {
    if (_closed || _pipActive == active) return;
    _pipActive = active;
    final state = snapshot();
    if (active) {
      _backgroundTimer?.cancel();
      if (_restoreOnResume && state.streaming) {
        _restore();
        return;
      }
      if (_pendingPlay && state.active) {
        _pendingPlay = false;
        unawaited(play());
      }
      schedulePrefetch();
    } else if (!_foreground) {
      _updateIntent(false);
      _pendingPlay = false;
      cancelPrefetch();
      trim();
      if (state.streaming) {
        _resumePlay = false;
        _suspend(false);
      } else if (state.active) {
        unawaited(pause());
      }
    }
  }

  void setForeground(bool foreground) {
    if (_closed) return;
    _foreground = foreground;
    final state = snapshot();
    if (!foreground) {
      save();
      if (!_pipActive) {
        cancelPrefetch();
        _backgroundTimer?.cancel();
        final ticket = session.generation;
        _backgroundTimer = _timerFactory(const Duration(milliseconds: 800), () {
          if (!_closed && session.isCurrent(ticket) && !canPlay) {
            trim();
            if (snapshot().streaming) _suspend(_playIntent);
          }
        });
      }
    } else {
      if (_backgroundTimer?.isActive == true &&
          state.streaming &&
          _playIntent) {
        _pendingPlay = true;
      }
      _backgroundTimer?.cancel();
      if (_restoreOnResume) {
        _restore();
      } else if (_pendingPlay) {
        _pendingPlay = false;
        if (state.active) unawaited(play());
      }
      syncPage();
      schedulePrefetch();
    }
  }

  void _suspend(bool playIntent) {
    if (_restoreOnResume) return;
    _restoreOnResume = true;
    _resumePlay = playIntent;
    _resumePosition = snapshot().position;
    _pendingPlay = false;
    unawaited(pause().catchError((Object _) {}));
    unawaited(cancelProgressive().catchError((Object _) {}));
  }

  void _restore() {
    _restoreOnResume = false;
    _pendingPlay = false;
    unawaited(restoreComplete(_resumePlay, _resumePosition));
  }

  void close() {
    _closed = true;
    _pendingPlay = false;
    _pipEntryWasPlaying = null;
    _backgroundTimer?.cancel();
  }
}
