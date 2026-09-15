import 'dart:async';
import 'dart:io';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../platform/media_preparer.dart';
import '../platform/provider_client.dart';
import 'components.dart';
import 'cast_sheet.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.drama,
    required this.episodes,
    required this.initialIndex,
  });
  final AppStore store;
  final DownloadStore downloads;
  final Drama drama;
  final List<Episode> episodes;
  final int initialIndex;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _playerKey = GlobalKey();
  BetterPlayerController? _controller;
  ResolvedMedia? _media, _prefetchedMedia;
  BetterPlayerController? _prefetchedController;
  MediaPreparer? _preparer, _prefetchPreparer;
  String? _error, _localPath, _prefetchedPath;
  int _prefetchGeneration = 0;
  int _index = 0, _generation = 0, _prefetchedIndex = -1;
  bool _loading = true,
      _locked = false,
      _boost = false,
      _prefetching = false,
      _disposed = false;
  double _speed = 1, _drag = 0;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<List<ConnectivityResult>>? _network;
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _network = Connectivity().onConnectivityChanged.listen((states) {
      if (!states.contains(ConnectivityResult.wifi) &&
          !widget.store.cellularPrefetch) {
        _clearPrefetch();
      }
    });
    widget.store.addListener(_onPreferences);
    unawaited(_load(_index, resume: true));
  }

  void _onPreferences() {
    if (!widget.store.prefetch) _clearPrefetch();
  }

  BetterPlayerController _newController() => BetterPlayerController(
    const BetterPlayerConfiguration(
      autoPlay: false,
      autoDispose: false,
      fit: BoxFit.contain,
      allowedScreenSleep: false,
      controlsConfiguration: BetterPlayerControlsConfiguration(
        showControls: false,
      ),
    ),
  );
  BetterPlayerDataSource _dataSource(String path, ResolvedMedia? media) =>
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
          author: '果果 · 第 ${_index + 1} 集',
        ),
      );

  Future<void> _load(
    int index, {
    bool resume = false,
    int quality = 0,
    Duration? position,
  }) async {
    if (index < 0 || index >= widget.episodes.length || _disposed) return;
    final generation = ++_generation;
    await _save();
    if (!mounted || generation != _generation) return;
    final old = _controller;
    _controller = null;
    old?.removeEventsListener(_event);
    old?.dispose(forceDispose: true);
    final previousPreparer = _preparer;
    final previousMedia = _media;
    _preparer = null;
    _media = null;
    await previousPreparer?.dispose();
    unawaited(widget.store.provider.release(previousMedia));
    if (!mounted || generation != _generation) return;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _localPath = null;
      _boost = false;
    });
    BetterPlayerController? candidate;
    ResolvedMedia? resolved;
    MediaPreparer? preparer;
    try {
      if (_prefetchedIndex == index &&
          _prefetchedController != null &&
          quality == 0) {
        candidate = _prefetchedController;
        resolved = _prefetchedMedia;
        _localPath = _prefetchedPath;
        _prefetchedPath = null;
        _preparer = _prefetchPreparer;
        _prefetchPreparer = null;
        _prefetchedController = null;
        _prefetchedMedia = null;
        _prefetchedIndex = -1;
      } else {
        final local = await widget.downloads.localFile(
          widget.drama,
          widget.episodes[index],
        );
        String path;
        if (local != null) {
          path = local;
        } else {
          if (widget.store.offline) {
            throw const ProviderException('此分集尚未下载，请联网后播放');
          }
          resolved = await widget.store.provider.resolve(
            widget.drama,
            widget.episodes[index],
            quality: quality,
          );
          preparer = MediaPreparer();
          _preparer = preparer;
          path = await preparer.prepare(resolved);
        }
        if (!mounted || generation != _generation) {
          await widget.store.provider.release(resolved);
          await preparer?.dispose();
          return;
        }
        _localPath = path.startsWith('http') ? null : path;
        candidate = _newController();
        await candidate.setupDataSource(_dataSource(path, resolved));
      }
      if (!mounted || generation != _generation) {
        candidate?.dispose(forceDispose: true);
        await widget.store.provider.release(resolved);
        return;
      }
      _controller = candidate;
      _media = resolved;
      candidate!.setBetterPlayerGlobalKey(_playerKey);
      candidate.addEventsListener(_event);
      final record = widget.store.history[widget.drama.key];
      final start =
          position ??
          (resume && record?.episodeId == widget.episodes[index].id
              ? Duration(milliseconds: record!.positionMs)
              : Duration.zero);
      if (start > Duration.zero) await candidate.seekTo(start);
      await candidate.setSpeed(_speed);
      await candidate.play();
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    } catch (error) {
      candidate?.dispose(forceDispose: true);
      await widget.store.provider.release(resolved);
      if (mounted && generation == _generation) {
        setState(() {
          _controller = null;
          _media = null;
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  void _event(BetterPlayerEvent event) {
    if (!mounted || _disposed) return;
    if (event.betterPlayerEventType == BetterPlayerEventType.finished) {
      if (_index + 1 < widget.episodes.length) {
        unawaited(_load(_index + 1));
      } else {
        unawaited(_save());
      }
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.progress) {
      final value = _controller?.videoPlayerController?.value;
      if (value?.isPlaying == true &&
          DateTime.now().difference(_lastSaved).inSeconds >= 5) {
        unawaited(_save());
      }
      final duration = value?.duration ?? Duration.zero;
      final position = value?.position ?? Duration.zero;
      if (duration > Duration.zero &&
          duration - position < const Duration(seconds: 20)) {
        unawaited(_prefetch());
      }
      setState(() {});
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
      setState(() => _error = '视频暂时无法播放，请重试或切换分集');
    }
    if (event.betterPlayerEventType == BetterPlayerEventType.play ||
        event.betterPlayerEventType == BetterPlayerEventType.pause) {
      setState(() {});
    }
  }

  Future<void> _save() async {
    final value = _controller?.videoPlayerController?.value;
    if (value == null ||
        value.duration == null ||
        value.duration == Duration.zero ||
        value.position == Duration.zero) {
      return;
    }
    _lastSaved = DateTime.now();
    try {
      await widget.store.saveWatch(
        WatchRecord(
          drama: widget.drama,
          episodeId: widget.episodes[_index].id,
          episodeIndex: _index,
          positionMs: value.position.inMilliseconds,
          durationMs: value.duration!.inMilliseconds,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      /* AppStore exposes persistence failures in the main UI. */
    }
  }

  Future<void> _prefetch() async {
    final next = _index + 1;
    if (!widget.store.prefetch ||
        _prefetching ||
        _prefetchedIndex == next ||
        next >= widget.episodes.length ||
        _disposed) {
      return;
    }
    _prefetching = true;
    final generation = _generation;
    final prefetchGeneration = ++_prefetchGeneration;
    var transferred = false;
    ResolvedMedia? media;
    BetterPlayerController? controller;
    final preparer = MediaPreparer();
    _prefetchPreparer = preparer;
    try {
      final states = await Connectivity().checkConnectivity();
      if (!states.contains(ConnectivityResult.wifi) &&
          !widget.store.cellularPrefetch) {
        return;
      }
      if (states.contains(ConnectivityResult.none)) return;
      media = await widget.store.provider.resolve(
        widget.drama,
        widget.episodes[next],
      );
      if (_disposed ||
          generation != _generation ||
          prefetchGeneration != _prefetchGeneration) {
        return;
      }
      final path = await preparer.prepare(media);
      if (_disposed ||
          generation != _generation ||
          prefetchGeneration != _prefetchGeneration) {
        return;
      }
      controller = _newController();
      await controller.setupDataSource(_dataSource(path, media));
      if (_disposed ||
          generation != _generation ||
          prefetchGeneration != _prefetchGeneration ||
          !widget.store.prefetch) {
        return;
      }
      _clearPrefetch(cancelPending: false);
      _prefetchedPath = path.startsWith('http') ? null : path;
      _prefetchedMedia = media;
      _prefetchedController = controller;
      _prefetchedIndex = next;
      transferred = true;
      media = null;
      controller = null;
    } catch (_) {
      /* Prebuffer failures must not interrupt current playback. */
    } finally {
      controller?.dispose(forceDispose: true);
      await widget.store.provider.release(media);
      if (!transferred) await preparer.dispose();
      _prefetching = false;
    }
  }

  void _clearPrefetch({bool cancelPending = true}) {
    if (cancelPending) {
      ++_prefetchGeneration;
      unawaited(_prefetchPreparer?.dispose());
      _prefetchPreparer = null;
    }
    _prefetchedController?.dispose(forceDispose: true);
    _prefetchedController = null;
    unawaited(widget.store.provider.release(_prefetchedMedia));
    _prefetchedMedia = null;
    _prefetchedIndex = -1;
  }

  Future<void> _togglePlay() async {
    if (_controller?.isPlaying() == true) {
      await _controller?.pause();
    } else {
      await _controller?.play();
    }
    if (mounted) setState(() {});
  }

  void _showEpisodes() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .55,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _episodeGrid(),
        ),
      ),
    ),
  );
  Widget _episodeGrid() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '选集 · 共 ${widget.episodes.length} 集',
        style: Theme.of(context).textTheme.titleLarge,
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
              if (ModalRoute.of(context) is ModalBottomSheetRoute) {
                Navigator.pop(context);
              }
              unawaited(_load(index));
            },
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor: index == _index
                  ? Theme.of(context).colorScheme.primary
                  : null,
              foregroundColor: index == _index
                  ? Theme.of(context).colorScheme.onPrimary
                  : null,
            ),
            child: Text('${widget.episodes[index].number}'),
          ),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final value = _controller?.videoPlayerController?.value;
    final duration = value?.duration?.inMilliseconds.toDouble() ?? 0;
    final position = value?.position.inMilliseconds.toDouble() ?? 0;
    final video = Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _locked ? null : _togglePlay,
            onVerticalDragStart: _locked ? null : (_) => _drag = 0,
            onVerticalDragUpdate: _locked
                ? null
                : (details) => _drag += details.delta.dy,
            onVerticalDragEnd: _locked
                ? null
                : (_) {
                    if (_drag.abs() > 70) {
                      unawaited(_load(_index + (_drag < 0 ? 1 : -1)));
                    }
                  },
            onLongPressStart: _locked
                ? null
                : (_) {
                    setState(() => _boost = true);
                    unawaited(_controller?.setSpeed(2));
                  },
            onLongPressEnd: _locked
                ? null
                : (_) {
                    setState(() => _boost = false);
                    unawaited(_controller?.setSpeed(_speed));
                  },
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_controller != null && !_loading)
                    BetterPlayer(key: _playerKey, controller: _controller!),
                  if (_loading)
                    const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 18),
                          Text(
                            '正在准备视频…',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  if (_error != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.white70,
                              size: 36,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 18),
                            FilledButton(
                              onPressed: () => _load(_index, resume: true),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_boost)
                    const Positioned(
                      top: 22,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Text(
                          '▶▶ 2 倍速播放',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 10,
                    top: 10,
                    child: IconButton(
                      tooltip: _locked ? '解锁手势' : '锁定手势',
                      onPressed: () => setState(() => _locked = !_locked),
                      icon: Icon(
                        _locked ? Icons.lock : Icons.lock_open,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!_locked)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                Slider(
                  value: position.clamp(0, duration),
                  max: duration <= 0 ? 1 : duration,
                  onChanged: _loading
                      ? null
                      : (v) => _controller?.seekTo(
                          Duration(milliseconds: v.toInt()),
                        ),
                  activeColor: const Color(0xFF9DCDB0),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: value?.isPlaying == true ? '暂停' : '播放',
                      onPressed: _togglePlay,
                      icon: Icon(
                        value?.isPlaying == true
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${_time(position)} / ${_time(duration)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    PopupMenuButton<double>(
                      tooltip: '播放倍速',
                      initialValue: _speed,
                      onSelected: (v) {
                        setState(() => _speed = v);
                        _controller?.setSpeed(v);
                      },
                      itemBuilder: (_) => [
                        for (final speed in [.75, 1.0, 1.25, 1.5, 2.0])
                          PopupMenuItem(value: speed, child: Text('$speed 倍速')),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '${_speed}x',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '画中画',
                      onPressed: _controller == null
                          ? null
                          : () => perform(context, () async {
                              await _controller!.enablePictureInPicture(
                                _playerKey,
                              );
                            }),
                      icon: const Icon(
                        Icons.picture_in_picture_alt_outlined,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '切换横竖屏',
                      onPressed: () => SystemChrome.setPreferredOrientations(
                        MediaQuery.orientationOf(context) ==
                                Orientation.portrait
                            ? [
                                DeviceOrientation.landscapeLeft,
                                DeviceOrientation.landscapeRight,
                              ]
                            : [DeviceOrientation.portraitUp],
                      ),
                      icon: const Icon(
                        Icons.screen_rotation_outlined,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _locked
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(
                widget.drama.title,
                style: const TextStyle(fontSize: 16),
              ),
              actions: [
                if (Platform.isIOS)
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: UiKitView(viewType: 'guoguo/airplay'),
                  ),
                IconButton(
                  tooltip: '投屏到电视',
                  onPressed: _media == null
                      ? null
                      : () => showCastSheet(
                          context,
                          _media!,
                          widget.drama.title,
                          _localPath,
                          onConnected: () async {
                            await _controller?.pause();
                          },
                        ),
                  icon: const Icon(Icons.cast),
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: wide
                  ? Row(
                      children: [
                        Expanded(flex: 3, child: video),
                        Expanded(
                          child: Theme(
                            data: ThemeData.dark(),
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: _episodeGrid(),
                            ),
                          ),
                        ),
                      ],
                    )
                  : video,
            ),
            if (!_locked)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.drama.source.label} · 第 ${_index + 1} 集',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    if ((_media?.qualities.length ?? 0) > 1)
                      PopupMenuButton<int>(
                        tooltip: '清晰度',
                        onSelected: (q) => _load(
                          _index,
                          quality: q,
                          position: value?.position,
                        ),
                        itemBuilder: (_) => [
                          for (final q in _media!.qualities)
                            PopupMenuItem(value: q, child: Text('${q}P')),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '${_media?.quality}P',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: '下载当前集',
                      onPressed: () => perform(
                        context,
                        () => widget.downloads.enqueue(
                          widget.drama,
                          widget.episodes[_index],
                          _index,
                        ),
                      ),
                      icon: const Icon(
                        Icons.download_outlined,
                        color: Colors.white70,
                      ),
                    ),
                    TextButton(
                      onPressed: _showEpisodes,
                      child: const Text(
                        '选集',
                        style: TextStyle(color: Color(0xFF9DCDB0)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _time(double ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_save());
    widget.store.removeListener(_onPreferences);
    _network?.cancel();
    _controller?.removeEventsListener(_event);
    _controller?.dispose(forceDispose: true);
    unawaited(_preparer?.dispose());
    _clearPrefetch();
    unawaited(widget.store.provider.release(_media));
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }
}
