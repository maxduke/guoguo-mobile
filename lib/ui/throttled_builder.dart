import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// Throttle display updates only; the controller retains every real position.
class ThrottledValueBuilder<T> extends StatefulWidget {
  const ThrottledValueBuilder({
    super.key,
    required this.listenable,
    required this.active,
    required this.builder,
    required this.immediate,
    this.interval = const Duration(milliseconds: 240),
  });
  final ValueListenable<T> listenable;
  final bool active;
  final WidgetBuilder builder;
  final bool Function(T previous, T current) immediate;
  final Duration interval;
  @override
  State<ThrottledValueBuilder<T>> createState() =>
      _ThrottledValueBuilderState<T>();
}

class _ThrottledValueBuilderState<T> extends State<ThrottledValueBuilder<T>> {
  Timer? _timer;
  late T _previous;
  DateTime _painted = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
    _previous = widget.listenable.value;
    widget.listenable.addListener(_changed);
  }

  void _changed() {
    final current = widget.listenable.value;
    final immediate = widget.immediate(_previous, current);
    _previous = current;
    if (!widget.active) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final remaining = widget.interval - DateTime.now().difference(_painted);
    if (immediate || remaining <= Duration.zero) {
      _refresh();
    } else {
      _timer ??= Timer(remaining, _refresh);
    }
  }

  void _refresh() {
    _timer?.cancel();
    _timer = null;
    if (!mounted || !widget.active) return;
    _painted = DateTime.now();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ThrottledValueBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      _previous = widget.listenable.value;
      widget.listenable.addListener(_changed);
    }
    if (!widget.active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
