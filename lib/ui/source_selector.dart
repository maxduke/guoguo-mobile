import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';

class _SourceChoice {
  const _SourceChoice(this.source);
  final DramaSource? source;
}

/// A fixed-width entry to all sources, shared by browsing and record filters.
class SourceSelector extends StatefulWidget {
  const SourceSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.includeAll = false,
  });
  final DramaSource? value;
  final ValueChanged<DramaSource?> onChanged;
  final bool includeAll;
  @override
  State<SourceSelector> createState() => _SourceSelectorState();
}

class _SourceSelectorState extends State<SourceSelector> {
  bool _opening = false;
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    try {
      final choice = await showModalBottomSheet<_SourceChoice>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) =>
            _SourceSheet(selected: widget.value, includeAll: widget.includeAll),
      );
      if (mounted && choice != null && choice.source != widget.value) {
        widget.onChanged(choice.source);
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: OutlinedButton.icon(
      onPressed: _open,
      icon: const Icon(Icons.grid_view_rounded, size: 20),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.value?.label ?? '全部站源'),
          const SizedBox(width: 8),
          const Icon(Icons.expand_more, size: 20),
        ],
      ),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
    ),
  );
}

class _SourceSheet extends StatefulWidget {
  const _SourceSheet({required this.selected, required this.includeAll});
  final DramaSource? selected;
  final bool includeAll;
  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available =
        media.size.height - media.viewInsets.bottom - media.padding.top;
    final sources =
        <DramaSource?>[if (widget.includeAll) null, ...DramaSource.values]
            .where(
              (source) => '${source?.label ?? '全部站源'} ${source?.name ?? ''}'
                  .toLowerCase()
                  .contains(_query.trim().toLowerCase()),
            )
            .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: math.min(650, math.max(0, available - 32)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scale = media.textScaler.scale(14) / 14;
                final columns = scale >= 1.5
                    ? 2
                    : constraints.maxWidth >= 480
                    ? 4
                    : 3;
                final width =
                    (constraints.maxWidth - (columns - 1) * 8) / columns;
                return SingleChildScrollView(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '选择站源',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭站源选择',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          hintText: '搜索站源',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                      const SizedBox(height: 16),
                      if (sources.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Text('没有匹配的站源'),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final source in sources)
                              SizedBox(
                                width: width,
                                height: math.max(56, 48 * scale),
                                child: ChoiceChip(
                                  label: Center(
                                    child: Text(
                                      source?.label ?? '全部站源',
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  labelPadding: EdgeInsets.zero,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  showCheckmark: false,
                                  selected: widget.selected == source,
                                  onSelected: (_) => Navigator.pop(
                                    context,
                                    _SourceChoice(source),
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
