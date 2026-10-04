import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';

abstract interface class CastRelayHandle {
  Future<String> start(ResolvedMedia media, String? localPath);
  Future<void> close();
}

enum CastPlaybackState { playing, paused, buffering, stopped, unknown }

enum CastPhase { idle, connecting, connected, stopping, returning, failed }

class CastPlayback {
  const CastPlayback({
    this.position,
    this.duration,
    this.state = CastPlaybackState.unknown,
  });
  final Duration? position, duration;
  final CastPlaybackState state;
  bool? get playing => switch (state) {
    CastPlaybackState.playing || CastPlaybackState.buffering => true,
    CastPlaybackState.paused || CastPlaybackState.stopped => false,
    CastPlaybackState.unknown => null,
  };
}

class CastSource {
  const CastSource({
    required this.media,
    required this.title,
    required this.position,
    required this.duration,
    required this.playing,
    this.localPath,
  });
  final ResolvedMedia media;
  final String title;
  final String? localPath;
  final Duration position, duration;
  final bool playing;
}

class CastHandoff {
  const CastHandoff(this.position, this.duration, this.playing);
  final Duration position, duration;
  final bool playing;
}

abstract interface class CastReceiver {
  String get name;
  Future<void> connect();
  Future<void> load(String url, CastSource source);
  Future<CastPlayback> status();
  Future<void> pause();
  Future<void> play();
  Future<void> stop();
  Future<void> close();
}

class CastTarget {
  const CastTarget(this.id, this.name, this.protocol, this.createReceiver);
  final String id, name, protocol;
  final CastReceiver Function() createReceiver;
}

class CastCancelled implements Exception {
  const CastCancelled();
}

/// Owns a cast for one player page. A control sheet only observes this session.
class CastSessionController extends ChangeNotifier {
  CastSessionController({
    required this.captureSource,
    required this.pauseLocal,
    required this.returnLocal,
    required this.relayFactory,
    Timer Function(Duration, void Function())? pollTimer,
  }) : _pollTimerFactory =
           pollTimer ??
           ((interval, tick) => Timer.periodic(interval, (_) => tick()));

  final CastSource Function() captureSource;
  final Future<void> Function() pauseLocal;
  final Future<void> Function(CastHandoff) returnLocal;
  final CastRelayHandle Function() relayFactory;
  final Timer Function(Duration, void Function()) _pollTimerFactory;
  CastPhase phase = CastPhase.idle;
  String? error;
  CastReceiver? _receiver;
  CastRelayHandle? _relay;
  CastSource? source;
  CastPlayback latest = const CastPlayback();
  Duration? _lastPosition, _lastDuration;
  bool? _lastPlaying;
  Future<void> _pending = Future.value();
  Future<void>? _stopping;
  Timer? _timer;
  bool _closed = false, _foreground = true, _polling = false;
  bool _stopRequested = false, _pausedLocal = false;
  int _revision = 0, _commands = 0;

