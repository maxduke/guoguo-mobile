import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One owner for video gestures. Vertical movement remains with the episode pager.
class PlayerGestures extends StatefulWidget {
  const PlayerGestures({
    super.key,
    required this.child,
    required this.onTap,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.onBoost,
    required this.onScrub,
    this.enabled = true,
  });
  final Widget child;
  final VoidCallback onTap;
  final double Function() position, duration;
  final ValueChanged<double> onSeek;
  final ValueChanged<bool> onBoost, onScrub;
  final bool enabled;
  @override
  State<PlayerGestures> createState() => _PlayerGesturesState();
}

class _PlayerGesturesState extends State<PlayerGestures>
    with WidgetsBindingObserver {
  double? _origin, _preview;
  double _distance = 0;
  bool _boost = false, _longGesture = false, _horizontalGesture = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _finish(commit: false);
  }

  @override
  void didUpdateWidget(PlayerGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) _finish(commit: false);
  }

  void _start({bool boost = false}) {
    if (widget.duration() <= 0) return;
    _origin = widget.position();
    _distance = 0;
    _longGesture = boost;
    _horizontalGesture = !boost;
    if (boost) {
      _boost = true;
      widget.onBoost(true);
      HapticFeedback.selectionClick();
    } else {
      widget.onScrub(true);
    }
    setState(() {});
  }

  void _move(double dx) {
    if (_origin == null) return;
    _distance += dx;
    if (_boost && _distance.abs() < 18) return;
    if (_boost) {
      _boost = false;
      widget.onBoost(false);
      widget.onScrub(true);
    }
    final span = widget.duration().clamp(0, 120000);
    setState(
      () => _preview =
          (_origin! + _distance / MediaQuery.sizeOf(context).width * span)
              .clamp(0, widget.duration()),
    );
  }

  void _finish({bool commit = true}) {
    if (_origin == null) return;
    if (_boost) widget.onBoost(false);
    if (commit && _preview != null) widget.onSeek(_preview!);
    widget.onScrub(false);
    _origin = _preview = null;
    _boost = false;
    _longGesture = false;
    _horizontalGesture = false;
    if (mounted) setState(() {});
  }

  String _time(double value) {
    final seconds = value ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: widget.onTap,
    onHorizontalDragStart: widget.enabled ? (_) => _start() : null,
    onHorizontalDragUpdate: widget.enabled
        ? (event) => _move(event.delta.dx)
        : null,
    onHorizontalDragEnd: widget.enabled ? (_) => _finish() : null,
    onHorizontalDragCancel: () {
      if (_horizontalGesture) _finish(commit: false);
    },
    onLongPressStart: widget.enabled ? (_) => _start(boost: true) : null,
    onLongPressMoveUpdate: widget.enabled
        ? (event) => _move(event.offsetFromOrigin.dx - _distance)
        : null,
    onLongPressEnd: (_) => _finish(),
    onLongPressCancel: () {
      if (_longGesture) _finish(commit: false);
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_boost || _preview != null)
          Center(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xB3000000),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Text(
                    _boost
                        ? '2 倍速 · 左右滑动调节进度'
                        : '${_preview! >= _origin! ? '快进' : '快退'}  ${_time(_preview!)} / ${_time(widget.duration())}\n松手跳转',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      height: 1.7,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
