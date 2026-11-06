import 'package:flutter/material.dart';

import '../domain/source_diagnostic.dart';
import 'discovery_cache_status.dart';

class SourceRequestStatus extends StatelessWidget {
  const SourceRequestStatus({super.key, this.sample, this.compact = false});
  final SourceDiagnostic? sample;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final sample = this.sample, theme = Theme.of(context);
    final failed = sample?.result == 'failed';
    final cached =
        sample != null &&
        (sample.requestResult == 'not_requested' ||
            sample.networkAttempts == 0 && sample.cacheHits > 0);
    final partial = sample?.result == 'partial';
    final label = sample == null
        ? '暂无请求记录'
        : '${sample.methodLabel} · ${failed
              ? sample.failureLabel.isEmpty
                    ? '失败'
                    : sample.failureLabel
              : partial
              ? sample.cacheHits > 0
                    ? '缓存回退'
                    : '部分结果'
              : cached
              ? '已保存'
              : sample.validation == 'passed'
              ? '读取成功'
              : '请求成功'}';
    final color = failed
        ? theme.colorScheme.error
        : cached || partial || sample == null
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    final time = sample == null ? null : formatDiscoveryTimestamp(sample.at);
    return Tooltip(
      message: [
        label,
        if (time != null) '$time · ${sample!.elapsedMs} ms',
        '最近请求记录，不代表视频播放验证',
      ].join('\n'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: compact ? 2 : null,
            overflow: compact ? TextOverflow.ellipsis : null,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
          if (!compact && time != null) ...[
            const SizedBox(height: 4),
            Text(
              '$time · ${sample!.elapsedMs} ms',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
