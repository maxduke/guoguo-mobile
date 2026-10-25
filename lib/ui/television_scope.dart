import 'package:flutter/material.dart';

class TelevisionScope extends InheritedWidget {
  const TelevisionScope({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TelevisionScope>()?.enabled ??
      false;
  @override
  bool updateShouldNotify(TelevisionScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Observe descendant focus without adding another remote traversal stop.
class TelevisionFocusOutline extends StatefulWidget {
  const TelevisionFocusOutline({super.key, required this.child});
  final Widget child;
  @override
  State<TelevisionFocusOutline> createState() => _TelevisionFocusOutlineState();
}

class _TelevisionFocusOutlineState extends State<TelevisionFocusOutline> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    if (!TelevisionScope.of(context)) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      child: Stack(
        children: [
          widget.child,
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const Key('television-focus-outline'),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
