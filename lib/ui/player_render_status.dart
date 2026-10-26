import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'components.dart';
import 'television_scope.dart';

/// A snapshot of the open player, not a promise that the TV displayed a frame.
class PlayerRenderStatus extends StatelessWidget {
  const PlayerRenderStatus({
    super.key,
    required this.playback,
    required this.deviceInfo,
  });
  final Map<String, Object?> playback;
  final Future<Map<String, Object?>> deviceInfo;

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, Object?>>(
    future: deviceInfo,
    builder: (context, snapshot) {
      final device = snapshot.data ?? const <String, Object?>{};
      String yes(Object? value) => value == true ? '是' : '否';
      final rows = <String, String>{
        '应用': '${device['version'] ?? '未知'} (${device['build'] ?? '未知'})',
        '设备': '${device['manufacturer'] ?? '未知'} ${device['model'] ?? ''}',
        '系统':
            'Android ${device['androidVersion'] ?? '未知'} · API ${device['apiLevel'] ?? '未知'}',
        '架构': (device['abis'] as List?)?.join(', ') ?? '未知',
        '渲染配置': device['renderingPolicy'] == 'legacy-opengl'
            ? '旧版 OpenGL（TV 兼容）'
            : device['renderingPolicy'] == 'automatic'
            ? '自动'
            : '未知',
        '播放准备':
            '${playback['prepared'] == true ? '已准备' : '未准备'} · 加载中：${yes(playback['loading'])}',
        '播放器':
            '初始化：${yes(playback['initialized'])} · 播放中：${yes(playback['playing'])}',
        '画面尺寸': '${playback['width'] ?? 0} × ${playback['height'] ?? 0}（播放器报告）',
        '界面状态':
            '电视：${yes(playback['uiTelevision'])} · 封面：${playback['coverVisible'] == true ? '显示' : '隐藏'}',
      };
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(20),
        children: [
          Text('设备与画面状态', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text('有声音但没有画面时，可拍下此页用于排查。以下是打开面板时的状态。'),
          if (snapshot.connectionState != ConnectionState.done)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else if (device.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('设备信息暂不可用，仍可查看播放状态。'),
            ),
          const SizedBox(height: 8),
          for (final (index, row) in rows.entries.indexed)
            TelevisionFocusOutline(
              key: ValueKey('render-status-${row.key}'),
              child: Focus(
                autofocus: index == 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Text('${row.key}：${row.value}'),
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text('初始化和尺寸信息不能证明电视已显示视频。不包含播放地址、密钥或异常原文。'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => perform(context, () async {
              await Clipboard.setData(
                ClipboardData(
                  text: const JsonEncoder.withIndent(
                    '  ',
                  ).convert({'device': device, 'playback': playback}),
                ),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('状态已复制')));
              }
            }),
            icon: const Icon(Icons.copy),
            label: const Text('复制状态'),
          ),
        ],
      );
    },
  );
}
