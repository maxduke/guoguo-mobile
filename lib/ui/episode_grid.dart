import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';

/// Pages by list index while showing the source's original episode numbers.
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.builder,
    required this.onJump,
    this.initialIndex = 0,
    this.shrinkWrap = false,
  });

  final List<Episode> episodes;
  final IndexedWidgetBuilder builder;
  final ValueChanged<int> onJump;
  final int initialIndex;

  /// Places the grid in the parent's scroll view (used on the detail page).
  final bool shrinkWrap;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid> {
  static const pageSize = 30;
  late int page = _currentPage;
  bool _pageChosenByUser = false;

  int get _currentIndex => widget.episodes.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, widget.episodes.length - 1);
  int get _currentPage => _currentIndex ~/ pageSize;

  @override
  void didUpdateWidget(covariant EpisodeGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.episodes.isEmpty) {
      page = 0;
      _pageChosenByUser = false;
      return;
    }
    final listChanged =
        oldWidget.episodes.length != widget.episodes.length ||
        !identical(oldWidget.episodes, widget.episodes) &&
            Iterable.generate(widget.episodes.length).any(
              (index) =>
                  oldWidget.episodes[index].id != widget.episodes[index].id,
            );
    if (_pageChosenByUser && listChanged && oldWidget.episodes.isNotEmpty) {
      final oldStart = (page * pageSize).clamp(
        0,
        oldWidget.episodes.length - 1,
      );
      final anchorId = oldWidget.episodes[oldStart].id;
      final anchor = widget.episodes.indexWhere((e) => e.id == anchorId);
      if (anchor >= 0) page = anchor ~/ pageSize;
    } else if (!_pageChosenByUser &&
        (listChanged || oldWidget.initialIndex != widget.initialIndex)) {
      page = _currentPage;
    }
    page = page.clamp(0, (widget.episodes.length - 1) ~/ pageSize);
  }

  void _locateCurrent() {
    setState(() {
      page = _currentPage;
      _pageChosenByUser = false;
    });
  }

  Future<void> _jump() async {
    var input = '';
    String? error;
    final index = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void submit() {
            final number = int.tryParse(input);
            final index = widget.episodes.indexWhere((e) => e.number == number);
            if (index < 0) {
              update(() => error = '没有这一集，请输入已有集数');
              return;
            }
            Navigator.pop(context, index);
          }

          return AlertDialog(
            title: const Text('跳转到分集'),
            content: TextField(
              onChanged: (value) => input = value,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(labelText: '集数', errorText: error),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('播放')),
            ],
          );
        },
      ),
    );
    if (!mounted || index == null) return;
    setState(() {
      page = index ~/ pageSize;
      _pageChosenByUser = true;
    });
    widget.onJump(index);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.episodes.length;
    if (count == 0) return const Center(child: Text('暂无分集'));
    final pages = (count / pageSize).ceil();
    final current = page.clamp(0, pages - 1);
    final start = current * pageSize;
    final scaler = MediaQuery.textScalerOf(context);
    final maxDigits = widget.episodes
        .skip(start)
        .take(pageSize)
        .fold(
          1,
          (int width, episode) => math.max(width, '${episode.number}'.length),
        );
    final tileWidth = math.max(80.0, scaler.scale(16) * maxDigits * .65 + 32);
    final tileHeight = math.max(
      64.0,
      scaler.scale(18) + scaler.scale(12) * 2 + 20,
    );
    final grid = GridView.builder(
      key: ValueKey(current),
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.only(bottom: 24),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: tileWidth,
        mainAxisExtent: tileHeight,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: math.min(pageSize, count - start),
      itemBuilder: (context, index) {
        final absolute = start + index;
        return Semantics(
          container: true,
          selected: absolute == _currentIndex,
          label: '第 ${widget.episodes[absolute].number} 集',
          child: widget.builder(context, absolute),
        );
      },
    );
    return Column(
      mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (pages > 1)
          DropdownButton<int>(
            value: current,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (var i = 0; i < pages; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    '${widget.episodes[i * pageSize].number}–${widget.episodes[math.min((i + 1) * pageSize, count) - 1].number} 集',
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                page = value;
                _pageChosenByUser = true;
              });
            },
          ),
        Wrap(
          alignment: WrapAlignment.end,
          children: [
            TextButton.icon(
              onPressed: _locateCurrent,
              icon: const Icon(Icons.my_location_rounded, size: 18),
              label: const Text('定位当前'),
            ),
            TextButton.icon(
              onPressed: _jump,
              icon: const Icon(Icons.pin_outlined, size: 18),
              label: const Text('跳集'),
            ),
          ],
        ),
        if (widget.shrinkWrap) grid else Expanded(child: grid),
      ],
    );
  }
}
