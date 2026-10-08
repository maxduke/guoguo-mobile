import 'package:flutter/material.dart';

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
    this.mediaIdentity,
  });
  final double duration, position, speed;
  final bool playing, enabled, preparing;
  final VoidCallback onPlay, onEpisodes;
  final ValueChanged<double> onSpeed, onSeek;
  final ValueChanged<bool> onScrub;
  final Object? mediaIdentity;
  @override
  State<PlayerTransport> createState() => _PlayerTransportState();
}

class _PlayerTransportState extends State<PlayerTransport>
    with WidgetsBindingObserver {
  double? _preview;
  bool _foreground = true, _menuOpen = false;
  bool get _enabled => widget.enabled && _foreground;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _cancel(rebuild: false);
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PlayerTransport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        widget.duration <= 0 ||
        widget.mediaIdentity != oldWidget.mediaIdentity) {
      _cancel(rebuild: false);
    }
  }

  void _finishScrub({double? seek}) {
    if (_preview == null) return;
    _preview = null;
    if (seek != null) widget.onSeek(seek);
    if (!_menuOpen) widget.onScrub(false);
    if (mounted) setState(() {});
  }

  void _finishMenu() {
    if (!_menuOpen) return;
    _menuOpen = false;
    if (_preview == null) widget.onScrub(false);
  }

  void _cancel({bool rebuild = true}) {
    final interacting = _preview != null || _menuOpen;
    _preview = null;
    _menuOpen = false;
    if (interacting) widget.onScrub(false);
    if (interacting && rebuild && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel(rebuild: false);
    super.dispose();
  }

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
        Listener(
          // Slider reports pointer cancellation through onChangeEnd too.
          // Clear our preview first so only an ordinary release commits it.
          onPointerCancel: (_) => _finishScrub(),
          child: Slider(
            // Reset Slider's gesture recognizers and overlay when its source
            // or availability changes, including when the chrome is hidden.
            key: ValueKey((_enabled, widget.mediaIdentity)),
            value: (_preview ?? widget.position).clamp(0, widget.duration),
            max: widget.duration > 0 ? widget.duration : 1,
            activeColor: const Color(0xFF9DCDB0),
            onChangeStart: _enabled && widget.duration > 0
                ? (value) {
                    widget.onScrub(true);
                    setState(() => _preview = value);
                  }
                : null,
            onChanged: _enabled && widget.duration > 0
                ? (value) {
                    if (_preview != null) setState(() => _preview = value);
                  }
                : null,
            onChangeEnd: _enabled && widget.duration > 0
                ? (value) => _finishScrub(seek: value)
                : null,
          ),
        ),
        Row(
          children: [
            IconButton(
              tooltip: widget.playing ? '暂停' : '播放',
              onPressed: _enabled ? widget.onPlay : null,
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
              enabled: _enabled,
              initialValue: widget.speed,
              onOpened: () {
                _menuOpen = true;
                widget.onScrub(true);
              },
              onCanceled: _finishMenu,
              onSelected: (speed) {
                if (!_menuOpen || !_enabled) return;
                widget.onSpeed(speed);
                _finishMenu();
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
