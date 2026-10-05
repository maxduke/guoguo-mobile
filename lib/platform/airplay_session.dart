import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cast_session.dart';
import 'provider_client.dart';

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
  final _pendingSources = <int>{};
  final _closingSources = <CastRelayHandle, int>{};
  final _closingRelays = <Future<void>>{};
  Set<int> _nativeRetained = {};
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
    } else if (!_failedNext.contains('$index')) {
      error = null;
    }
    if (state['retainedItemIds'] case final List ids) {
      _nativeRetained = ids
          .map((id) => int.tryParse('$id'))
          .whereType<int>()
          .toSet();
    }
    if (state['rejectedItemId'] ?? state['failedItemId']
        case final String failed) {
      final failedIndex = int.tryParse(failed);
      if (failedIndex == _queuedIndex &&
          !_nativeRetained.contains(failedIndex)) {
        _queuedIndex = null;
        _failedNext.add('$index');
      }
    }
    if (state['closed'] == true) {
      engaged = preparing = active = false;
      _notify();
      return;
    }
    _notify();
    if (!engaged) return;
    final revision = _revision;
    // currentItem KVO is not proof that the receiver finished the old URL.
    // Native explicitly retains the outgoing item through the handoff.
    unawaited(_releaseUnused(revision));
    if (state['needsNext'] == true && autoAdvance()) {
      unawaited(_append('$index'));
    }
  }

  void _retain() => retainSources({
    ..._relays.keys,
    ..._nativeRetained,
    ..._pendingSources,
    ..._closingSources.values,
    index,
    ?_queuedIndex,
  });

  Future<void> _releaseUnused(int revision) async {
    for (final previous in _relays.keys.toList()) {
      if (revision != _revision || !engaged) return;
      if (_nativeRetained.contains(previous) ||
          _pendingSources.contains(previous)) {
        continue;
      }
      final lease = _relays.remove(previous);
      if (lease != null) await _closeLease(previous, lease);
    }
    if (revision == _revision && engaged) _retain();
  }

  Future<void> _closeLease(int index, CastRelayHandle relay) async {
    _closingSources[relay] = index;
    final task = relay.close();
    _closingRelays.add(task);
    try {
      await task;
    } finally {
      _closingRelays.remove(task);
      _closingSources.remove(relay);
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
    _pendingSources.clear();
    _nativeRetained = {initialIndex};
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
    var stage = 'source.prepare';
    try {
      final source = await loadSource(index);
      _check(revision);
      stage = 'relay.start';
      lease = relayFactory();
      final url = await lease
          .start(source.media, source.localPath)
          .timeout(const Duration(seconds: 8));
      _check(revision);
      _relays[index] = lease;
      stage = 'player.open';
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
        error = _failure('AirPlay 播放准备失败', stage, failure);
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
      var stage = 'source.prepare';
      var accepted = false;
      try {
        // Retain a pending preparation even while native sends progress events.
        _queuedIndex = next;
        _pendingSources.add(next);
        _retain();
        final source = await loadSource(next);
        _check(revision);
        stage = 'relay.start';
        lease = relayFactory();
        final url = await lease
            .start(source.media, source.localPath)
            .timeout(const Duration(seconds: 8));
        _check(revision);
        _relays[next] = lease;
        stage = 'queue.append';
        await _command(() async {
          _check(revision);
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
          accepted = true;
        });
        _check(revision);
        // An asynchronous queued-item rejection can arrive before the method
        // response. Do not resurrect its lease/clear its retry state afterward.
        if (_queuedIndex == next || index == next) {
          _nativeRetained.add(next);
          if (_failedNext.remove(afterId)) error = null;
        }
      } catch (failure) {
        if (!accepted) {
          if (lease != null && identical(_relays[next], lease)) {
            _relays.remove(next);
          }
          await lease?.close();
        }
        if (revision == _revision && engaged) {
          _queuedIndex = null;
          _failedNext.add(afterId);
          error = _failure('下一集准备失败', stage, failure);
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
        if (revision == _revision) {
          _pendingSources.remove(next);
          // A successful append emits the authoritative retained set before
          // completing. A rejected append never owns the submitted URL.
          if (engaged) {
            await _releaseUnused(revision);
          }
        }
        if (identical(_appending[afterId], operation)) {
          _appending.remove(afterId);
        }
      }
    }();
    _appending[afterId] = operation;
    return operation;
  }

  // Error codes are a closed vocabulary: never expose URL/key-bearing native
  // messages or arbitrary exception text in the UI.
  String _failure(String label, String stage, Object failure) {
    final code = failure is TimeoutException
        ? 'timeout'
        : failure is ProviderException
        ? _sourceFailureCode(failure.message)
        : failure is PlatformException &&
              const {
                'airplay_stale',
                'airplay_queue_full',
                'airplay_queue',
                'airplay_session',
                'airplay_unavailable',
                'airplay_audio',
                'airplay_player_failed',
              }.contains(failure.code)
        ? failure.code
        : 'failed';
    final action = code == 'airplay_player_failed'
        ? '请先点原生播放器中的重试本集'
        : code == 'storage_full'
        ? '请清理手机存储空间后重试'
        : stage == 'source.prepare'
        ? '请重试以重新获取并准备视频'
        : stage == 'relay.start'
        ? '请确认手机与电视在同一局域网后重试'
        : '请点击下一集重试；若仍失败请重新打开投放';
    return '$label（$stage/$code）。$action';
  }

  String _sourceFailureCode(String message) {
    if (message.contains('存储空间不足')) return 'storage_full';
    if (message.contains('链接已失效')) return 'source_expired';
    if (message.contains('视频处理组件不兼容')) return 'remux_component';
    if (message.contains('视频处理失败')) return 'remux_failed';
    if (message.contains('准备超时')) return 'timeout';
    if (message.contains('已取消')) return 'cancelled';
    if (message.contains('本地视频不可读取')) return 'file_missing';
    return 'source_failed';
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
    await Future.wait(_closingRelays.toList());
    _queuedIndex = null;
    _nativeRetained.clear();
    _pendingSources.clear();
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
