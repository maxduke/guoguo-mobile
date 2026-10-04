import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cast_session.dart';

/// Owns receiver-readable media, separately from the system's selected route.
/// Replacing an episode never ends the AirPlay connection. A relay is released
/// only after AVPlayer has replaced or detached the item that consumes it.
class AirPlaySession extends ChangeNotifier {
  AirPlaySession({
    required this.relayFactory,
    this.channel = const MethodChannel('guoguo/airplay'),
    this.connectionTimeout = const Duration(seconds: 15),
    this.playerId,
  }) {
    final listeners = _listeners.putIfAbsent(_channelKey, () => {});
    listeners.add(this);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'externalPlaybackChanged') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        for (final session in listeners.toList()) {
          if (!session._closed && args['textureId'] == session.textureId) {
            session._setState(args);
          }
        }
      }
    });
  }

  // Navigator can dispose an exiting page after the next page has subscribed.
  // MethodChannel has only one handler, so subscriptions share its ownership.
  static final _listeners = <(String, BinaryMessenger), Set<AirPlaySession>>{};
  (String, BinaryMessenger) get _channelKey =>
      (channel.name, channel.binaryMessenger);

  final CastRelayHandle Function() relayFactory;
  final MethodChannel channel;
  final Duration connectionTimeout;
  final int? Function()? playerId;
  int? _textureId;
  int? get textureId => playerId?.call() ?? _textureId;
  set textureId(int? id) => _textureId = id;
  bool active = false, routed = false, preparing = false;
  String? error;
  bool _closed = false, _prepared = false, _expectVideo = false;
  bool previouslyRouted = false;
  int _revision = 0, _sourceRevision = -1;
  Object? _sourceKey, _openingKey;
  String? _url;
  final _relays = <CastRelayHandle>{};
  Future<void> _pending = Future.value();
  Future<void>? _opening, _closing;
  Timer? _connectionTimer;

  bool get hasSource => _prepared && _url != null;
  bool get hasRelay => _relays.isNotEmpty;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _setState(Map<String, dynamic> state) {
    final wasActive = active, wasRouted = routed;
    final previousError = error;
    final revision = state['sourceRevision'] as int?;
    if (revision != null && revision < _sourceRevision) return;
    if (revision != null) _sourceRevision = revision;
    // Audio routing belongs to iOS and survives individual players. It must be
    // read even before installing a source, otherwise audio alone goes to TV.
    active = hasSource && state['sourceUrl'] == _url && state['active'] == true;
    routed = state['routed'] == true || active;
    if (routed) previouslyRouted = true;
    if (active) error = null;
    _watchConnection();
    if (active != wasActive || routed != wasRouted || error != previousError) {
      _notify();
    }
  }

  Future<void> refreshRoute() async {
    if (_closed) return;
    final revision = _revision;
    final state = await channel.invokeMapMethod<String, dynamic>(
      'getAirPlayState',
      {if (textureId != null) 'textureId': textureId},
    );
    if (!_closed && revision == _revision && state != null) _setState(state);
  }

  void expectVideo(bool playing) {
    _expectVideo = playing;
    _watchConnection();
  }

  void _watchConnection() {
    if (_closed ||
        preparing ||
        !_expectVideo ||
        !routed ||
        active ||
        !hasSource) {
      _connectionTimer?.cancel();
      _connectionTimer = null;
      return;
    }
    if (error != null || _connectionTimer != null) return;
    _connectionTimer = Timer(connectionTimeout, () {
      _connectionTimer = null;
      if (!_closed && routed && !active && _expectVideo && !preparing) {
        error = '电视未接通 AirPlay 视频，请重新选择设备或切回 iPhone';
        _notify();
      }
    });
  }

  Future<void> _queue(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _check(int revision) {
    if (_closed || revision != _revision) throw const CastCancelled();
  }

  /// Invalidate in-flight preparation without tearing down an active receiver.
  void cancelPreparation() {
    _revision++;
    preparing = false;
    _openingKey = null;
    _connectionTimer?.cancel();
    _connectionTimer = null;
  }

  Future<void> open({
    required Object sourceKey,
    required CastSource source,
    required Future<bool> Function(String) install,
    bool showPicker = true,
  }) {
    if (_closed) return Future.error(const CastCancelled());
    if (preparing && identical(_openingKey, sourceKey)) return _opening!;
    final revision = ++_revision;
    _openingKey = sourceKey;
    preparing = true;
    error = null;
    _watchConnection();
    _notify();
    return _opening = _queue(() async {
      CastRelayHandle? started;
      var installationStarted = false;
      var nativePrepared = false;
      try {
        _check(revision);
        if (!identical(_sourceKey, sourceKey) || _url == null) {
          started = relayFactory();
          _relays.add(started);
          final url = await started
              .start(source.media, source.localPath)
              .timeout(const Duration(seconds: 8));
          _check(revision);
          installationStarted = true;
          _url = url;
          _sourceKey = null;
          _prepared = false;
          active = false;
          if (!await install(url)) throw const CastCancelled();
          _check(revision);
          _sourceKey = sourceKey;
          _prepared = true;
        }
        if (textureId == null) throw StateError('AirPlay player is not ready');
        final args = {'textureId': textureId};
        final state = await channel.invokeMapMethod<String, dynamic>(
          'prepareAirPlay',
          args,
        );
        _check(revision);
        nativePrepared = true;
        if (state != null) _setState(state);
        // Native installation has completed: the old item no longer reads its
        // relay. Even cancelled installations retain their relay until here.
        for (final relay in _relays.toList()) {
          if (!identical(relay, started) && started != null) {
            await relay.close();
            _relays.remove(relay);
          }
        }
        _check(revision);
        if (showPicker) {
          await channel.invokeMethod<void>('showAirPlayRoutes', args);
        }
      } catch (failure) {
        if (failure is! CastCancelled && !nativePrepared && routed) {
          error = 'AirPlay 视频准备失败，请重新选择设备或切回 iPhone';
        }
        if (started != null && !installationStarted) {
          await started.close();
          _relays.remove(started);
        }
        rethrow;
      } finally {
        if (revision == _revision) {
          preparing = false;
          _openingKey = null;
          _watchConnection();
          _notify();
        }
      }
    });
  }

  /// Stop/detach native media before closing any receiver URL. This does not
  /// claim to change the system audio route; users select iPhone in the picker.
  Future<void> release({Future<void>? after}) {
    cancelPreparation();
    preparing = false;
    _prepared = false;
    active = false;
    _expectVideo = false;
    previouslyRouted = false;
    error = null;
    _notify();
    return _queue(() async {
      await after;
      if (textureId != null) {
        await channel.invokeMethod<void>('releaseAirPlay', {
          'textureId': textureId,
        });
      }
      for (final relay in _relays.toList()) {
        await relay.close();
        _relays.remove(relay);
      }
      _sourceKey = null;
      _url = null;
    });
  }

  Future<void> close({Future<void>? after}) =>
      _closing ??= release(after: after);

  @override
  void dispose() {
    _closed = true;
    final listeners = _listeners[_channelKey];
    listeners?.remove(this);
    if (listeners?.isEmpty == true) {
      _listeners.remove(_channelKey);
      channel.setMethodCallHandler(null);
    }
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}
