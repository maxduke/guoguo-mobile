import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cast_session.dart';

/// Media leases for a dedicated native queue, independent of the phone player.
/// Only native item changes advance the episode; Flutter never drives its end.
class AirPlaySession extends ChangeNotifier {
  AirPlaySession({
    required this.loadSource,
    required this.retainSources,
    required this.episodeCount,
    required this.autoAdvance,
    required this.relayFactory,
    this.channel = const MethodChannel('guoguo/airplay'),
  }) {
    final listeners = _listeners.putIfAbsent(_channelKey, () => {});
    listeners.add(this);
    channel.setMethodCallHandler((call) async {
      if (call.method != 'state' && call.method != 'requestNext') return;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      for (final session in listeners.toList()) {
        if (session._disposed) continue;
        if (call.method == 'state') {
          session._state(args);
        } else if (args['sessionId'] == session._id && session.engaged) {
          unawaited(session._append('${args['afterId']}', forced: true));
        }
      }
    });
  }

  static final _listeners = <(String, BinaryMessenger), Set<AirPlaySession>>{};
  static int _identities = 0;
  (String, BinaryMessenger) get _channelKey =>
      (channel.name, channel.binaryMessenger);
  final Future<CastSource> Function(int) loadSource;
  final void Function(Set<int>) retainSources;
  final int episodeCount;
  final bool Function() autoAdvance;
  final CastRelayHandle Function() relayFactory;
  final MethodChannel channel;
  final _relays = <int, CastRelayHandle>{};
  final _appending = <String, Future<void>>{};
  final _failedNext = <String>{};
  Future<void> _native = Future.value();
  Future<void>? _releasing;
  String? _id;
  int _revision = 0, _sequence = -1;
  int index = 0;
  int? _queuedIndex;
  Duration position = Duration.zero, duration = Duration.zero;
  bool engaged = false, preparing = false, routed = false, active = false;
  bool playing = false, ended = false;
  bool _disposed = false;
  String? error;

