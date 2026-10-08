import 'package:flutter/material.dart';
import '../data/record_store.dart';
import '../domain/models.dart';
import '../domain/watch_resume.dart';
import 'components.dart';

String episodeLabel(RecordStore records, WatchRecord record) {
  final number = records.episodeNumberFor(record);
  return number == null ? '上次观看' : '第 $number 集';
}

String watchLabel(RecordStore records, WatchRecord record) =>
    switch (records.resumeFor(record).status) {
      WatchStatus.waiting => '${episodeLabel(records, record)} · 等待更新',
      WatchStatus.completed => '已看完',
      WatchStatus.nextEpisode || WatchStatus.episodeCompleted =>
        '${episodeLabel(records, record)} · 本集已看完',
      WatchStatus.watching => episodeLabel(records, record),
    };

String continueLabel(RecordStore records, WatchRecord record) {
  final resume = records.resumeFor(record);
  if (resume.status == WatchStatus.nextEpisode) {
    return '${episodeLabel(records, record)}已播完 · 接着看第 ${resume.episode!.number} 集';
  }
  return '${episodeLabel(records, record)} · 已看 ${record.durationMs > 0 ? '${(record.progress * 100).round()}%' : '${record.positionMs ~/ 60000}分${record.positionMs ~/ 1000 % 60}秒'}';
}

class ContinueWatchingCard extends StatelessWidget {
  const ContinueWatchingCard({
    super.key,
    required this.records,
    required this.record,
    required this.busy,
    required this.onContinue,
    this.onDetails,
  });
  final RecordStore records;
  final WatchRecord record;
  final bool busy;
  final VoidCallback? onContinue, onDetails;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: InkWell(
      excludeFromSemantics: true,
      onTap: onContinue,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 64,
              child: Poster(record.drama, radius: 9),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '接着上次看 · ${record.drama.source.label}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    continueLabel(records, record),
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (onDetails != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: onDetails,
                        child: const Text('详情'),
                      ),
                    ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                tooltip: '继续观看 ${record.drama.title}',
                onPressed: onContinue,
                icon: const Icon(Icons.play_circle_fill_rounded, size: 36),
              ),
          ],
        ),
      ),
    ),
  );
}