  String? get deviceName => _receiver?.name;
  bool get blocksLocal => phase != CastPhase.idle;
  bool get busy =>
      _commands > 0 ||
      switch (phase) {
        CastPhase.connecting ||
        CastPhase.stopping ||
        CastPhase.returning => true,
        _ => false,
      };
  Duration? get reportedPosition => _lastPosition;
  Duration get duration => _lastDuration ?? source?.duration ?? Duration.zero;
  CastHandoff? get handoff {
    final original = source;
    if (original == null) return null;
    final length = duration;
    var position = _lastPosition ?? original.position;
    if (position < Duration.zero) position = Duration.zero;
    if (length > Duration.zero && position > length) position = length;
    return CastHandoff(position, length, _lastPlaying ?? original.playing);
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _check(int revision) {
    if (_closed || revision != _revision || _stopRequested) {
      throw const CastCancelled();
    }
  }

  Future<void> _queue(Future<void> Function() operation) {
    final next = _pending.catchError((Object _) {}).then((_) => operation());
    _pending = next;
    return next;
  }

  Future<void> start(CastTarget target) {
    if (_closed || blocksLocal) return Future.value();
    phase = CastPhase.connecting;
    error = null;
    _stopRequested = false;
    final revision = ++_revision;
    _notify();
    return _queue(() async {
      try {
        _check(revision);
        source = captureSource();
        latest = const CastPlayback();
        _lastPosition = _lastDuration = null;
        _lastPlaying = null;
        _receiver = target.createReceiver();
        _relay = relayFactory();
        // Pause before loading on the TV so both devices cannot play together.
        _pausedLocal = true;
        await pauseLocal();
        _check(revision);
        await _receiver!.connect().timeout(const Duration(seconds: 20));
        _check(revision);
        final url = await _relay!.start(source!.media, source!.localPath);
        _check(revision);
        await _receiver!
            .load(url, source!)
            .timeout(const Duration(seconds: 25));
        _check(revision);
        final initial = await _receiver!.status().timeout(
          const Duration(seconds: 15),
        );
        _check(revision);
        _accept(initial);
        phase = CastPhase.connected;
        _beginPolling();
        _notify();
      } catch (problem) {
        if (_closed || revision != _revision) return;
        // A failed load may have reached the receiver. Require a confirmed stop
        // before starting the phone again, and keep controls for retry on failure.
        try {
          await _receiver?.stop().timeout(const Duration(seconds: 20));
        } catch (_) {
          phase = CastPhase.failed;
          error = '电视未确认结束，请重试结束投屏后再在手机播放';
          _notify();
          return;
        }
        final original = source;
        await _release();
        if (_closed || revision != _revision) return;
        if (problem is! CastCancelled) error = '投屏未成功：$problem';
        await _return(
          original == null
              ? null
              : CastHandoff(
                  original.position,
                  original.duration,
                  original.playing,
                ),
          revision,
        );
      }
    });
  }

  void _accept(CastPlayback snapshot) {
    latest = snapshot;
    final position = snapshot.position;
    if (position != null && position >= Duration.zero) _lastPosition = position;
    final length = snapshot.duration;
    if (length != null && length > Duration.zero) _lastDuration = length;
    if (snapshot.playing != null) _lastPlaying = snapshot.playing;
  }

  void _beginPolling() {
    _timer?.cancel();
    if (!_foreground || _closed || phase != CastPhase.connected) return;
    _timer = _pollTimerFactory(const Duration(seconds: 2), () {
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    if (_closed ||
        !_foreground ||
        phase != CastPhase.connected ||
        busy ||
        _polling) {
      return Future.value();
    }
    _polling = true;
    final revision = _revision;
    return _queue(() async {
      try {
        _check(revision);
        final snapshot = await _receiver!.status().timeout(
          const Duration(seconds: 15),
        );
        _check(revision);
        _accept(snapshot);
        error = null;
        _notify();
      } on CastCancelled {
        // Closing a sheet does not cancel; ending the owned session does.
      } catch (_) {
        if (!_closed && revision == _revision && !_stopRequested) {
          error = '暂时无法读取电视状态，保留上次进度；可重试结束投屏';
          _notify();
        }
      } finally {
        _polling = false;
      }
    });
  }

  Future<void> setPlaying(bool playing) {
    if (_closed || phase != CastPhase.connected || busy) return Future.value();
    final revision = _revision;
    _commands++;
    _notify();
    return _queue(() async {
      try {
        _check(revision);
        await (playing ? _receiver!.play() : _receiver!.pause()).timeout(
          const Duration(seconds: 15),
        );
        _check(revision);
        // Command acknowledgement reflects explicit user intent even if the
        // device cannot report its playback state; position is never estimated.
        _lastPlaying = playing;
        final snapshot = await _receiver!.status().timeout(
          const Duration(seconds: 15),
        );
        _check(revision);
        _accept(snapshot);
        error = null;
      } on CastCancelled {
        return;
      } catch (_) {
        if (!_closed && revision == _revision && !_stopRequested) {
          error = '电视未确认操作，请重试';
        }
      } finally {
        _commands--;
        _notify();
      }
    });
  }

  Future<void> stop() {
    if (_closed || !blocksLocal) return Future.value();
    if (_stopping != null) return _stopping!;
    _stopRequested = true;
    _timer?.cancel();
    final revision = _revision;
    phase = CastPhase.stopping;
    _notify();
    final operation = _queue(() async {
      if (_closed || revision != _revision || source == null) return;
      try {
        try {
          // Preserve final actual progress before the TV's Stop resets it.
          final snapshot = await _receiver!.status().timeout(
            const Duration(seconds: 15),
          );
          if (_closed || revision != _revision) return;
          _accept(snapshot);
        } catch (_) {
          // Use only the last reported position, or the original phone position.
        }
        if (_closed || revision != _revision) return;
        await _receiver!.stop().timeout(const Duration(seconds: 20));
      } catch (_) {
        if (!_closed && revision == _revision) {
          _stopRequested = false;
          phase = CastPhase.failed;
          error = '电视未确认结束，请重试结束投屏后再在手机播放';
          _notify();
        }
        return;
      }
      final result = handoff;
      await _release();
      if (_closed || revision != _revision) return;
      error = null;
      await _return(result, revision);
    });
    _stopping = operation.whenComplete(() => _stopping = null);
    return _stopping!;
  }

  Future<void> _return(CastHandoff? result, int revision) async {
    phase = CastPhase.returning;
    _notify();
    try {
      if (_pausedLocal && result != null) await returnLocal(result);
    } catch (_) {
      error = '投屏已结束，手机续播未成功；可重试播放';
    } finally {
      if (!_closed && revision == _revision) {
        source = null;
        _pausedLocal = false;
        _stopRequested = false;
        phase = CastPhase.idle;
        _notify();
      }
    }
  }

  Future<void> _release() async {
    final receiver = _receiver, relay = _relay;
    _receiver = null;
    _relay = null;
    await Future.wait([
      if (receiver != null) receiver.close().catchError((Object _) {}),
      if (relay != null) relay.close().catchError((Object _) {}),
    ]);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _timer?.cancel();
    if (foreground) {
      _beginPolling();
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _revision++;
    _timer?.cancel();
    final receiver = _receiver;
    // Invalidate first and close local resources promptly. Late connect/load
    // results are ignored; receivers also close their own pending requests.
    if (receiver != null) {
      unawaited(
        receiver
            .stop()
            .timeout(const Duration(seconds: 20))
            .catchError((Object _) {}),
      );
    }
    unawaited(_release());
    super.dispose();
  }
}
