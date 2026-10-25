import 'package:flutter/widgets.dart';

/// Keep page State while subscribing to display updates only when visible.
class ActiveListenableBuilder extends StatefulWidget {
  const ActiveListenableBuilder({
    super.key,
    required this.listenable,
    required this.active,
    required this.builder,
  });
  final Listenable listenable;
  final bool active;
  final WidgetBuilder builder;
  @override
  State<ActiveListenableBuilder> createState() =>
      _ActiveListenableBuilderState();
}

class _ActiveListenableBuilderState extends State<ActiveListenableBuilder> {
  @override
  void initState() {
    super.initState();
    if (widget.active) widget.listenable.addListener(_changed);
  }

  void _changed() {
    if (mounted && widget.active) setState(() {});
  }

  @override
  void didUpdateWidget(ActiveListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active) oldWidget.listenable.removeListener(_changed);
    if (widget.active) widget.listenable.addListener(_changed);
  }

  @override
  void dispose() {
    if (widget.active) widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: widget.active, child: widget.builder(context));
}
