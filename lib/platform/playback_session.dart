import 'dart:async';

import '../domain/models.dart';
import '../domain/playback_diagnostic.dart';
import 'episode_buffer.dart';
import 'media_preparer.dart';
import 'playback_failure.dart';
import 'provider_client.dart';

/// A session-owned result. Its media and temporary files leave together.
class PreparedEpisode {
  PreparedEpisode._(
    this.preparer,
    this.media,
    this._path,
    this.timing,
    this._cancellation,
    this._created, {
    bool deferred = false,
  }) : _deferred = deferred;

  final MediaPreparer preparer;
  final ResolvedMedia? media;
  final PreparationTiming timing;
  final EpisodeCancellation _cancellation;
  final DateTime _created;
  String _path;
  bool _deferred;
  Future<void>? _preparing;
  String get path => _path;
}

/// Owns episode preparation, native session cleanup and source handoff order.
/// UI/native events stay with the player; they invalidate tickets on changes.
class PlaybackSessionController {
  static int _requestSerial = 0;
  PlaybackSessionController({
    required ProviderClient provider,
    required this.drama,
    required List<Episode> episodes,
    required this.localFile,
    required this.canResolve,
    required this.progressive,
    required this.completePrefetch,
    required this.onPhase,
    MediaPreparer Function()? preparerFactory,
    DateTime Function()? now,
  }) : _provider = provider,
       episodes = List.unmodifiable(episodes),
       _preparerFactory = preparerFactory ?? MediaPreparer.new,
       _now = now ?? DateTime.now {
    _buffer = EpisodeBuffer(
      load: _load,
      release: _release,
      isReusable: (item) =>
          !item.path.startsWith('http') ||
          (_now().difference(item._created) < const Duration(minutes: 2) &&
              (item.media?.freshAt(_now()) ?? true)),
    );
  }

  final ProviderClient _provider;
  final Drama drama;
  final List<Episode> episodes;
  final Future<String?> Function(int) localFile;
  final bool Function() canResolve;
  final bool Function(int) progressive;
  final bool Function() completePrefetch;
  final void Function(int, String) onPhase;
  final MediaPreparer Function() _preparerFactory;
  final DateTime Function() _now;
  late final EpisodeBuffer<PreparedEpisode> _buffer;
  final Map<int, int> _qualities = {};
  final Map<int, ResolvedMedia> _resolved = {};
  final Set<int> _forceComplete = {}, _compatibilityFallback = {};
  final Map<int, PreparationTiming> _timings = {};
  final Set<EpisodeCancellation> _resolving = {};
  Future<void> _sourceSetup = Future.value();
  void Function()? _interruptSource;
  bool _closed = false;
  int _generation = 0;
  int get generation => _generation;
  int invalidate() {
    ++_generation;
    _interruptSource?.call();
    return _generation;
  }

  bool isCurrent(int ticket) => !_closed && ticket == _generation;

  PreparedEpisode? peek(int index) => _buffer.peek(index);
  bool contains(int index) => _buffer.contains(index);
  PreparationTiming? timing(int index) => _timings[index];

  // Exit may still be draining a remote/native player. Stop provider IO now,
  // keeping already prepared media alive until that player's teardown ends.
  void cancelPendingResolutions() {
    for (final cancellation in _resolving.toList()) {
      cancellation.cancel();
    }
  }

  Future<PreparedEpisode> prefetch(
    int index, {
    Duration timeout = const Duration(minutes: 1),
  }) => _buffer.prepare(index, backgroundTimeout: timeout);

  Future<PreparedEpisode> prepare(int index, {required int ticket}) async {
    if (!isCurrent(ticket)) throw EpisodeCancelled();
    final item = await _buffer.prepare(index);
    if (!isCurrent(ticket)) throw EpisodeCancelled();
    await _prepareSelected(item, index);
    if (!isCurrent(ticket)) throw EpisodeCancelled();
    return item;
  }