  bool get blocksLocal => engaged || routed || preparing;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _command(Future<void> Function() command) {
    final next = _native.then((_) => command());
    _native = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _check(int revision) {
    if (_disposed || revision != _revision || !engaged) {
      throw const CastCancelled();
    }
  }

  Future<void> refreshRoute() async {
    final state = await channel.invokeMapMethod<String, dynamic>('getState');
    if (!_disposed && state != null) {
      final route = state['routed'] == true;
      if (routed != route) {
        routed = route;
        _notify();
      }
    }
  }

  Future<void> showRoutes() => channel.invokeMethod<void>('showRoutes');

  void _state(Map<String, dynamic> state) {
    final id = state['sessionId'];
    if (id == null || id == '') {
      final route = state['routed'] == true;
      if (routed != route) {
        routed = route;
        _notify();
      }
      return;
    }
    if (id != _id) return;
    final sequence = state['sequence'] as int? ?? 0;
    if (sequence <= _sequence) return;
    _sequence = sequence;
    final selected = int.tryParse('${state['itemId']}');
    if (selected != null && selected >= 0 && selected < episodeCount) {
      index = selected;
      if (_queuedIndex == index) _queuedIndex = null;
    }
    position = Duration(milliseconds: state['positionMs'] as int? ?? 0);
    duration = Duration(milliseconds: state['durationMs'] as int? ?? 0);
    playing = state['playing'] == true;
    active = state['active'] == true;
    routed = state['routed'] == true;
    ended = state['ended'] == true;
    if (state['error'] case final String failure when failure.isNotEmpty) {
      error = failure;
    }
    if (state['closed'] == true) {
      engaged = preparing = active = false;
      _notify();
      return;
    }
    _notify();
    if (!engaged) return;
    final revision = _revision;
    // Native has removed the preceding item before reporting the next one.
    unawaited(_releaseBefore(index, revision));
    if (state['needsNext'] == true && autoAdvance()) {
      unawaited(_append('$index'));
    }
  }

  Future<void> _releaseBefore(int current, int revision) async {
    for (final previous in _relays.keys.toList()) {
      if (previous >= current || revision != _revision) continue;
      final lease = _relays.remove(previous);
      await lease?.close();
    }
    if (revision == _revision && engaged && current == index) {
      retainSources({current, ?_queuedIndex});
    }
  }

  Future<void> start({
    required int initialIndex,
    required Duration initialPosition,
    required bool initialPlaying,
    required double speed,
  }) async {
    await _releasing;
    if (_disposed || engaged) throw const CastCancelled();
    if (initialIndex < 0 || initialIndex >= episodeCount) {
      throw RangeError.index(initialIndex, List.filled(episodeCount, null));
    }
    final revision = ++_revision;
    _id = '${DateTime.now().microsecondsSinceEpoch}-${++_identities}';
    _sequence = -1;
    _failedNext.clear();
    _appending.clear();
    index = initialIndex;
    position = initialPosition;
    duration = Duration.zero;
    playing = initialPlaying;
    ended = false;
    error = null;
    engaged = preparing = true;
    _notify();
    CastRelayHandle? lease;
    var submitted = false;
    try {
      final source = await loadSource(index);
      _check(revision);
      lease = relayFactory();
      final url = await lease
          .start(source.media, source.localPath)
          .timeout(const Duration(seconds: 8));
      _check(revision);
      _relays[index] = lease;
      await _command(() async {
        _check(revision);
        submitted = true;
        await channel.invokeMethod<void>('open', {
          'sessionId': _id,
          'item': {
            'id': '$initialIndex',
            'url': url,
            'title': source.title,
            'hasNext': initialIndex + 1 < episodeCount,
          },
          'positionMs': initialPosition.inMilliseconds,
          'playing': initialPlaying,
          'speed': speed,
        });
      });
      _check(revision);
      preparing = false;
      _notify();
      // Prepare now, rather than waiting until the receiver reaches the end.
      if (autoAdvance()) unawaited(_append('$initialIndex'));
    } catch (failure) {
      if (!submitted) {
        if (lease != null && identical(_relays[initialIndex], lease)) {
          _relays.remove(initialIndex);
        }
        await lease?.close();
      }
      if (revision == _revision) {
        error = 'AirPlay 播放准备失败，请重试';
        await release();
      }
      rethrow;
    }
  }

  Future<void> _append(String afterId, {bool forced = false}) {
    if (_appending[afterId] case final pending?) return pending;
    final predecessor = int.tryParse(afterId);
    if (!engaged ||
        predecessor != index ||
        index + 1 >= episodeCount ||
        _queuedIndex != null ||
        (!forced && (!autoAdvance() || _failedNext.contains(afterId)))) {
      return Future.value();
    }
    final revision = _revision;
    final next = index + 1;
    late final Future<void> operation;
    operation = () async {
      CastRelayHandle? lease;
      var submitted = false;
      try {
        // Retain a pending preparation even while native sends progress events.
        _queuedIndex = next;
        retainSources({index, next});
        final source = await loadSource(next);
        _check(revision);
        lease = relayFactory();
        final url = await lease
            .start(source.media, source.localPath)
            .timeout(const Duration(seconds: 8));
        _check(revision);
        _relays[next] = lease;
        await _command(() async {
          _check(revision);
          submitted = true;
          await channel.invokeMethod<void>('append', {
            'sessionId': _id,
            'afterId': afterId,
            'item': {
              'id': '$next',
              'url': url,
              'title': source.title,
              'hasNext': next + 1 < episodeCount,
            },
          });
        });
      } catch (failure) {
        if (!submitted) {
          if (lease != null && identical(_relays[next], lease)) {
            _relays.remove(next);
          }
          await lease?.close();
        }
        if (revision == _revision && engaged) {
          _queuedIndex = null;
          _failedNext.add(afterId);
          error = '下一集准备失败，请检查网络后点击下一集重试';
          _notify();
          await _command(() async {
            if (revision != _revision || !engaged) return;
            await channel.invokeMethod<void>('reportError', {
              'sessionId': _id,
              'message': error,
            });
          }).catchError((Object _) {});
        }
      } finally {
        if (identical(_appending[afterId], operation)) {
          _appending.remove(afterId);
        }
      }
    }();
    _appending[afterId] = operation;
    return operation;
  }

  /// Native must detach every consumer before receiver URLs/files are released.
  Future<void> release() => _releasing ??= () async {
    ++_revision;
    preparing = false;
    final id = _id;
    await _command(() async {
      if (id != null) {
        await channel.invokeMethod<void>('close', {'sessionId': id});
      }
    });
    engaged = active = false;
    for (final relay in _relays.values.toList()) {
      await relay.close();
    }
    _relays.clear();
    _queuedIndex = null;
    retainSources({});
    _notify();
  }().whenComplete(() => _releasing = null);

  Future<void> close() => release();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
