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
    this.onPrevious,
    this.onNext,
    this.previousLabel = '上一集',
    this.nextLabel = '下一集',
    required this.onEpisodes,
    required this.onSpeed,
    required this.onScrub,
    required this.onSeek,
    this.mediaIdentity,
  });
  final double duration, position, speed;
  final bool playing, enabled, preparing;
  final VoidCallback onPlay, onEpisodes;
  final VoidCallback? onPrevious, onNext;
  final String previousLabel, nextLabel;
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
          child: MergeSemantics(
            child: Semantics(
              label: '播放进度',
              child: Slider(
                // Reset Slider's gesture recognizers and overlay when its source
                // or availability changes, including when the chrome is hidden.
                key: ValueKey((_enabled, widget.mediaIdentity)),
                value: (_preview ?? widget.position).clamp(0, widget.duration),
                max: widget.duration > 0 ? widget.duration : 1,
                activeColor: const Color(0xFF9DCDB0),
                semanticFormatterCallback: (value) =>
                    '${_time(value)} / ${_time(widget.duration)}',
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
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${_time(_preview ?? widget.position)} / ${widget.preparing ? '已准备 ' : ''}${_time(widget.duration)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
          spacing: 4,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: widget.previousLabel,
                  onPressed: _foreground ? widget.onPrevious : null,
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  tooltip: widget.playing ? '暂停' : '播放',
                  onPressed: _enabled ? widget.onPlay : null,
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  icon: Icon(widget.playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: widget.nextLabel,
                  onPressed: _foreground ? widget.onNext : null,
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
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
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      '${widget.speed}x',
                      style: TextStyle(
                        color: _enabled ? Colors.white : Colors.white38,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: const Color(0xFF9DCDB0),
                disabledForegroundColor: Colors.white38,
              ),
              onPressed: _foreground ? widget.onEpisodes : null,
              child: const Text('选集'),
            ),
          ],
        ),
      ],
    ),
  );
}
