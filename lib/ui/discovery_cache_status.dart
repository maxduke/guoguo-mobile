import 'package:flutter/material.dart';

String formatDiscoveryTimestamp(DateTime savedAt) {
  final date = savedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

class DiscoveryCacheStatus extends StatelessWidget {
  const DiscoveryCacheStatus({
    super.key,
    required this.savedAt,
    required this.cached,
    this.compact = false,
    this.description = '',
  });
  final DateTime savedAt;
  final bool cached;
  final bool compact;
  final String description;

  @override
  Widget build(BuildContext context) {
    final time = formatDiscoveryTimestamp(savedAt);
    if (compact) {
      final date = savedAt.toLocal();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            '${cached ? '缓存' : '更新'} · ${date.month}-${date.day}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('上次获取 $time', style: Theme.of(context).textTheme.bodySmall),
            if (description.isNotEmpty)
              Text(description, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
      child: Text(
        '${cached ? '缓存 · ' : ''}上次获取 $time',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
