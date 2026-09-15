import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import 'components.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.store, required this.downloads});
  final AppStore store;
  final DownloadStore downloads;
  Future<void> _export(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/guoguo-records.json');
    await file.writeAsString(store.exportBackup(), flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: '果果收藏与观看记录',
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (selected == null) return;
    final length = await selected.length();
    if (length == null || length > 20 * 1024 * 1024) {
      throw const FormatException('备份文件超过 20 MB 或无法读取大小');
    }
    final raw = utf8.decode(await selected.readAsBytes());
    final backup = store.inspectBackup(raw);
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('合并记录备份'),
        content: Text(
          '备份包含 ${backup.favorites.length} 部收藏、${backup.history.length} 条观看记录。\n\n收藏会去重，观看记录保留观看时间较新的一条。现有视频不会改变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并导入'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await store.importBackup(backup);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('记录已合并')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              _heading(context, '舒服地看'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('外观'),
                      const SizedBox(height: 14),
                      SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_outlined),
                            label: Text('浅色'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_outlined),
                            label: Text('深色'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('跟随系统'),
                          ),
                        ],
                        selected: {store.themeMode},
                        onSelectionChanged: (v) =>
                            perform(context, () => store.setTheme(v.first)),
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('预缓冲下一集'),
                      subtitle: const Text('临近结束时准备下一集，减少等待'),
                      value: store.prefetch,
                      onChanged: (v) =>
                          perform(context, () => store.setPrefetch(v)),
                    ),
                    SwitchListTile(
                      title: const Text('使用移动数据预缓冲'),
                      subtitle: const Text('默认只在 Wi-Fi 下预缓冲'),
                      value: store.cellularPrefetch,
                      onChanged: (v) =>
                          perform(context, () => store.setNetwork(preload: v)),
                    ),
                    SwitchListTile(
                      title: const Text('使用移动数据下载'),
                      subtitle: const Text('更改后同时更新已有任务的网络要求'),
                      value: store.cellularDownloads,
                      onChanged: (v) =>
                          perform(context, () => downloads.setCellular(v)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _heading(context, '把喜欢的故事带走'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.ios_share),
                      title: const Text('导出记录备份'),
                      subtitle: const Text('收藏与观看历史，不包含视频文件'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => perform(context, () => _export(context)),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.restore_page_outlined),
                      title: const Text('导入记录备份'),
                      subtitle: const Text('先预览，再合并到当前设备'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => perform(context, () => _import(context)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _heading(context, '设备空间'),
              Card(
                child: Column(
                  children: [
                    FutureBuilder<int>(
                      future: downloads.usedBytes(),
                      builder: (context, snapshot) => ListTile(
                        leading: const Icon(Icons.storage_outlined),
                        title: const Text('已下载视频'),
                        subtitle: Text(
                          snapshot.hasData
                              ? '${(snapshot.data! / 1024 / 1024).toStringAsFixed(1)} MB · 在下载页管理'
                              : '正在统计',
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined),
                      title: const Text('清理封面缓存'),
                      subtitle: const Text('收藏、历史和已下载视频会保留'),
                      onTap: () => perform(context, () async {
                        await DefaultCacheManager().emptyCache();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('封面缓存已清理')),
                          );
                        }
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  '果果 · 0.1.0\n好故事，接着看',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.8,
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _heading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 10),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
