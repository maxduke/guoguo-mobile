import 'package:flutter/material.dart';

import '../domain/models.dart';

class DownloadRangeSheet extends StatefulWidget {
  const DownloadRangeSheet({
    super.key,
    required this.episodes,
    required this.startIndex,
  });
  final List<Episode> episodes;
  final int startIndex;
  @override
  State<DownloadRangeSheet> createState() => _DownloadRangeSheetState();
}

class _DownloadRangeSheetState extends State<DownloadRangeSheet> {
  late int start = widget.startIndex.clamp(0, widget.episodes.length - 1);
  late int end = (start + 9).clamp(start, widget.episodes.length - 1);
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('选择下载分集', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('已有下载自动跳过，失败任务会尝试恢复'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('接下来 10 集'),
                onPressed: () => setState(() {
                  start = widget.startIndex.clamp(
                    0,
                    widget.episodes.length - 1,
                  );
                  end = (start + 9).clamp(start, widget.episodes.length - 1);
                }),
              ),
              ActionChip(
                label: const Text('整部下载'),
                onPressed: () => setState(() {
                  start = 0;
                  end = widget.episodes.length - 1;
                }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey('start-$start'),
                  initialValue: start,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '从'),
                  items: [
                    for (var i = 0; i < widget.episodes.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text('第 ${widget.episodes[i].number} 集'),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    start = v!;
                    if (end < start) end = start;
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey('end-$end-$start'),
                  initialValue: end,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '到'),
                  items: [
                    for (var i = start; i < widget.episodes.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text('第 ${widget.episodes[i].number} 集'),
                      ),
                  ],
                  onChanged: (v) => setState(() => end = v!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, (start, end)),
            icon: const Icon(Icons.download_rounded),
            label: Text('加入下载（${end - start + 1} 集）'),
          ),
        ],
      ),
    ),
  );
}
