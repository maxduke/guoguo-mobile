import 'episode_grid.dart';
import 'throttled_builder.dart';
import 'detail_page.dart';
import '../domain/catalog_query.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:better_player_plus/better_player_plus.dart';
// Native PiP stop is only exposed on this event stream; the public API emits a
// second, synthetic stop when it resets its video value for a new data source.
// ignore: implementation_imports
import 'package:better_player_plus/src/video_player/video_player_platform_interface.dart'
    show VideoEvent, VideoEventType;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:flutter/services.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../domain/playback_diagnostic.dart';
import '../domain/playback_policy.dart';
import '../platform/episode_buffer.dart' show EpisodeCancelled;
import '../platform/playback_session.dart';
import '../platform/playback_recovery.dart';
import '../platform/playback_lifecycle.dart';
import '../platform/media_preparer.dart';
import '../platform/casting.dart';
import '../platform/cast_session.dart';
import '../platform/cast_receivers.dart';
import '../platform/airplay_session.dart';
import 'components.dart';
import 'cast_sheet.dart';
import 'episode_pager.dart';
import 'player_viewport.dart';
import 'player_gestures.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.drama,
    required this.episodes,
    required this.initialIndex,
    this.episodeIndices,
    this.localOnly = false,
    this.preparerFactory,
    this.playbackClock,
    this.castRelayFactory,
    this.castDiscoveryFactory,
    this.airPlayChannel,
  });
  final AppStore store;
  final DownloadStore downloads;
  final Drama drama;
  final List<Episode> episodes;
  final int initialIndex;
  final List<int>? episodeIndices;
  final bool localOnly;
  final MediaPreparer Function()? preparerFactory;
  final DateTime Function()? playbackClock;
  final CastRelayHandle Function()? castRelayFactory;
  final CastDiscovery Function()? castDiscoveryFactory;
  final MethodChannel? airPlayChannel;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final PageController _pages;
  late final PlaybackSessionController _session;
  late final BetterPlayerController _player;
  final GlobalKey _playerKey = GlobalKey();
  late final PlaybackRecoveryController _recovery;
  late final PlaybackLifecycleController _lifecycle;
  late final CastSessionController _casting;
  AirPlaySession? _airplay;
  bool _castOpening = false;
  CastPlaybackState? _lastCastState;
  bool get _remotePlayback =>
      _casting.blocksLocal && _casting.phase != CastPhase.returning;
  PlaybackHealth get _health => _recovery.health;
  bool get _recovering => _recovery.recovering;
  DateTime _prefetchRetryAt = DateTime(2000);
  Timer? _healthTimer;
  PreparedEpisode? _active;
  ValueListenable<ProgressiveTimeline>? _timeline;
  VoidCallback? _timelineListener;
  Future<void> _paused = Future.value();
  bool get _playIntent => _lifecycle.playIntent;
  set _playIntent(bool play) => _lifecycle.setPlayIntent(play);
  StreamSubscription<VideoEvent>? _nativeEvents;
  Timer? _hideTimer, _preloadTimer, _settleTimer;
  StreamSubscription<List<ConnectivityResult>>? _network;
  int _index = 0;
  int get _generation => _session.generation;
  bool _controls = false, _locked = false, _fill = false;
  bool _loading = true;
  bool get _foreground => _lifecycle.foreground;
  bool get _pipActive => _lifecycle.pipActive;
  bool _modal = false, _scrubbing = false;
  double _speed = 1;
  String? _error;
  String _loadingPhase = '正在查找本地视频…';
  PlaybackAttempt? _attempt;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _speed = widget.store.playbackSpeed;
    _pages = PageController(initialPage: _index);
    _session = PlaybackSessionController(
      provider: widget.store.provider,
      drama: widget.drama,
      episodes: widget.episodes,
      localFile: (index) =>
          widget.downloads.localFile(widget.drama, widget.episodes[index]),
      canResolve: () => !widget.localOnly && !widget.store.offline,
      progressive: (index) =>
          widget.store.progressivePreparation &&
          index == _index &&
          _foreground &&
          !_pipActive &&
          _airplay?.routed != true,
      onPhase: _phase,
      preparerFactory: widget.preparerFactory,
    );
    _player = BetterPlayerController(
      BetterPlayerConfiguration(
        autoPlay: false,
        autoDispose: false,
        fit: _fill ? BoxFit.cover : BoxFit.contain,
        allowedScreenSleep: false,
        controlsConfiguration: const BetterPlayerControlsConfiguration(
          showControls: false,
        ),
      ),
    )..setBetterPlayerGlobalKey(_playerKey);
    _recovery = PlaybackRecoveryController(_session, widget.store.provider);
    _lifecycle = PlaybackLifecycleController(
      session: _session,
      snapshot: () => PlaybackLifecycleSnapshot(
        active: _active != null,
        streaming: _active?.preparer.streaming == true,
        loading: _loading,
        position: _player.videoPlayerController?.value.position,
      ),
      save: _save,
      pause: _player.pause,
      play: _player.play,
      cancelProgressive: () async => _active?.preparer.cancel(),
      restoreComplete: (play, position) =>
          _ensureCompatible(play: play, position: position),
      cancelPrefetch: () => _preloadTimer?.cancel(),
      trim: () => _session.retain({_index}),
      schedulePrefetch: _schedulePrefetch,
      syncPage: () {
        if (_pages.hasClients) _pages.jumpToPage(_index);
      },
    );
    _casting = CastSessionController(
      captureSource: _castSource,
      pauseLocal: () async {
        _playIntent = false;
        _preloadTimer?.cancel();
        _hideTimer?.cancel();
        _health.reset();
        await _player.pause();
      },
      returnLocal: _returnFromCast,
      relayFactory: widget.castRelayFactory ?? CastRelay.new,
    )..addListener(_castChanged);
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        widget.airPlayChannel != null) {
      _airplay = AirPlaySession(
        relayFactory: widget.castRelayFactory ?? CastRelay.new,
        channel: widget.airPlayChannel ?? const MethodChannel('guoguo/airplay'),
      )..addListener(_airPlayChanged);
    }
    _player.addEventsListener(_event);
    _healthTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkHealth(),
    );
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_preferencesChanged);
    _network = Connectivity().onConnectivityChanged.listen((states) {
      if (!states.contains(ConnectivityResult.wifi) &&
          !widget.store.cellularPrefetch) {
        _preloadTimer?.cancel();
        _session.retain({_index});
      } else {
        _schedulePrefetch();
      }
    });
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_activate(resume: true));
  }

  void _phase(int index, String label) {
    if (mounted && index == _index && _loading) {
      setState(() => _loadingPhase = label);
    }
  }

  void _finishAttempt(PlaybackResult result) {
    final sample = _attempt?.finish(result);
    if (sample != null) {
      unawaited(widget.store.recordPlayback(sample).catchError((Object _) {}));
    }
  }

  void _detachTimeline() {
    final listener = _timelineListener;
    if (listener != null) _timeline?.removeListener(listener);
    _timeline = null;
    _timelineListener = null;
  }

  void _attachTimeline(PreparedEpisode item, int generation) {
    _detachTimeline();
    final timeline = item.preparer.timeline;
    final controller = _player.videoPlayerController;
    if (!item.preparer.streaming || timeline == null || controller == null) {
      return;
    }
    var completed = timeline.value.complete;
    void synchronize() {
      if (!mounted || generation != _generation || !identical(_active, item)) {
        return;
      }
      final snapshot = timeline.value;
      if (snapshot.complete != completed) {
        completed = snapshot.complete;
        setState(() {});
      }
      if (snapshot.duration <= Duration.zero) return;
      // EVENT HLS initially has an indefinite native duration. BetterPlayer
      // only receives duration at initialization and clamps seeks to that value.
      // Use the published fragment range, never elapsed time or a guessed total.
      controller.value = controller.value.copyWith(duration: snapshot.duration);
    }

    _timeline = timeline;
    _timelineListener = synchronize;
    timeline.addListener(synchronize);
    synchronize();
  }

  void _save() {
    if (_casting.blocksLocal && _casting.source != null) {
      final handoff = _casting.handoff;
      if (handoff != null) _savePosition(handoff.position, handoff.duration);
      return;
    }
    final value = _active == null ? null : _player.videoPlayerController?.value;
    if (value == null ||
        value.duration == null ||
        value.duration == Duration.zero) {
      return;
    }
    _savePosition(
      value.position,
      _active!.preparer.streaming && !_active!.preparer.complete
          ? Duration.zero
          : value.duration!,
    );
  }

  void _savePosition(Duration position, Duration duration) {
    _lastSaved = DateTime.now();
    unawaited(
      widget.store
          .saveWatch(
            WatchRecord(
              drama: widget.drama,
              episodeId: widget.episodes[_index].id,
              episodeIndex: widget.episodeIndices?[_index] ?? _index,
              positionMs: position.inMilliseconds,
              durationMs: duration.inMilliseconds,
              updatedAt: DateTime.now(),
            ),
          )
          .catchError((Object _) {}),
    );
  }

  void _pageChanged(int index) {
    if (_casting.blocksLocal) return;
    if (index == _index) return;
    _recovery.reset();
    _health.reset();
    _prefetchRetryAt = DateTime(2000);
    _finishAttempt(PlaybackResult.cancelled);
    _save();
    _detachTimeline();
    if ((_active ?? _session.peek(_index))?.preparer.streaming == true ||
        (_loading && widget.store.progressivePreparation)) {
      _session.evict(_index);
    }
    _lifecycle.selectionChanged();
    _hideTimer?.cancel();
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    _session.invalidate();
    _paused = _active == null ? Future.value() : _player.pause();
    unawaited(_paused.catchError((Object _) {}));
    setState(() {
      _index = index;
      _active = null;
      _loading = true;
      _loadingPhase = '正在准备这一集…';
      _error = null;
      _controls = false;
    });
    _session.retain({index - 1, index, index + 1});
    if ((_pipActive || _airplay?.routed == true) && !_foreground) {
      unawaited(_activate());
    } else {
      _settleTimer = Timer(
        const Duration(milliseconds: 120),
        () => unawaited(_activate()),
      );
    }
  }

  Future<void> _activate({
    bool resume = false,
    Duration? position,
    bool play = true,
  }) async {
    _lifecycle.beginActivation(play);
    final generation = _session.invalidate();
    final index = _index;
    final record = widget.store.history[widget.drama.key];
    var start =
        position ??
        (resume && record?.episodeId == widget.episodes[index].id
            ? Duration(milliseconds: record!.positionMs)
            : null);
    if (start != null && start > Duration.zero) _session.requireComplete(index);
    final attempt = PlaybackAttempt(
      source: widget.drama.source,
      episode: widget.episodes[index].number,
      preloaded: _session.peek(index) != null,
    );
    _attempt = attempt;
    try {
      final pending = _session.prepare(index, ticket: generation);
      attempt.timing = _session.timing(index) ?? PreparationTiming();
      final item = await pending;
      attempt.timing = item.timing;
      attempt.waitMs = attempt.clock.elapsedMilliseconds;
      if (!mounted || generation != _generation) return;
      await _paused;
      if (!mounted || generation != _generation) return;
      _phase(index, '正在启动播放器…');
      final setup = Stopwatch()..start();
      final source = BetterPlayerDataSource(
        item.path.startsWith('http')
            ? BetterPlayerDataSourceType.network
            : BetterPlayerDataSourceType.file,
        item.path,
        headers: item.preparer.streaming ? const {} : item.media?.headers,
        videoFormat:
            (item.preparer.streaming || item.media?.hls == true) &&
                item.path.startsWith('http')
            ? BetterPlayerVideoFormat.hls
            : null,
        notificationConfiguration: BetterPlayerNotificationConfiguration(
          showNotification: true,
          title: widget.drama.title,
          author: '果果 · 第 ${widget.episodes[index].number} 集',
        ),
      );
      final wasAirPlay = _airplay?.routed == true;
      await _airplay?.reset();
      if (!mounted || generation != _generation) return;
      // Native setDataSource operates on one texture. Serialize rapid swipes so
      // an older request cannot finish after a newer episode starts loading.
      if (wasAirPlay) {
        await _airplay!.open(
          sourceKey: item,
          source: CastSource(
            media:
                item.media ??
                ResolvedMedia.fromJson({
                  'url': Uri.file(item.path).toString(),
                  'remoteUrl': '',
                }),
            localPath: item.path.startsWith('http') ? null : item.path,
            title: widget.drama.title,
            position: start ?? Duration.zero,
            duration: Duration.zero,
            playing: play,
          ),
          install: (url) => _session.installSource(
            generation,
            () => _player.setupDataSource(
              BetterPlayerDataSource(
                BetterPlayerDataSourceType.network,
                url,
                videoFormat:
                    item.path.startsWith('http') && item.media?.hls == true
                    ? BetterPlayerVideoFormat.hls
                    : null,
                notificationConfiguration: source.notificationConfiguration,
              ),
            ),
          ),
          showPicker: false,
        );
      } else if (!await _session.installSource(
        generation,
        () => _player.setupDataSource(source),
      )) {
        return;
      }
      item.timing.setupMs = setup.elapsedMilliseconds;
      if (!mounted || generation != _generation) return;
      _nativeEvents ??= _player
          .videoPlayerController
          ?.videoEventStreamController
          .stream
          .listen(_nativeEvent);
      _active = item;
      // The pinned native AirPlay bridge uses the same player channel identifier.
      // ignore: invalid_use_of_visible_for_testing_member
      _airplay?.textureId = _player.videoPlayerController?.textureId;
      _attachTimeline(item, generation);
      _health.reset();
      await _applyVideoFit();
      // The private EVENT playlist declares its start. Seeking during native
      // initialization can race play because the plugin returns before AVPlayer
      // finishes seeking. Resume/scrub on complete media still uses seekTo.
      if (item.preparer.streaming) start = null;
      final value = _player.videoPlayerController?.value;
      final duration = value?.duration ?? Duration.zero;
      if (!item.preparer.streaming &&
          start == null &&
          duration > Duration.zero &&
          value!.position >= duration - const Duration(milliseconds: 300)) {
        start = Duration.zero;
      }
      if (start != null) await _player.seekTo(start);
      if (!mounted || generation != _generation) return;
      await _player.setSpeed(_speed);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = null;
      });
      if (_lifecycle.deferPlayback()) return;
      attempt.initialPosition = _player.videoPlayerController?.value.position;
      if (_playIntent) {
        await _player.play();
      } else {
        _showControls();
      }
      _schedulePrefetch();
    } catch (error) {
      if (mounted && generation == _generation) {
        _finishAttempt(
          error is EpisodeCancelled
              ? PlaybackResult.cancelled
              : PlaybackResult.failed,
        );
        setState(() {
          _loading = false;
          _error = error is EpisodeCancelled ? '准备已取消，请重试' : '$error';
        });
        if (error is! EpisodeCancelled) unawaited(_recover());
      }
    }
  }

  Future<void> _applyVideoFit() async {
    _player.setOverriddenFit(_fill ? BoxFit.cover : BoxFit.contain);
    // Reusing the player resets VideoPlayerValue on every source change, while
    // the fit widget caches its last gravity. Explicitly restore the native
    // mode even when the requested BoxFit has not changed.
    await _player.videoPlayerController?.setAspectRatio(
      _fill ? 'fill' : 'aspect',
    );
  }

  Future<void> _retry({
    int? quality,
    bool automatic = false,
    ResolvedMedia? resolved,
    bool play = true,
    Duration? savedPosition,
  }) async {
    if (_casting.blocksLocal || _recovering && !automatic) return;
    if (!automatic) _recovery.reset();
    _health.reset();
    _finishAttempt(PlaybackResult.cancelled);
    if (savedPosition == null) _save();
    final position =
        savedPosition ??
        (_active == null
            ? null
            : _player.videoPlayerController?.value.position);
    _paused = _active == null ? Future.value() : _player.pause();
    unawaited(_paused.catchError((Object _) {}));
    _detachTimeline();
    _active = null;
    _session.retry(_index, quality: quality, resolved: resolved);
    setState(() {
      _loading = true;
      _error = null;
    });
    await _activate(resume: position == null, position: position, play: play);
  }

  void _checkHealth() {
    if (!mounted || _casting.blocksLocal) return;
    if (_airplay?.routed == true || _airplay?.preparing == true) {
      _health.reset();
      return;
    }
    if (!_loading && _active?.preparer.failure != null) {
      unawaited(_recover());
      return;
    }
    final value = _player.videoPlayerController?.value;
    final progressive = _active?.preparer.streaming == true;
    final duration = value?.duration ?? Duration.zero;
    final ended =
        _active?.preparer.complete == true &&
        duration > Duration.zero &&
        (value?.position ?? Duration.zero) >= duration;
    final stalled = _health.stalled(
      value?.position ?? Duration.zero,
      widget.playbackClock?.call() ?? DateTime.now(),
      timeout: Duration(seconds: progressive ? 10 : 20),
      watching:
          (_foreground || _pipActive) &&
          !_loading &&
          !_recovering &&
          _error == null &&
          !_scrubbing &&
          !_modal &&
          _active != null &&
          !ended &&
          // AVPlayer can wait at the first frame without reporting playing.
          // Explicit page and native pause commands update the viewer intent.
          (value?.isPlaying == true || progressive && _playIntent),
    );
    if (stalled) unawaited(_recover());
    _schedulePrefetch();
  }

  Future<void> _recover() async {
    if (_casting.blocksLocal ||
        _recovering ||
        !mounted ||
        (!_foreground && !_pipActive) ||
        widget.localOnly ||
        widget.store.offline ||
        _active?.timing.local == true) {
      return;
    }
    if ((_active ?? _session.peek(_index))?.preparer.streaming == true) {
      await _ensureCompatible(play: _playIntent);
      return;
    }
    await _recovery.recover(
      _index,
      pause: () async {
        if (_active != null) await _player.pause();
      },
      onAction: (action) {
        _preloadTimer?.cancel();
        if (action == RecoveryAction.stop) {
          if (_active != null) unawaited(_player.pause());
          setState(() {
            _error = '自动恢复未成功，请重试或切换分集';
            _loading = false;
          });
        } else {
          setState(() {
            _error = null;
            _loading = true;
            _loadingPhase = action == RecoveryAction.alternative
                ? '正在切换备用线路…'
                : '正在重新获取播放资源…';
          });
        }
      },
      restart: (replacement) {
        _finishAttempt(PlaybackResult.failed);
        unawaited(
          _retry(automatic: true, resolved: replacement, play: _playIntent),
        );
      },
      onFailure: () {
        setState(() {
          _error = '自动恢复未成功，请重试或切换分集';
          _loading = false;
        });
      },
    );
  }

  void _event(BetterPlayerEvent event) {
    if (!mounted) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.finished:
        if (_casting.blocksLocal) break;
        if (_loading || _active == null) break;
        if (_active!.preparer.streaming &&
            (!_active!.preparer.complete ||
                _active!.preparer.failure != null)) {
          unawaited(_recover());
          break;
        }
        _save();
        if (!_foreground && !_pipActive && _airplay?.routed != true) break;
        if (widget.store.autoAdvance && _index + 1 < widget.episodes.length) {
          _goTo(_index + 1);
        } else {
          _playIntent = false;
          _health.reset();
          _showControls();
        }
        break;
      case BetterPlayerEventType.progress:
        final value = _player.videoPlayerController?.value;
        final initial = _attempt?.initialPosition;
        if (initial != null &&
            value != null &&
            value.isPlaying &&
            !value.isBuffering &&
            value.position > initial) {
          _finishAttempt(PlaybackResult.started);
        }
        if (DateTime.now().difference(_lastSaved).inSeconds >= 10) _save();
        break;
      case BetterPlayerEventType.exception:
        if (_loading || _recovering || _active == null) break;
        _finishAttempt(PlaybackResult.failed);
        setState(() {
          _error = '视频暂时无法播放，请重试或切换分集';
          _loading = false;
        });
        unawaited(_recover());
        break;
      case BetterPlayerEventType.play:
        if (_remotePlayback) {
          unawaited(_player.pause().catchError((Object _) {}));
          break;
        }
        _armHide();
        _schedulePrefetch();
        break;
      case BetterPlayerEventType.pause:
        _health.reset();
        _preloadTimer?.cancel();
        _hideTimer?.cancel();
        break;
      case BetterPlayerEventType.pipStart:
        _setPipActive(true);
        break;
      case BetterPlayerEventType.pipStop:
        // Changing source clears better_player_plus's Dart isPip flag and
        // produces a synthetic pipStop. The native event stream below reports
        // the actual PiP window closing.
        break;
      default:
        break;
    }
  }

  void _nativeEvent(VideoEvent event) {
    if (!mounted) return;
    switch (event.eventType) {
      case VideoEventType.play:
        if (_remotePlayback) {
          unawaited(_player.pause().catchError((Object _) {}));
          return;
        }
        if (_casting.blocksLocal) return;
        _lifecycle.nativePlaying(true);
      case VideoEventType.pause:
        if (_casting.blocksLocal) return;
        _lifecycle.nativePlaying(false);
      case VideoEventType.pipStart:
        _lifecycle.nativePipStarted();
      case VideoEventType.pipStop:
        _lifecycle.nativePipStopped();
      default:
        break;
    }
  }

  void _setPipActive(bool active) => _lifecycle.setPipActive(active);

  void _preferencesChanged() {
    if (!widget.store.prefetch) {
      _preloadTimer?.cancel();
      _session.retain({_index});
    }
  }

  bool get _prefetchReady {
    if (_active?.preparer.streaming == true && !_active!.preparer.complete) {
      return false;
    }
    final value = _player.videoPlayerController?.value;
    if (value == null) return false;
    var ahead = Duration.zero;
    for (final range in value.buffered) {
      if (range.start <= value.position &&
          range.end > value.position &&
          range.end - value.position > ahead) {
        ahead = range.end - value.position;
      }
    }
    return shouldPrefetch(
      position: value.position,
      duration: value.duration ?? Duration.zero,
      bufferedAhead: ahead,
      playing: value.isPlaying,
      buffering: value.isBuffering,
      local: _active?.timing.local == true,
    );
  }

  void _schedulePrefetch() {
    if (_casting.blocksLocal ||
        _error != null ||
        _recovering ||
        !_prefetchReady ||
        _preloadTimer?.isActive == true ||
        DateTime.now().isBefore(_prefetchRetryAt) ||
        !widget.store.prefetch ||
        (!_foreground && !_pipActive) ||
        _active == null ||
        _loading ||
        _index + 1 >= widget.episodes.length ||
        _session.contains(_index + 1)) {
      return;
    }
    _preloadTimer?.cancel();
    final index = _index;
    final generation = _generation;
    _preloadTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final states = await Connectivity().checkConnectivity();
        if (!mounted ||
            _casting.blocksLocal ||
            _loading ||
            _recovering ||
            !_prefetchReady ||
            index != _index ||
            generation != _generation ||
            _error != null ||
            (!_foreground && !_pipActive) ||
            !widget.store.prefetch ||
            states.contains(ConnectivityResult.none) ||
            (!states.contains(ConnectivityResult.wifi) &&
                !widget.store.cellularPrefetch)) {
          return;
        }
        await _session.prefetch(index + 1);
      } catch (_) {
        if (mounted && index == _index && generation == _generation) {
          _prefetchRetryAt = DateTime.now().add(const Duration(seconds: 30));
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _health.reset();
    _lifecycle.setForeground(state == AppLifecycleState.resumed);
    _casting.setForeground(state == AppLifecycleState.resumed);
  }

  Future<bool> _ensureCompatible({bool? play, Duration? position}) async {
    final item = _active ?? _session.peek(_index);
    if (item == null || _loading && _recovering) return false;
    if (!item.preparer.streaming) return true;
    final generation = _generation;
    final index = _index;
    final intent = _lifecycle.captureIntent(
      play ?? _player.isPlaying() == true,
    );
    final savedPosition =
        position ?? _player.videoPlayerController?.value.position;
    _save();
    _session.requireComplete(_index, compatibilityFallback: true);
    _preloadTimer?.cancel();
    _session.retain({_index});
    setState(() {
      _loading = true;
      _error = null;
      _loadingPhase = '正在准备完整视频，保留播放进度…';
    });
    return _recovery.compatible(generation, () async {
      try {
        await _player.pause();
        await item.preparer.cancel();
        if (!mounted || generation != _generation) return false;
        await _retry(
          automatic: true,
          play: _lifecycle.resumeIntent(intent),
          savedPosition: savedPosition,
        );
        return mounted &&
            _index == index &&
            _generation == generation + 1 &&
            _active != null &&
            !_active!.preparer.streaming &&
            _error == null;
      } catch (_) {
        if (mounted && generation == _generation) {
          setState(() {
            _loading = false;
            _error = '兼容播放准备失败，请重试';
          });
        }
        return false;
      }
    });
  }

  Future<void> _cast() async {
    if (_airplay?.routed == true || _airplay?.preparing == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在 AirPlay 中切回 iPhone，再选择其他投屏方式')),
      );
      return;
    }
    if (_castOpening || _pipActive) return;
    _castOpening = true;
    try {
      if (!_casting.blocksLocal && (!await _ensureCompatible() || !mounted)) {
        return;
      }
      if (!mounted) return;
      _modal = true;
      _hideTimer?.cancel();
      await showCastSheet(
        context,
        _casting,
        discoveryFactory: widget.castDiscoveryFactory,
      );
    } finally {
      _castOpening = false;
      _modal = false;
      if (mounted) _armHide();
    }
  }

  CastSource _castSource() {
    final item = _active;
    final value = _player.videoPlayerController?.value;
    if (item == null ||
        value == null ||
        _loading ||
        _recovering ||
        item.preparer.streaming) {
      throw StateError('视频尚未准备好');
    }
    _save();
    final local = !item.path.startsWith('http');
    return CastSource(
      media:
          item.media ??
          ResolvedMedia.fromJson({
            'url': Uri.file(item.path).toString(),
            'remoteUrl': '',
          }),
      localPath: local ? item.path : null,
      title: '${widget.drama.title} · 第 ${widget.episodes[_index].number} 集',
      position: value.position,
      duration: value.duration ?? Duration.zero,
      playing: value.isPlaying,
    );
  }

  void _castChanged() {
    if (!mounted) return;
    _lifecycle.setExternalPlayback(_remotePlayback);
    if (_casting.blocksLocal) {
      _health.reset();
      _preloadTimer?.cancel();
      _hideTimer?.cancel();
      final state = _casting.latest.state;
      if (_casting.reportedPosition != null &&
          (state != _lastCastState ||
              DateTime.now().difference(_lastSaved).inSeconds >= 10)) {
        _save();
      }
      _lastCastState = state;
    } else {
      _lastCastState = null;
    }
    setState(() => _controls = true);
  }

  Future<void> _returnFromCast(CastHandoff handoff) async {
    if (!mounted || _active == null) return;
    final generation = _generation;
    _savePosition(handoff.position, handoff.duration);
    _lifecycle.setExternalPlayback(false);
    _playIntent = handoff.playing;
    final duration =
        _player.videoPlayerController?.value.duration ?? Duration.zero;
    final position = duration > Duration.zero && handoff.position > duration
        ? duration
        : handoff.position;
    await _player.seekTo(position);
    if (!mounted || generation != _generation) return;
    final ended = duration > Duration.zero && position >= duration;
    if (ended) _playIntent = false;
    if (!_lifecycle.deferPlayback() && _playIntent) await _player.play();
    if (mounted) _showControls();
  }

  Future<void> _prepareAirPlay() async {
    final airplay = _airplay;
    if (airplay == null ||
        _loading ||
        _recovering ||
        _casting.blocksLocal ||
        _pipActive ||
        airplay.preparing) {
      return;
    }
    if (!await _ensureCompatible() || !mounted) return;
    final item = _active;
    if (item == null) return;
    final generation = _generation;
    final source = _castSource();
    final intent = _lifecycle.captureIntent(source.playing);
    try {
      await airplay.open(
        sourceKey: item,
        source: source,
        install: (url) => _session.installSource(generation, () async {
          if (!mounted || !identical(_active, item)) {
            throw const CastCancelled();
          }
          await _player.pause();
          await _player.setupDataSource(
            BetterPlayerDataSource(
              BetterPlayerDataSourceType.network,
              url,
              videoFormat: source.localPath == null && source.media.hls
                  ? BetterPlayerVideoFormat.hls
                  : null,
              notificationConfiguration: BetterPlayerNotificationConfiguration(
                showNotification: true,
                title: widget.drama.title,
                author: '果果 · 第 ${widget.episodes[_index].number} 集',
              ),
            ),
          );
          if (!mounted || generation != _generation) return;
          await _player.seekTo(source.position);
          await _player.setSpeed(_speed);
          await _applyVideoFit();
          if (!mounted || generation != _generation) return;
          _playIntent = _lifecycle.resumeIntent(intent);
          if (_playIntent && !_lifecycle.deferPlayback()) await _player.play();
        }),
      );
    } on CastCancelled {
      // A newer episode or a closed page superseded this request.
    } catch (_) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AirPlay 准备失败，请确认连接同一 Wi-Fi 和本地网络权限后重试'),
          ),
        );
      }
    }
    if (mounted) _showControls();
  }

  void _airPlayChanged() {
    if (!mounted) return;
    _lifecycle.setAirPlayActive(_airplay?.routed == true);
    _health.reset();
    setState(() => _controls = true);
  }

  void _goTo(int index) {
    if (_casting.blocksLocal) return;
    if (index == _index || index < 0 || index >= widget.episodes.length) return;
    if ((_pipActive || _airplay?.routed == true) && !_foreground) {
      // Background playback changes the native media directly; synchronize the
      // visible page when returning to the foreground.
      _pageChanged(index);
      return;
    }
    if ((index - _index).abs() > 1) {
      _pages.jumpToPage(index);
      return;
    }
    unawaited(
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (_casting.blocksLocal ||
        !_controls ||
        _modal ||
        _scrubbing ||
        _active == null ||
        _player.isPlaying() != true) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _showControls() {
    setState(() => _controls = true);
    _armHide();
  }

  void _tap() {
    if (_locked) return;
    setState(() => _controls = !_controls);
    _armHide();
  }

  Future<void> _togglePlay() async {
    if (_active == null || _casting.blocksLocal) return;
    final controller = _player;
    if (controller.isPlaying() == true) {
      _playIntent = false;
      await controller.pause();
    } else {
      _playIntent = true;
      final value = controller.videoPlayerController?.value;
      final duration = value?.duration ?? Duration.zero;
      if (duration > Duration.zero &&
          value!.position >= duration - const Duration(milliseconds: 300)) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
    if (mounted) _showControls();
  }

  Future<void> _enterPictureInPicture(bool wasPlaying) async {
    if (_casting.blocksLocal || _airplay?.routed == true) return;
    if (!await _ensureCompatible(play: wasPlaying) || !mounted) return;
    // AVKit can pause the player while moving its layer into PiP. Capture the
    // viewer's intent before that transition; a deliberately paused episode
    // must remain paused in the window.
    _lifecycle.beginPipEntry(wasPlaying);
    try {
      await _player.enablePictureInPicture(_playerKey);
    } catch (_) {
      _lifecycle.cancelPipEntry();
      rethrow;
    }
  }

  Future<void> _sheet(Widget child) async {
    if (_modal || !mounted) return;
    _modal = true;
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF161A18),
      isScrollControlled: true,
      builder: (_) => Theme(
        data: ThemeData.dark(),
        child: SafeArea(child: child),
      ),
    );
    _modal = false;
    if (mounted) _armHide();
  }

  Future<void> _showEpisodes() => _sheet(
    SizedBox(
      height: math.min(600, MediaQuery.sizeOf(context).height * .85),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              '选集 · 共 ${widget.episodes.length} 集',
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: EpisodeGrid(
                episodes: widget.episodes,
                initialIndex: _index,
                onJump: (index) {
                  Navigator.pop(context);
                  _goTo(index);
                },
                builder: (context, index) => FilledButton.tonal(
                  onPressed: () {
                    Navigator.pop(context);
                    _goTo(index);
                  },
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: index == _index
                        ? const Color(0xFF345D55)
                        : null,
                  ),
                  child: Text(
                    '${widget.episodes[index].number}${widget.episodes[index].vip ? '\nVIP' : ''}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> _showRelated() async {
    final rows = relatedSeries(widget.drama, [
      ...widget.store.catalogs.values.expand((rows) => rows),
      ...widget.store.searchCache.dramas,
      ...widget.store.favorites.values,
      ...widget.store.history.values.map((record) => record.drama),
    ]);
    Drama? selected;
    await _sheet(
      SizedBox(
        height: math.min(500, MediaQuery.sizeOf(context).height * .75),
        child: rows.isEmpty
            ? const Center(child: Text('暂未找到同系列作品'))
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) => ListTile(
                  title: Text(rows[index].title),
                  subtitle: Text(rows[index].source.label),
                  onTap: () {
                    selected = rows[index];
                    Navigator.pop(context);
                  },
                ),
              ),
      ),
    );
    if (selected != null && mounted) {
      await _player.pause();
      if (mounted) {
        await openDrama(context, widget.store, widget.downloads, selected!);
      }
    }
  }

  Future<void> _showMore() async {
    var relatedRequested = false;
    var castRequested = false;
    final item = _active;
    await _sheet(
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('相关剧集'),
              subtitle: const Text('按标题匹配同系列作品'),
              onTap: () {
                relatedRequested = true;
                Navigator.pop(context);
              },
            ),
            StatefulBuilder(
              builder: (context, update) => SwitchListTile(
                title: const Text('自动播放下一集'),
                subtitle: const Text('关闭后，播完停在当前集'),
                value: widget.store.autoAdvance,
                onChanged: (value) async {
                  await perform(
                    context,
                    () => widget.store.setPlayback(advance: value),
                  );
                  if (context.mounted) update(() {});
                },
              ),
            ),
            const ListTile(
              leading: Icon(Icons.touch_app_outlined),
              title: Text('播放手势'),
              subtitle: Text(
                '单击显示或隐藏控件；上下滑动切换分集；左右滑动调节进度。长按 2 倍速，按住后左右滑动可快进快退，松手跳转。',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.fit_screen),
              title: Text(_fill ? '显示完整画面' : '等比例铺满（裁切边缘）'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _fill = !_fill);
                unawaited(_applyVideoFit());
              },
            ),
            ListTile(
              leading: const Icon(Icons.screen_rotation_outlined),
              title: const Text('切换横竖屏'),
              onTap: () {
                Navigator.pop(context);
                unawaited(
                  SystemChrome.setPreferredOrientations(
                    MediaQuery.orientationOf(context) == Orientation.portrait
                        ? [
                            DeviceOrientation.landscapeLeft,
                            DeviceOrientation.landscapeRight,
                          ]
                        : [DeviceOrientation.portraitUp],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_in_picture_alt),
              title: const Text('画中画'),
              enabled: item != null && !_casting.blocksLocal,
              onTap: () {
                final wasPlaying =
                    _player.videoPlayerController?.value.isPlaying == true;
                Navigator.pop(context);
                if (item != null) {
                  perform(context, () => _enterPictureInPicture(wasPlaying));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.cast),
              title: const Text('投屏到电视'),
              enabled: item != null && !_pipActive,
              onTap: () {
                castRequested = true;
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载当前集'),
              onTap: () {
                Navigator.pop(context);
                perform(
                  context,
                  () => widget.downloads.enqueue(
                    widget.drama,
                    widget.episodes[_index],
                    widget.episodeIndices?[_index] ?? _index,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('锁定手势'),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  _locked = true;
                  _controls = false;
                });
              },
            ),
            if ((item?.media?.qualities.length ?? 0) > 1)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final quality in item!.media!.qualities)
                      ChoiceChip(
                        label: Text('${quality}P'),
                        selected: quality == item.media!.quality,
                        onSelected: (_) {
                          Navigator.pop(context);
                          _retry(quality: quality);
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    if (relatedRequested && mounted) await _showRelated();
    if (castRequested && mounted) await _cast();
  }

  Widget _page(BuildContext context, int index) {
    final item = _session.peek(index);
    final selected = index == _index;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!selected || _active == null)
            Opacity(opacity: .25, child: Poster(widget.drama, radius: 0)),
          if (selected && _loading)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    _loadingPhase,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          if (!selected && item == null)
            Center(
              child: Text(
                '第 ${widget.episodes[index].number} 集',
                style: const TextStyle(color: Colors.white, fontSize: 22),
              ),
            ),
          if (selected && _error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!.length > 600
                          ? "${_error!.substring(0, 600)}…"
                          : _error!,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _retry, child: const Text('重试')),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _seek(Duration position) async {
    if (_casting.blocksLocal || _loading || _active == null) return;
    final duration = _player.videoPlayerController?.value.duration;
    if (duration == null || duration <= Duration.zero) return;
    // Seeking beyond an EVENT range can cause BetterPlayer to emit 'finished'.
    final target = Duration(
      microseconds: position.inMicroseconds.clamp(0, duration.inMicroseconds),
    );
    await _player.seekTo(target);
  }

  Widget _transport() {
    final controller = _active == null ? null : _player.videoPlayerController;
    Widget build() {
      final value = controller?.value;
      return PlayerTransport(
        duration: value?.duration?.inMilliseconds.toDouble() ?? 0,
        position: value?.position.inMilliseconds.toDouble() ?? 0,
        playing: value?.isPlaying == true,
        enabled: !_casting.blocksLocal && !_loading && _active != null,
        speed: _speed,
        preparing:
            _active?.preparer.streaming == true && !_active!.preparer.complete,
        onPlay: _togglePlay,
        onEpisodes: _showEpisodes,
        onSpeed: (speed) {
          if (_casting.blocksLocal) return;
          setState(() => _speed = speed);
          unawaited(
            perform(context, () => widget.store.setPlayback(speed: speed)),
          );
          if (_active != null) unawaited(_player.setSpeed(speed));
          _armHide();
        },
        onScrub: (scrubbing) {
          _scrubbing = scrubbing;
          _armHide();
        },
        onSeek: (position) {
          if (_active != null) {
            unawaited(_seek(Duration(milliseconds: position.round())));
          }
          _armHide();
        },
      );
    }

    return controller == null
        ? build()
        : ThrottledValueBuilder(
            listenable: controller,
            active: _controls && !_locked,
            immediate: (previous, current) =>
                previous.isPlaying != current.isPlaying ||
                previous.isBuffering != current.isBuffering ||
                previous.hasError != current.hasError ||
                previous.duration != current.duration ||
                (previous.position - current.position).abs() >
                    const Duration(milliseconds: 1500),
            builder: (_) => build(),
          );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: PlayerViewport(playerKey: _playerKey, controller: _player),
          ),
          Semantics(
            container: true,
            explicitChildNodes: true,
            child: PlayerGestures(
              onTap: _tap,
              enabled:
                  !_casting.blocksLocal &&
                  !_locked &&
                  !_loading &&
                  _active != null,
              position: () =>
                  (_active == null
                      ? null
                      : _player
                            .videoPlayerController
                            ?.value
                            .position
                            .inMilliseconds
                            .toDouble()) ??
                  0,
              duration: () =>
                  (_active == null
                      ? null
                      : _player
                            .videoPlayerController
                            ?.value
                            .duration
                            ?.inMilliseconds
                            .toDouble()) ??
                  0,
              onBoost: (boost) {
                if (_active != null) {
                  unawaited(_player.setSpeed(boost ? 2 : _speed));
                }
                _scrubbing = boost;
                _armHide();
              },
              onScrub: (value) {
                _scrubbing = value;
                _armHide();
              },
              onSeek: (value) {
                if (_active != null) {
                  unawaited(_seek(Duration(milliseconds: value.round())));
                }
              },
              child: EpisodePager(
                controller: _pages,
                count: widget.episodes.length,
                onChanged: _pageChanged,
                builder: _page,
                locked: _locked || _casting.blocksLocal,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: math.max(
              28,
              math.max(
                MediaQuery.systemGestureInsetsOf(context).bottom,
                MediaQuery.viewPaddingOf(context).bottom,
              ),
            ),
            child: const AbsorbPointer(
              key: Key('playerHomeGestureGuard'),
              child: SizedBox.expand(),
            ),
          ),
          if (_casting.blocksLocal)
            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: FilledButton.icon(
                    key: const Key('reopenCastControls'),
                    onPressed: _cast,
                    icon: const Icon(Icons.cast_connected),
                    label: const Text('打开投屏控制'),
                  ),
                ),
              ),
            ),
          if (_casting.error != null && !_casting.blocksLocal)
            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _casting.error!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          if (_locked)
            SafeArea(
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton.filledTonal(
                  tooltip: '解锁手势',
                  onPressed: () {
                    setState(() => _locked = false);
                    _showControls();
                  },
                  icon: const Icon(Icons.lock_open),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: !(_controls || _loading || _error != null) || _locked,
            child: ExcludeSemantics(
              excluding: !(_controls || _loading || _error != null) || _locked,
              child: AnimatedOpacity(
                alwaysIncludeSemantics: true,
                opacity: (_controls || _loading || _error != null) && !_locked
                    ? 1
                    : 0,
                duration: const Duration(milliseconds: 180),
                child: Column(
                  children: [
                    DecoratedBox(
                      key: const Key('playerTopChrome'),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black87, Colors.transparent],
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: '返回',
                              onPressed: () => Navigator.maybePop(context),
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${widget.drama.title} · 第 ${widget.episodes[_index].number} 集',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            if (_airplay != null)
                              IconButton(
                                tooltip: _airplay!.active
                                    ? 'AirPlay · 已连接'
                                    : 'AirPlay',
                                onPressed:
                                    _loading ||
                                        _airplay!.preparing ||
                                        _casting.blocksLocal
                                    ? null
                                    : _prepareAirPlay,
                                icon: const Icon(
                                  Icons.airplay,
                                  color: Colors.white,
                                ),
                              ),
                            IconButton(
                              tooltip: '更多播放设置',
                              onPressed: _showMore,
                              icon: const Icon(
                                Icons.more_horiz,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    DecoratedBox(
                      key: const Key('playerBottomChrome'),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        minimum: const EdgeInsets.only(bottom: 4),
                        // The TV owns transport while casting. Remove the phone
                        // controls instead of disabling its Slider beneath the
                        // modal route (its overlay retains stale semantics).
                        child: _casting.blocksLocal
                            ? const SizedBox.shrink()
                            : _transport(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    _finishAttempt(PlaybackResult.cancelled);
    _session.invalidate();
    _save();
    _casting.removeListener(_castChanged);
    _casting.dispose();
    _airplay?.removeListener(_airPlayChanged);
    _airplay?.dispose();
    _hideTimer?.cancel();
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_preferencesChanged);
    _network?.cancel();
    _player.removeEventsListener(_event);
    if (_nativeEvents case final events?) unawaited(events.cancel());
    _healthTimer?.cancel();
    _lifecycle.close();
    _recovery.close();
    _detachTimeline();
    _session.close();
    _player.dispose(forceDispose: true);
    _pages.dispose();
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }
}

/// Only the controls rebuild for position updates, never the video/page tree.
class PlayerTransport extends StatefulWidget {
  const PlayerTransport({
    super.key,
    required this.duration,
    required this.position,
    required this.playing,
    required this.enabled,
    required this.speed,
    this.preparing = false,
    required this.onPlay,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onScrub,
    required this.onSeek,
  });
  final double duration, position, speed;
  final bool playing, enabled, preparing;
  final VoidCallback onPlay, onEpisodes;
  final ValueChanged<double> onSpeed, onSeek;
  final ValueChanged<bool> onScrub;
  @override
  State<PlayerTransport> createState() => _PlayerTransportState();
}

class _PlayerTransportState extends State<PlayerTransport> {
  double? _preview;
  String _time(double ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Slider(
          value: (_preview ?? widget.position).clamp(0, widget.duration),
          max: widget.duration > 0 ? widget.duration : 1,
          activeColor: const Color(0xFF9DCDB0),
          onChangeStart: widget.enabled && widget.duration > 0
              ? (value) {
                  widget.onScrub(true);
                  setState(() => _preview = value);
                }
              : null,
          onChanged: widget.enabled && widget.duration > 0
              ? (value) => setState(() => _preview = value)
              : null,
          onChangeEnd: widget.enabled && widget.duration > 0
              ? (value) {
                  widget.onSeek(value);
                  widget.onScrub(false);
                  setState(() => _preview = null);
                }
              : null,
        ),
        Row(
          children: [
            IconButton(
              tooltip: widget.playing ? '暂停' : '播放',
              onPressed: widget.enabled ? widget.onPlay : null,
              icon: Icon(
                widget.playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
            ),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_time(_preview ?? widget.position)} / ${widget.preparing ? '已准备 ' : ''}${_time(widget.duration)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
            PopupMenuButton<double>(
              tooltip: '播放倍速',
              initialValue: widget.speed,
              onOpened: () => widget.onScrub(true),
              onCanceled: () => widget.onScrub(false),
              onSelected: (speed) {
                widget.onSpeed(speed);
                widget.onScrub(false);
              },
              itemBuilder: (_) => [
                for (final speed in [.75, 1.0, 1.25, 1.5, 2.0])
                  PopupMenuItem(value: speed, child: Text('$speed 倍速')),
              ],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${widget.speed}x',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            TextButton(
              onPressed: widget.onEpisodes,
              child: const Text(
                '选集',
                style: TextStyle(color: Color(0xFF9DCDB0)),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
