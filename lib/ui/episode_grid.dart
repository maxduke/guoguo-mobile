import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'television_grid.dart';
import 'television_scope.dart';

/// Pages by list index while showing the source's original episode numbers.
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.builder,
    required this.onJump,
    this.initialIndex = 0,
    this.shrinkWrap = false,
    this.autofocus = false,
  });

  final List<Episode> episodes;
  final IndexedWidgetBuilder builder;
  final ValueChanged<int> onJump;
  final int initialIndex;

  /// Places the grid in the parent's scroll view (used on the detail page).
  final bool shrinkWrap;
  final bool autofocus;

  @override
  State<EpisodeGrid> createState() => EpisodeGridState();
}

class EpisodeGridState extends State<EpisodeGrid> {
  static const pageSize = 30;
  late int page = _currentPage;
  bool _pageChosenByUser = false;
  final _grid = GlobalKey<TelevisionGridState>();
  final _locateFocus = FocusNode(debugLabel: 'episodes-locate-current');
  final _previousFocus = FocusNode(debugLabel: 'episodes-previous-page');
  final _nextFocus = FocusNode(debugLabel: 'episodes-next-page');

  @override
  void dispose() {
    _locateFocus.dispose();
    _previousFocus.dispose();
    _nextFocus.dispose();
    super.dispose();
  }

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
    _focusEpisode(_currentIndex);
  }

  void focusCurrent() => _locateCurrent();

  void _focusEpisode(int index) {
    if (!TelevisionScope.of(context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _grid.currentState?.focusItem(index - page * pageSize);
    });
  }

  void _choosePage(int value) {
    setState(() {
      page = value;
      _pageChosenByUser = true;
    });
    _focusEpisode(value * pageSize);
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
    final grid = LayoutBuilder(
      builder: (context, constraints) => TelevisionGrid(
        key: _grid,
        itemKeys: [
          for (final episode in widget.episodes.skip(start).take(pageSize))
            episode.id,
        ],
        sliver: false,
        scrollIdentity: current,
        shrinkWrap: widget.shrinkWrap,
        padding: const EdgeInsets.only(bottom: 24),
        columns: math.max(1, (constraints.maxWidth / (tileWidth + 10)).ceil()),
        mainAxisExtent: tileHeight,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        autofocusIndex: widget.autofocus ? _currentIndex - start : null,
        above: _locateFocus,
        below: pages <= 1
            ? null
            : current < pages - 1
            ? _nextFocus
            : _previousFocus,
        itemBuilder: (context, index) {
          final absolute = start + index;
          return Semantics(
            container: true,
            selected: absolute == _currentIndex,
            label: '第 ${widget.episodes[absolute].number} 集',
            child: widget.builder(context, absolute),
          );
        },
      ),
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
              _choosePage(value);
            },
          ),
        Wrap(
          alignment: WrapAlignment.end,
          children: [
            TextButton.icon(
              focusNode: _locateFocus,
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
        if (pages > 1 && TelevisionScope.of(context))
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ExcludeFocus(
                excluding: current == 0,
                child: TextButton.icon(
                  focusNode: _previousFocus,
                  onPressed: current > 0
                      ? () => _choosePage(current - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('上一页'),
                ),
              ),
              Text('${current + 1} / $pages'),
              ExcludeFocus(
                excluding: current == pages - 1,
                child: TextButton.icon(
                  focusNode: _nextFocus,
                  onPressed: current < pages - 1
                      ? () => _choosePage(current + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('下一页'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
