import 'package:flutter/material.dart';

class DiscoveryCacheStatus extends StatelessWidget {
  const DiscoveryCacheStatus({
    super.key,
    required this.savedAt,
    required this.cached,
  });
  final DateTime savedAt;
  final bool cached;

  @override
  Widget build(BuildContext context) {
    final date = savedAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final time =
        '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
      child: Text(
        '${cached ? '缓存 · ' : ''}上次获取 $time',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