  void requireComplete(int index, {bool compatibilityFallback = false}) {
    _forceComplete.add(index);
    if (compatibilityFallback) _compatibilityFallback.add(index);
  }

  void retry(int index, {int? quality, ResolvedMedia? resolved}) {
    if (_closed) {
      unawaited(releaseUnused(resolved));
      return;
    }
    if (quality != null) _qualities[index] = quality;
    _buffer.evict(index);
    final previous = _resolved.remove(index);
    if (previous != null && !identical(previous, resolved)) {
      unawaited(releaseUnused(previous));
    }
    if (resolved != null) _resolved[index] = resolved;
  }

  void evict(int index) => _buffer.evict(index);
  void retain(Set<int> indices) {
    _buffer.retain(indices);
    _timings.removeWhere((index, _) => !indices.contains(index));
    for (final index in _resolved.keys.toList()) {
      if (!indices.contains(index)) {
        unawaited(releaseUnused(_resolved.remove(index)));
      }
    }
  }

  /// A failed setup does not poison later setups; stale queued work is skipped.
  Future<bool> installSource(
    int ticket,
    Future<void> Function() install, {
    void Function()? abandon,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final operation = _sourceSetup.then((_) async {
      if (!isCurrent(ticket)) return false;
      if (abandon == null) {
        await install();
      } else {
        final interrupted = Completer<void>();
        void interrupt() {
          if (!interrupted.isCompleted) {
            interrupted.completeError(EpisodeCancelled());
          }
        }

        _interruptSource = interrupt;
        final timer = Timer(timeout, () {
          if (!interrupted.isCompleted) {
            interrupted.completeError(const ProviderException('播放器初始化超时，请重试'));
          }
        });
        try {
          // Retiring the native controller isolates any later callback. Merely
          // timing out a shared controller would let it initialize a new source.
          await Future.any([Future.sync(install), interrupted.future]);
        } catch (_) {
          if (interrupted.isCompleted) abandon();
          rethrow;
        } finally {
          timer.cancel();
          if (identical(_interruptSource, interrupt)) _interruptSource = null;
        }
      }
      return isCurrent(ticket);
    });
    _sourceSetup = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Teardown must wait for an already submitted native source replacement.
  Future<void> drainSources() => _sourceSetup;

  Future<PreparedEpisode> _load(
    int index,
    EpisodeCancellation cancellation,
  ) async {
    final timing = PreparationTiming();
    _timings[index] = timing;
    final stage = Stopwatch();
    var stageName = 'local';
    final preparer = _preparerFactory();
    ResolvedMedia? media = _resolved.remove(index);
    String? resolving;
    void cancelPrefetch() =>
        unawaited(_provider.cancelPrefetch(media).catchError((Object _) {}));
    cancellation.onForeground = cancelPrefetch;
    cancellation.onCancel = () {
      final request = resolving;
      if (request != null) {
        unawaited(
          _provider
              .cancelResolve(drama, episodes[index], request)
              .catchError((Object _) {}),
        );
      }
      cancelPrefetch();
      unawaited(preparer.cancel().catchError((Object _) {}));
    };
    try {
      cancellation.check();
      var path = await localFile(index);
      cancellation.check();
      timing.local = path != null;
      if (path == null) {
        if (!canResolve()) {
          throw const LocalEpisodeUnavailable();
        }
        stageName = 'resolve';
        _phase(index, '正在获取播放资源…');
        stage.start();
        if (media == null) {
          resolving =
              'resolve-${DateTime.now().microsecondsSinceEpoch}-${++_requestSerial}';
          _resolving.add(cancellation);
          try {
            media = await _provider.resolve(
              drama,
              episodes[index],
              quality: _qualities[index] ?? 0,
              requestId: resolving,
              // Background preparation already passed the user's network policy.
              // This batches small model metadata, without preparing more media.
              metadataAhead:
                  cancellation.background && drama.source == DramaSource.hongguo
                  ? 2
                  : 0,
            );
          } finally {
            _resolving.remove(cancellation);
            resolving = null;
          }
        }
        timing.resolveMs = stage.elapsedMilliseconds;
        stage.reset();
        stageName = 'prepare';
        cancellation.check();
        if (cancellation.background) {
          stageName = 'prefetch';
          media = await _provider.prefetch(media);
          cancellation.check();
          timing.prefetchBytes = media.prefetchedBytes;
          timing.prefetchMs = media.prefetchMs;
          if (media.contentKey.isEmpty ||
              !(_forceComplete.contains(index) || completePrefetch())) {
            return PreparedEpisode._(
              preparer,
              media,
              media.url,
              timing,
              cancellation,
              _now(),
              deferred: true,
            );
          }
          // Complete playback must finish decryption before the next selection.
          // Selection shares this job and only removes its background deadline.
          stage.reset();
          stageName = 'prepare';
        }
        _phase(
          index,
          media.contentKey.isEmpty ? '正在连接视频…' : '正在准备视频，首次播放可能稍久…',
        );
        cancellation.check();
        path = await preparer.prepare(
          media,
          progressive: !cancellation.background && _progressive(index),
        );
        _prepared(timing, preparer, media, index);
        timing.prepareMs = stage.elapsedMilliseconds;
        cancellation.check();
      }
      if (timing.local && media != null) {
        await releaseUnused(media);
        media = null;
      }
      return PreparedEpisode._(
        preparer,
        media,
        path,
        timing,
        cancellation,
        _now(),
      );
    } catch (_) {
      switch (stageName) {
        case 'resolve':
          timing.resolveMs = stage.elapsedMilliseconds;
        case 'prepare':
          timing.prepareMs = stage.elapsedMilliseconds;
        case 'prefetch':
          timing.prefetchMs = stage.elapsedMilliseconds;
      }
      try {
        await preparer.dispose();
      } catch (_) {
        // Failed cancellation retains files until native writes stop.
      } finally {
        await releaseUnused(media);
      }
      rethrow;
    }
  }

  bool _progressive(int index) =>
      !_forceComplete.contains(index) && progressive(index);
  void _phase(int index, String label) {
    if (!_closed) onPhase(index, label);
  }

  void _prepared(
    PreparationTiming timing,
    MediaPreparer preparer,
    ResolvedMedia media,
    int index,
  ) {
    timing.preparation = preparer.streaming
        ? 'progressive'
        : media.contentKey.isEmpty
        ? 'direct'
        : 'complete';
    timing.compatibilityFallback =
        preparer.fellBack || _compatibilityFallback.contains(index);
  }

  Future<void> _prepareSelected(PreparedEpisode item, int index) =>
      item._preparing ??= () async {
        item._cancellation.check();
        if (!item._deferred) return;
        final media = item.media!;
        _phase(
          index,
          media.contentKey.isEmpty ? '正在连接视频…' : '正在准备视频，首次播放可能稍久…',
        );
        final stage = Stopwatch()..start();
        try {
          item._path = await item.preparer.prepare(
            media,
            progressive: _progressive(index),
          );
          item._cancellation.check();
          item._deferred = false;
          _prepared(item.timing, item.preparer, media, index);
        } catch (_) {
          if (identical(_buffer.peek(index), item)) _buffer.evict(index);
          rethrow;
        } finally {
          item.timing.prepareMs = stage.elapsedMilliseconds;
        }
      }();

  Future<void> releaseUnused(ResolvedMedia? media) async {
    try {
      await _provider.release(media);
    } catch (_) {
      /* Best-effort cleanup. */
    }
  }

  Future<void> _release(PreparedEpisode item) async {
    try {
      await item.preparer.dispose();
    } catch (_) {
      // Failed cancellation must retain files until native writes stop.
    } finally {
      await releaseUnused(item.media);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    invalidate();
    _buffer.close();
    for (final media in _resolved.values) {
      unawaited(releaseUnused(media));
    }
    _resolved.clear();
    _timings.clear();
  }
}
