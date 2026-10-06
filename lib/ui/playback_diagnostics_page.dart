import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/app_store.dart';
import '../domain/playback_diagnostic.dart';
import 'components.dart';

class PlaybackDiagnosticsPage extends StatelessWidget {
  const PlaybackDiagnosticsPage({super.key, required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, store.preferences]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('播放诊断'),
        actions: [
          IconButton(
            tooltip: '清空诊断',
            onPressed: store.playbackDiagnostics.isEmpty
                ? null
                : () => perform(context, store.clearPlaybackDiagnostics),
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: '复制诊断',
            onPressed: store.playbackDiagnostics.isEmpty
                ? null
                : () => perform(context, () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: const JsonEncoder.withIndent('  ').convert(
                          store.playbackDiagnostics
                              .map((d) => d.toJson())
                              .toList(),
                        ),
                      ),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('诊断已复制')));
                    }
                  }),
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('提前开播（实验）'),
            subtitle: const Text(
              '仅用于从头播放的加密 MP4（主要为红果），已能直接播放的视频不受影响。进度条范围随已准备内容增长。续播、手动进入画中画和投屏时使用完整准备；自动画中画继续当前播放。',
            ),
            value: store.preferences.progressivePreparation,
            onChanged: (value) => perform(
              context,
              () => store.preferences.setPlayback(progressive: value),
            ),
          ),
          const SizedBox(height: 16),
          const Text('仅保留最近 30 条本地记录，不含剧名、播放地址或密钥。开播时间以播放进度首次前进为准，并非精确首帧时间。'),
          const SizedBox(height: 16),
          if (store.playbackDiagnostics.isEmpty)
            const Text('暂无记录，观看视频后可在这里查看。'),
          for (final sample in store.playbackDiagnostics)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${sample.source.label} · 第 ${sample.episode} 集 · ${switch (sample.result) {
                        PlaybackResult.started => '已开播',
                        PlaybackResult.failed => '失败',
                        PlaybackResult.cancelled => '已取消',
                      }}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${sample.at.toLocal().toString().split('.').first} · ${sample.local ? '本地视频' : '在线视频'}${sample.preloaded
                          ? sample.local
                                ? ' · 已准备本地文件'
                                : ' · 已提前准备地址'
                          : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      '${switch (sample.preparation) {
                        'progressive' => '提前开播',
                        'complete' => '完整准备',
                        _ => '直接播放',
                      }}${sample.compatibilityFallback ? ' · 已回退兼容方式' : ''}',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '解析 ${sample.resolveMs} ms · 媒体准备 ${sample.prepareMs} ms\n播放器准备 ${sample.setupMs} ms · 本次等待准备 ${sample.waitMs} ms\n${sample.result == PlaybackResult.started ? '到进度开始前进' : '到结束'} ${sample.elapsedMs} ms',
                    ),
                    if (sample.preloaded || sample.prefetchBytes > 0)
                      Text(
                        sample.prefetchBytes > 0
                            ? '预取缓存 ${(sample.prefetchBytes / 1024).toStringAsFixed(0)} KiB · 预取 ${sample.prefetchMs} ms；本次等待单独计时。'
                            : sample.local
                            ? '本地准备耗时来自缓存，本次等待单独计时。'
                            : '本次未缓存媒体首段；地址解析耗时来自预备阶段，本次等待单独计时。',
                        style: TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
