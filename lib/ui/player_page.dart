import 'episode_grid.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:better_player_plus/better_player_plus.dart';
// Native PiP stop is only exposed on this event stream; the public API emits a
// second, synthetic stop when it resets its video value for a new data source.
// ignore: implementation_imports
import 'package:better_player_plus/src/video_player/video_player_platform_interface.dart'
    show VideoEvent, VideoEventType;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../domain/playback_diagnostic.dart';
import '../domain/playback_policy.dart';
import '../platform/episode_buffer.dart';
import '../platform/media_preparer.dart';
import '../platform/provider_client.dart';
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
  });
  final AppStore store;
  final DownloadStore downloads;
  final Drama drama;
  final List<Episode> episodes;
  final int initialIndex;
  final List<int>? episodeIndices;
  final bool localOnly;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _Playable {
  _Playable(this.preparer, this.media, this.path, this.timing);
  final DateTime created = DateTime.now();
  final PreparationTiming timing;
  final MediaPreparer preparer;
  final ResolvedMedia? media;
  final String path;
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final PageController _pages;
  late final EpisodeBuffer<_Playable> _buffer;
  late final BetterPlayerController _player;
  final GlobalKey _playerKey = GlobalKey();
  final Map<int, int> _qualities = {};
  final Map<int, ResolvedMedia> _resolved = {};
  final PlaybackRecovery _recovery = PlaybackRecovery();
  final PlaybackHealth _health = PlaybackHealth();
  int? _recoveryGeneration;
  bool get _recovering => _recoveryGeneration == _generation;
  DateTime _prefetchRetryAt = DateTime(2000);
  Timer? _healthTimer;
  _Playable? _active;
  Future<void> _paused = Future.value();
  Future<void> _sourceSetup = Future.value();
  bool _pendingPlay = false;
  bool? _pipEntryWasPlaying;
  StreamSubscription<VideoEvent>? _nativeEvents;
  Timer? _hideTimer, _preloadTimer, _settleTimer;
  StreamSubscription<List<ConnectivityResult>>? _network;
  int _index = 0, _generation = 0;
  bool _controls = false, _locked = false, _fill = false;
  bool _loading = true, _foreground = true, _pipActive = false;
  bool _modal = false, _scrubbing = false;
  double _speed = 1;
  String? _error;
  String _loadingPhase = '正在查找本地视频…';
  PlaybackAttempt? _attempt;
  final Map<int, PreparationTiming> _timings = {};
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _speed = widget.store.playbackSpeed;
    _pages = PageController(initialPage: _index);
    _buffer = EpisodeBuffer(
      load: _prepare,
      release: _release,
      isReusable: (item) =>
          !item.path.startsWith('http') ||
          DateTime.now().difference(item.created) < const Duration(minutes: 2),
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
        _buffer.retain({_index});
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

  Future<_Playable> _prepare(
    int index,
    EpisodeCancellation cancellation,
  ) async {
    final timing = PreparationTiming();
    _timings[index] = timing;
    final stage = Stopwatch();
    var stageName = 'local';
    final preparer = MediaPreparer();
    cancellation.onCancel = () => unawaited(preparer.cancel());
    ResolvedMedia? media = _resolved.remove(index);
    try {
      cancellation.check();
      var path = await widget.downloads.localFile(
        widget.drama,
        widget.episodes[index],
      );
      cancellation.check();
      timing.local = path != null;
      if (path == null) {
        if (widget.localOnly || widget.store.offline) {
          throw const ProviderException('此分集尚未下载，请联网后播放');
        }
        stageName = 'resolve';
        _phase(index, '正在获取播放资源…');
        stage.start();
        media ??= await widget.store.provider.resolve(
          widget.drama,
          widget.episodes[index],
          quality: _qualities[index] ?? 0,
        );
        timing.resolveMs = stage.elapsedMilliseconds;
        stage.reset();
        stageName = 'prepare';
        _phase(
          index,
          media.contentKey.isEmpty ? '正在连接视频…' : '正在准备视频，首次播放可能稍久…',
        );
        cancellation.check();
        path = await preparer.prepare(media);
        timing.prepareMs = stage.elapsedMilliseconds;
        cancellation.check();
      }
      if (timing.local && media != null) {
        await _releaseMedia(media);
        media = null;
      }
      return _Playable(preparer, media, path, timing);
    } catch (_) {
      switch (stageName) {
        case 'resolve':
          timing.resolveMs = stage.elapsedMilliseconds;
        case 'prepare':
          timing.prepareMs = stage.elapsedMilliseconds;
      }
      await preparer.dispose();
      await _releaseMedia(media);
      rethrow;
    }
  }

  Future<void> _releaseMedia(ResolvedMedia? media) async {
    try {
      await widget.store.provider.release(media);
    } catch (_) {
      /* Best-effort session cleanup. */
    }
  }

  Future<void> _release(_Playable item) async {
    await item.preparer.dispose();
    await _releaseMedia(item.media);
  }

  void _save() {
    final value = _active == null ? null : _player.videoPlayerController?.value;
    if (value == null ||
        value.duration == null ||
        value.duration == Duration.zero) {
      return;
    }
    _lastSaved = DateTime.now();
    unawaited(
      widget.store
          .saveWatch(
            WatchRecord(
              drama: widget.drama,
              episodeId: widget.episodes[_index].id,
              episodeIndex: widget.episodeIndices?[_index] ?? _index,
              positionMs: value.position.inMilliseconds,
              durationMs: value.duration!.inMilliseconds,
              updatedAt: DateTime.now(),
            ),
          )
          .catchError((Object _) {}),
    );
  }

  void _pageChanged(int index) {
    if (index == _index) return;
    _recovery.reset();
    _health.reset();
    _prefetchRetryAt = DateTime(2000);
    _finishAttempt(PlaybackResult.cancelled);
    _timings.removeWhere((key, _) => (key - index).abs() > 1);
    _save();
    _hideTimer?.cancel();
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    ++_generation;
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
    _buffer.retain({index - 1, index, index + 1});
    if (_pipActive && !_foreground) {
      unawaited(_activate());
    } else {
      _settleTimer = Timer(
        const Duration(milliseconds: 120),
        () => unawaited(_activate()),
      );
    }
  }

  Future<void> _activate({bool resume = false, Duration? position}) async {
    _pendingPlay = false;
    final generation = ++_generation;
    final index = _index;
    final attempt = PlaybackAttempt(
      source: widget.drama.source,
      episode: widget.episodes[index].number,
      preloaded: _buffer.peek(index) != null,
    );
    _attempt = attempt;
    try {
      final pending = _buffer.prepare(index);
      attempt.timing = _timings[index] ?? PreparationTiming();
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
        headers: item.media?.headers,
        videoFormat: item.media?.hls == true && item.path.startsWith('http')
            ? BetterPlayerVideoFormat.hls
            : null,
        notificationConfiguration: BetterPlayerNotificationConfiguration(
          showNotification: true,
          title: widget.drama.title,
          author: '果果 · 第 ${widget.episodes[index].number} 集',
        ),
      );
      // Native setDataSource operates on one texture. Serialize rapid swipes so
      // an older request cannot finish after a newer episode starts loading.
      final setupFuture = _sourceSetup.then((_) async {
        if (mounted && generation == _generation) {
          await _player.setupDataSource(source);
        }
      });
      _sourceSetup = setupFuture.catchError((Object _) {});
      await setupFuture;
      item.timing.setupMs = setup.elapsedMilliseconds;
      if (!mounted || generation != _generation) return;
      _nativeEvents ??= _player
          .videoPlayerController
          ?.videoEventStreamController
          .stream
          .listen(_nativeEvent);
      _active = item;
      _health.reset();
      await _applyVideoFit();
      final record = widget.store.history[widget.drama.key];
      var start =
          position ??
          (resume && record?.episodeId == widget.episodes[index].id
              ? Duration(milliseconds: record!.positionMs)
              : null);
      final value = _player.videoPlayerController?.value;
      final duration = value?.duration ?? Duration.zero;
      if (start == null &&
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
      if (!_foreground && !_pipActive) {
        _pendingPlay = true;
        return;
      }
      attempt.initialPosition = _player.videoPlayerController?.value.position;
      await _player.play();
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

  void _retry({int? quality, bool automatic = false, ResolvedMedia? resolved}) {
    if (_recovering && !automatic) return;
    if (!automatic) _recovery.reset();
    _health.reset();
    _finishAttempt(PlaybackResult.cancelled);
    _save();
    final position = _active == null
        ? null
        : _player.videoPlayerController?.value.position;
    _paused = _active == null ? Future.value() : _player.pause();
    unawaited(_paused.catchError((Object _) {}));
    _active = null;
    if (quality != null) _qualities[_index] = quality;
    _buffer.evict(_index);
    if (resolved != null) _resolved[_index] = resolved;
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(_activate(resume: position == null, position: position));
  }

  void _checkHealth() {
    if (!mounted) return;
    final value = _player.videoPlayerController?.value;
    final stalled = _health.stalled(
      value?.position ?? Duration.zero,
      DateTime.now(),
      watching:
          _foreground &&
          !_loading &&
          !_recovering &&
          _error == null &&
          !_scrubbing &&
          !_modal &&
          _active != null &&
          value?.isPlaying == true,
    );
    if (stalled) unawaited(_recover());
    _schedulePrefetch();
  }

  Future<void> _recover() async {
    if (_recovering ||
        !mounted ||
        !_foreground ||
        widget.localOnly ||
        widget.store.offline ||
        _active?.timing.local == true) {
      return;
    }
    var media = _active?.media ?? _buffer.peek(_index)?.media;
    var action = _recovery.next(alternative: media?.hasAlternative == true);
    if (action == RecoveryAction.stop) {
      if (_active != null) unawaited(_player.pause());
      setState(() {
        _error = '自动恢复未成功，请重试或切换分集';
        _loading = false;
      });
      return;
    }
    final generation = _generation;
    _recoveryGeneration = generation;
    _preloadTimer?.cancel();
    _buffer.retain({_index});
    setState(() {
      _error = null;
      _loading = true;
      _loadingPhase = action == RecoveryAction.alternative
          ? '正在切换备用线路…'
          : '正在重新获取播放资源…';
    });
    ResolvedMedia? replacement;
    try {
      if (_active != null) await _player.pause();
      if (!mounted || generation != _generation) return;
      if (action == RecoveryAction.alternative) {
        try {
          replacement = await widget.store.provider.fallback(media!);
        } catch (_) {
          if (!mounted || generation != _generation) return;
          action = _recovery.next(alternative: false);
        }
      }
      if (!mounted || generation != _generation) return;
      if (action == RecoveryAction.stop) {
        setState(() {
          _error = '自动恢复未成功，请重试或切换分集';
          _loading = false;
        });
      } else {
        _finishAttempt(PlaybackResult.failed);
        final next = replacement;
        replacement = null;
        _retry(automatic: true, resolved: next);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '自动恢复未成功，请重试或切换分集';
          _loading = false;
        });
      }
    } finally {
      if (replacement != null) await _releaseMedia(replacement);
      if (_recoveryGeneration == generation) _recoveryGeneration = null;
      if (generation == _generation) _health.reset();
    }
  }

  void _event(BetterPlayerEvent event) {
    if (!mounted) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.finished:
        if (_loading || _active == null) break;
        _save();
        if (!_foreground && !_pipActive) break;
        if (widget.store.autoAdvance && _index + 1 < widget.episodes.length) {
          _goTo(_index + 1);
        } else {
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
      case VideoEventType.pipStart:
        _setPipActive(true);
        final wasPlaying = _pipEntryWasPlaying;
        _pipEntryWasPlaying = null;
        if (wasPlaying == true && _active != null) {
          unawaited(_player.play());
        }
      case VideoEventType.pipStop:
        _pipEntryWasPlaying = null;
        _setPipActive(false);
      default:
        break;
    }
  }

  void _setPipActive(bool active) {
    if (_pipActive == active) return;
    _pipActive = active;
    if (active) {
      if (_pendingPlay && _active != null) {
        _pendingPlay = false;
        unawaited(_player.play());
      }
      _schedulePrefetch();
    } else if (!_foreground) {
      _preloadTimer?.cancel();
      _buffer.retain({_index});
      if (_active != null) unawaited(_player.pause());
    }
  }

  void _preferencesChanged() {
    if (!widget.store.prefetch) {
      _preloadTimer?.cancel();
      _buffer.retain({_index});
    }
  }

  bool get _prefetchReady {
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
    if (_error != null ||
        _recovering ||
        !_prefetchReady ||
        _preloadTimer?.isActive == true ||
        DateTime.now().isBefore(_prefetchRetryAt) ||
        !widget.store.prefetch ||
        (!_foreground && !_pipActive) ||
        _active == null ||
        _loading ||
        _index + 1 >= widget.episodes.length ||
        _buffer.contains(_index + 1)) {
      return;
    }
    _preloadTimer?.cancel();
    final index = _index;
    _preloadTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final states = await Connectivity().checkConnectivity();
        if (!mounted ||
            _loading ||
            _recovering ||
            !_prefetchReady ||
            index != _index ||
            (!_foreground && !_pipActive) ||
            !widget.store.prefetch ||
            states.contains(ConnectivityResult.none) ||
            (!states.contains(ConnectivityResult.wifi) &&
                !widget.store.cellularPrefetch)) {
          return;
        }
        await _buffer.prepare(index + 1);
      } catch (_) {
        if (mounted && index == _index) {
          _prefetchRetryAt = DateTime.now().add(const Duration(seconds: 30));
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _health.reset();
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _preloadTimer?.cancel();
      if (!_pipActive) _buffer.retain({_index});
      _save();
    } else {
      if (_pendingPlay) {
        _pendingPlay = false;
        if (_active != null) unawaited(_player.play());
      }
      if (_pages.hasClients) _pages.jumpToPage(_index);
      _schedulePrefetch();
    }
  }

  void _goTo(int index) {
    if (index == _index || index < 0 || index >= widget.episodes.length) return;
    if (_pipActive && !_foreground) {
      // A backgrounded PageView may not animate or report onPageChanged. Keep
      // the native player and PiP layer alive while changing its media source.
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
    if (!_controls ||
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
    if (_active == null) return;
    final controller = _player;
    if (controller.isPlaying() == true) {
      if (_pipEntryWasPlaying != null) _pipEntryWasPlaying = false;
      await controller.pause();
    } else {
      if (_pipEntryWasPlaying != null) _pipEntryWasPlaying = true;
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
    // AVKit can pause the player while moving its layer into PiP. Capture the
    // viewer's intent before that transition; a deliberately paused episode
    // must remain paused in the window.
    _pipEntryWasPlaying = wasPlaying;
    try {
      await _player.enablePictureInPicture(_playerKey);
    } catch (_) {
      _pipEntryWasPlaying = null;
      rethrow;
    }
  }

  Future<void> _sheet(Widget child) async {
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
  Future<void> _showMore() async {
    final item = _active;
    await _sheet(
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
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
              enabled: item != null,
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
              enabled: item?.media != null,
              onTap: () {
                Navigator.pop(context);
                if (item?.media != null) {
                  showCastSheet(
                    context,
                    item!.media!,
                    widget.drama.title,
                    item.path.startsWith('http') ? null : item.path,
                    onConnected: _player.pause,
                  );
                }
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
  }

  Widget _page(BuildContext context, int index) {
    final item = _buffer.peek(index);
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
                      _error!,
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

  Widget _transport() {
    final controller = _active == null ? null : _player.videoPlayerController;
    Widget build() {
      final value = controller?.value;
      return PlayerTransport(
        duration: value?.duration?.inMilliseconds.toDouble() ?? 0,
        position: value?.position.inMilliseconds.toDouble() ?? 0,
        playing: value?.isPlaying == true,
        enabled: !_loading && _active != null,
        speed: _speed,
        onPlay: _togglePlay,
        onEpisodes: _showEpisodes,
        onSpeed: (speed) {
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
            unawaited(_player.seekTo(Duration(milliseconds: position.round())));
          }
          _armHide();
        },
      );
    }

    return controller == null
        ? build()
        : ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, child) => build(),
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
              enabled: !_locked && !_loading && _active != null,
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
                  unawaited(
                    _player.seekTo(Duration(milliseconds: value.round())),
                  );
                }
              },
              child: EpisodePager(
                controller: _pages,
                count: widget.episodes.length,
                onChanged: _pageChanged,
                builder: _page,
                locked: _locked,
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
                            if (Platform.isIOS)
                              const SizedBox(
                                width: 44,
                                height: 44,
                                child: UiKitView(viewType: 'guoguo/airplay'),
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
                        child: _transport(),
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
    ++_generation;
    _save();
    _hideTimer?.cancel();
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_preferencesChanged);
    _network?.cancel();
    _player.removeEventsListener(_event);
    if (_nativeEvents case final events?) unawaited(events.cancel());
    _healthTimer?.cancel();
    for (final media in _resolved.values) {
      unawaited(_releaseMedia(media));
    }
    _resolved.clear();
    _buffer.close();
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
    required this.onPlay,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onScrub,
    required this.onSeek,
  });
  final double duration, position, speed;
  final bool playing, enabled;
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
          onChangeStart: widget.enabled
              ? (value) {
                  widget.onScrub(true);
                  setState(() => _preview = value);
                }
              : null,
          onChanged: widget.enabled
              ? (value) => setState(() => _preview = value)
              : null,
          onChangeEnd: widget.enabled
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
                  '${_time(_preview ?? widget.position)} / ${_time(widget.duration)}',
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
