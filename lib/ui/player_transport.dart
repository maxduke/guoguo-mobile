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
