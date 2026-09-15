import 'package:flutter/material.dart';

class EpisodePager extends StatelessWidget {
  const EpisodePager({
    super.key,
    required this.controller,
    required this.count,
    required this.onChanged,
    required this.builder,
    this.locked = false,
  });
  final PageController controller;
  final int count;
  final ValueChanged<int> onChanged;
  final IndexedWidgetBuilder builder;
  final bool locked;
  @override
  Widget build(BuildContext context) => PageView.builder(
    controller: controller,
    scrollDirection: Axis.vertical,
    physics: locked
        ? const NeverScrollableScrollPhysics()
        : const PageScrollPhysics(),
    itemCount: count,
    onPageChanged: onChanged,
    itemBuilder: builder,
  );
}
