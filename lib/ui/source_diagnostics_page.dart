import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/source_diagnostics.dart';

class SourceDiagnosticsPage extends StatelessWidget {
  const SourceDiagnosticsPage({super.key, required this.diagnostics});
  final SourceDiagnostics diagnostics;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: diagnostics,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('站源诊断'),
        actions: [
          IconButton(
            tooltip: '清空站源诊断',
            onPressed: diagnostics.samples.isEmpty ? null : diagnostics.clear,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: '复制站源诊断',
            onPressed: diagnostics.samples.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: const JsonEncoder.withIndent('  ').convert({
                          'format': 'guoguo.source-diagnostics',
                          'version': 1,
                          'samples': diagnostics.samples
                              .map((row) => row.toJson())
                              .toList(),
                        }),
                      ),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('站源诊断已复制')));
                    }
                  },
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('刷新或搜索出现问题后，可复制这些记录用于反馈。'),
          const SizedBox(height: 12),
          const Text('保留本次运行最近 64 条记录。联网尝试包含连接失败，不能代表站点已收到请求；未知表示没有取得该项统计。'),
          const SizedBox(height: 16),
          if (diagnostics.samples.isEmpty) const Text('暂无记录，刷新栏目或搜索后可在这里查看。'),
          for (final sample in diagnostics.samples)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${sample.source.label} · ${sample.methodLabel} · ${sample.resultLabel}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${sample.at.toLocal().toString().split('.').first} · 第 ${sample.page} 页'
                      '${sample.refresh ? ' · 手动刷新' : ''}${sample.background ? ' · 提前加载' : ''}',
                    ),
                    Text(
                      '${sample.elapsedMs} ms · 联网尝试 ${sample.networkAttempts ?? '未知'}'
                      ' · 缓存命中 ${sample.cacheHits} · 等待共享请求 ${sample.sharedWaits}',
                    ),
                    if (sample.httpStatus > 0)
                      Text('HTTP ${sample.httpStatus}'),
                    if (sample.failureLabel.isNotEmpty)
                      Text(sample.failureLabel),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
