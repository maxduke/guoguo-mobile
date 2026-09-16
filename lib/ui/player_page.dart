import 'dart:async';
import 'dart:io';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
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
  _Playable(this.controller, this.preparer, this.media, this.path);
  final BetterPlayerController controller;
  final MediaPreparer preparer;
  final ResolvedMedia? media;
  final String path;
  final key = GlobalKey();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final PageController _pages;
  late final EpisodeBuffer<_Playable> _buffer;
  final Map<int, int> _qualities = {};
  _Playable? _active;
  Future<void> _paused = Future.value();
  bool _pendingPlay = false;
  Timer? _hideTimer, _preloadTimer, _settleTimer;
  StreamSubscription<List<ConnectivityResult>>? _network;
  int _index = 0, _generation = 0;
  bool _controls = false, _locked = false, _fill = false;
  bool _loading = true, _foreground = true, _modal = false, _scrubbing = false;
  double _speed = 1;
  String? _error;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
    _buffer = EpisodeBuffer(load: _prepare, release: _release);
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

  Future<_Playable> _prepare(
    int index,
    EpisodeCancellation cancellation,
  ) async {
    final preparer = MediaPreparer();
    cancellation.onCancel = () => unawaited(preparer.cancel());
    BetterPlayerController? controller;
    ResolvedMedia? media;
    try {
      cancellation.check();
      var path = await widget.downloads.localFile(
        widget.drama,
        widget.episodes[index],
      );
      cancellation.check();
      if (path == null) {
        if (widget.localOnly || widget.store.offline) {
          throw const ProviderException('此分集尚未下载，请联网后播放');
        }
        media = await widget.store.provider.resolve(
          widget.drama,
          widget.episodes[index],
          quality: _qualities[index] ?? 0,
        );
        cancellation.check();
        path = await preparer.prepare(media);
        cancellation.check();
      }
      controller = BetterPlayerController(
        BetterPlayerConfiguration(
          autoPlay: false,
          autoDispose: false,
          fit: _fill ? BoxFit.cover : BoxFit.contain,
          allowedScreenSleep: false,
          controlsConfiguration: const BetterPlayerControlsConfiguration(
            showControls: false,
          ),
        ),
      );
      await controller.setupDataSource(
        BetterPlayerDataSource(
          path.startsWith('http')
              ? BetterPlayerDataSourceType.network
              : BetterPlayerDataSourceType.file,
          path,
          headers: media?.headers,
          videoFormat: media?.hls == true && path.startsWith('http')
              ? BetterPlayerVideoFormat.hls
              : null,
          notificationConfiguration: BetterPlayerNotificationConfiguration(
            showNotification: true,
            title: widget.drama.title,
            author: '果果 · 第 ${widget.episodes[index].number} 集',
          ),
        ),
      );
      cancellation.check();
      return _Playable(controller, preparer, media, path);
    } catch (_) {
      controller?.dispose(forceDispose: true);
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
    item.controller.removeEventsListener(_event);
    item.controller.dispose(forceDispose: true);
    await item.preparer.dispose();
    await _releaseMedia(item.media);
  }

  void _save() {
    final value = _active?.controller.videoPlayerController?.value;
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
    _save();
    _hideTimer?.cancel();
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    ++_generation;
    _active?.controller.removeEventsListener(_event);
    _paused = _active?.controller.pause() ?? Future.value();
    unawaited(_paused.catchError((Object _) {}));
    setState(() {
      _index = index;
      _active = null;
      _loading = true;
      _error = null;
      _controls = false;
    });
    _buffer.retain({index - 1, index, index + 1});
    _settleTimer = Timer(
      const Duration(milliseconds: 120),
      () => unawaited(_activate()),
    );
  }

  Future<void> _activate({bool resume = false, Duration? position}) async {
    _pendingPlay = false;
    final generation = ++_generation;
    final index = _index;
    try {
      final item = await _buffer.prepare(index);
      if (!mounted || generation != _generation) return;
      _active = item;
      item.controller.setBetterPlayerGlobalKey(item.key);
      item.controller.setOverriddenFit(_fill ? BoxFit.cover : BoxFit.contain);
      item.controller.addEventsListener(_event);
      final record = widget.store.history[widget.drama.key];
      var start =
          position ??
          (resume && record?.episodeId == widget.episodes[index].id
              ? Duration(milliseconds: record!.positionMs)
              : null);
      final value = item.controller.videoPlayerController?.value;
      final duration = value?.duration ?? Duration.zero;
      if (start == null &&
          duration > Duration.zero &&
          value!.position >= duration - const Duration(milliseconds: 300)) {
        start = Duration.zero;
      }
      if (start != null) await item.controller.seekTo(start);
      if (!mounted || generation != _generation) return;
      await item.controller.setSpeed(_speed);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = null;
      });
      await WidgetsBinding.instance.endOfFrame;
      await _paused;
      if (!mounted || generation != _generation) return;
      if (!_foreground) {
        _pendingPlay = true;
        return;
      }
      await item.controller.play();
      _schedulePrefetch();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error is EpisodeCancelled ? '准备已取消，请重试' : '$error';
        });
      }
    }
  }

  void _retry({int? quality}) {
    _save();
    final position = _active?.controller.videoPlayerController?.value.position;
    _active?.controller.removeEventsListener(_event);
    _active = null;
    if (quality != null) _qualities[_index] = quality;
    _buffer.evict(_index);
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(_activate(resume: position == null, position: position));
  }

  void _event(BetterPlayerEvent event) {
    if (!mounted) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.finished:
        _save();
        if (_index + 1 < widget.episodes.length) {
          _goTo(_index + 1);
        } else {
          _showControls();
        }
        break;
      case BetterPlayerEventType.progress:
        if (DateTime.now().difference(_lastSaved).inSeconds >= 10) _save();
        break;
      case BetterPlayerEventType.exception:
        setState(() {
          _error = '视频暂时无法播放，请重试或切换分集';
          _loading = false;
        });
        break;
      case BetterPlayerEventType.play:
        _armHide();
        _schedulePrefetch();
        break;
      case BetterPlayerEventType.pause:
        _hideTimer?.cancel();
        break;
      default:
        break;
    }
  }

  void _preferencesChanged() {
    if (!widget.store.prefetch) {
      _preloadTimer?.cancel();
      _buffer.retain({_index});
    }
  }

  void _schedulePrefetch() {
    if (!widget.store.prefetch ||
        !_foreground ||
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
            index != _index ||
            !_foreground ||
            !widget.store.prefetch ||
            states.contains(ConnectivityResult.none) ||
            (!states.contains(ConnectivityResult.wifi) &&
                !widget.store.cellularPrefetch)) {
          return;
        }
        await _buffer.prepare(index + 1);
      } catch (_) {
        /* Speculative failure must not interrupt this episode. */
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _preloadTimer?.cancel();
      _save();
    } else {
      if (_pendingPlay) {
        _pendingPlay = false;
        unawaited(_active?.controller.play());
      }
      _schedulePrefetch();
    }
  }

  void _goTo(int index) {
    if (index == _index || index < 0 || index >= widget.episodes.length) return;
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
        _active?.controller.isPlaying() != true) {
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
    final controller = _active?.controller;
    if (controller == null) return;
    if (controller.isPlaying() == true) {
      await controller.pause();
    } else {
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
      height: MediaQuery.sizeOf(context).height * .55,
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
              child: GridView.builder(
                itemCount: widget.episodes.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 75,
                  mainAxisExtent: 48,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemBuilder: (context, index) => FilledButton.tonal(
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
                  child: Text('${widget.episodes[index].number}'),
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
                _active?.controller.setOverriddenFit(
                  _fill ? BoxFit.cover : BoxFit.contain,
                );
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
                Navigator.pop(context);
                if (item != null) {
                  perform(context, () async {
                    await item.controller.enablePictureInPicture(item.key);
                  });
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
                    onConnected: item.controller.pause,
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
          if (item != null)
            IgnorePointer(
              child: PlayerViewport(
                playerKey: item.key,
                controller: item.controller,
              ),
            )
          else
            Opacity(opacity: .25, child: Poster(widget.drama, radius: 0)),
          if (selected && _loading)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text('正在准备这一集…', style: TextStyle(color: Colors.white70)),
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
    final controller = _active?.controller.videoPlayerController;
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
          unawaited(_active?.controller.setSpeed(speed));
          _armHide();
        },
        onScrub: (scrubbing) {
          _scrubbing = scrubbing;
          _armHide();
        },
        onSeek: (position) {
          unawaited(
            _active?.controller.seekTo(
              Duration(milliseconds: position.round()),
            ),
          );
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
          PlayerGestures(
            onTap: _tap,
            enabled: !_locked && !_loading && _active != null,
            position: () =>
                _active
                    ?.controller
                    .videoPlayerController
                    ?.value
                    .position
                    .inMilliseconds
                    .toDouble() ??
                0,
            duration: () =>
                _active
                    ?.controller
                    .videoPlayerController
                    ?.value
                    .duration
                    ?.inMilliseconds
                    .toDouble() ??
                0,
            onBoost: (boost) {
              unawaited(_active?.controller.setSpeed(boost ? 2 : _speed));
              _scrubbing = boost;
              _armHide();
            },
            onScrub: (value) {
              _scrubbing = value;
              _armHide();
            },
            onSeek: (value) {
              unawaited(
                _active?.controller.seekTo(
                  Duration(milliseconds: value.round()),
                ),
              );
            },
            child: EpisodePager(
              controller: _pages,
              count: widget.episodes.length,
              onChanged: _pageChanged,
              builder: _page,
              locked: _locked,
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
            ignoring: !_controls || _locked,
            child: AnimatedOpacity(
              opacity: _controls && !_locked ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: SafeArea(
                child: Column(
                  children: [
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black87, Colors.transparent],
                        ),
                      ),
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
                    const Spacer(),
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: _transport(),
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
    ++_generation;
    _save();
    _hideTimer?.cancel();
    _preloadTimer?.cancel();
    _settleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_preferencesChanged);
    _network?.cancel();
    _active?.controller.removeEventsListener(_event);
    _buffer.close();
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
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
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
