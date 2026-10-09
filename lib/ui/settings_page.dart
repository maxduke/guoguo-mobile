import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/app_store.dart';
import '../data/library_exchange.dart';
import '../data/download_store.dart';
import '../domain/user_input_exception.dart';
import 'components.dart';
import 'playback_diagnostics_page.dart';
import 'storage_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store, required this.downloads});
  final AppStore store;
  final DownloadStore downloads;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppStore get store => widget.store;
  DownloadStore get downloads => widget.downloads;
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  @override
  void initState() {
    super.initState();
    unawaited(downloads.refreshUsage());
  }

  bool _backingUp = false;
  bool _exchangingLibrary = false;
  bool get _fileBusy => _backingUp || _exchangingLibrary;

  Future<void> _backup(BuildContext context, {required bool importing}) async {
    if (_fileBusy) return;
    setState(() => _backingUp = true);
    try {
      if (importing) {
        await _import(context);
      } else {
        await _export(context);
      }
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _export(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : box.localToGlobal(Offset.zero) & box.size;
    final directory = await getTemporaryDirectory();
    if (!context.mounted) return;
    final file = File('${directory.path}/guoguo-records.json');
    await file.writeAsString(store.records.exportBackup(), flush: true);
    if (!context.mounted) return;
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
    if (selected == null || !context.mounted) return;
    final length = await selected.length();
    if (length == null || length > 20 * 1024 * 1024) {
      throw const UserInputException('备份文件超过 20 MB 或无法读取大小');
    }
    final bytes = await selected.readAsBytes();
    if (!context.mounted) return;
    final String raw;
    try {
      raw = utf8.decode(bytes);
    } on FormatException {
      throw const UserInputException('备份损坏或格式不兼容，原记录未修改');
    }
    final backup = store.records.inspectBackup(raw);
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('合并记录备份'),
        scrollable: true,
        content: Text(
          '备份包含 ${backup.favorites.length} 部收藏、${backup.history.length} 条观看记录、${backup.seasonReminders.length} 项新季提醒。\n\n收藏会去重，观看记录与新季提醒保留时间较新的一份。现有视频不会改变。',
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
    if (confirmed == true && context.mounted) {
      await store.records.importBackup(backup);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('记录已合并')));
      }
    }
  }

  Future<void> _library(BuildContext context, {required bool importing}) async {
    if (_fileBusy) return;
    setState(() => _exchangingLibrary = true);
    final exchange = LibraryExchange(store);
    File? copied;
    try {
      final directory = await getTemporaryDirectory();
      if (!context.mounted) return;
      if (importing) {
        final selected = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['json', 'xz'],
        );
        if (selected == null || !context.mounted) return;
        final length = await selected.length();
        if (length == null || length > LibraryExchange.maxBytes) {
          throw const UserInputException('剧库文件超过 32 MB 或无法读取');
        }
        copied = File(
          '${directory.path}/.guoguo-import-${DateTime.now().microsecondsSinceEpoch}',
        );
        final sink = copied.openWrite();
        var copiedBytes = 0;
        try {
          await for (final chunk in selected.readAsByteStream()) {
            copiedBytes += chunk.length;
            if (copiedBytes > LibraryExchange.maxBytes) {
              throw const UserInputException('剧库文件超过 32 MB');
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        final preview = await exchange.inspect(copied);
        if (!context.mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('合并剧库'),
            scrollable: true,
            content: Text(
              '可导入 ${preview.items.length} 部剧集；跳过 ${preview.skipped} 条不支持站源和 ${preview.rejected} 条无效记录。\n\n按剧集身份补全资料，保留现有条目，不包含视频文件。',
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
        if (confirmed != true || !context.mounted) return;
        final result = await exchange.merge(preview);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '新增 ${result['imported']} 部，合并 ${result['merged']} 部',
              ),
            ),
          );
        }
      } else {
        final file = await exchange.export(directory);
        if (!context.mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        final origin = box == null
            ? const Rect.fromLTWH(0, 0, 1, 1)
            : box.localToGlobal(Offset.zero) & box.size;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'application/x-xz')],
            subject: '果果剧库',
            sharePositionOrigin: origin,
          ),
        );
      }
    } finally {
      try {
        if (copied != null && await copied.exists()) await copied.delete();
      } finally {
        if (mounted) setState(() => _exchangingLibrary = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.preferences,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              _heading(context, '外观'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in [
                        ThemeMode.light,
                        ThemeMode.dark,
                        ThemeMode.system,
                      ])
                        ChoiceChip(
                          label: Text(switch (mode) {
                            ThemeMode.light => '浅色',
                            ThemeMode.dark => '深色',
                            ThemeMode.system => '跟随系统',
                          }),
                          selected: store.preferences.themeMode == mode,
                          onSelected: (selected) {
                            if (selected) {
                              perform(
                                context,
                                () => store.preferences.setTheme(mode),
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _heading(context, '播放与网络'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('自动播放下一集'),
                      subtitle: const Text('关闭后，播完停在当前集'),
                      value: store.preferences.autoAdvance,
                      onChanged: (v) => perform(
                        context,
                        () => store.preferences.setPlayback(advance: v),
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('预缓冲下一集'),
                      subtitle: const Text('当前集播放顺畅后再准备下一集'),
                      value: store.preferences.prefetch,
                      onChanged: (v) => perform(
                        context,
                        () => store.preferences.setPrefetch(v),
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('使用移动数据预缓冲'),
                      subtitle: const Text('默认只在 Wi-Fi 下预缓冲'),
                      value: store.preferences.cellularPrefetch,
                      onChanged: (v) => perform(
                        context,
                        () => store.preferences.setNetwork(preload: v),
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('使用移动数据下载'),
                      subtitle: const Text('更改后同时更新已有任务的网络要求'),
                      value: store.preferences.cellularDownloads,
                      onChanged: (v) =>
                          perform(context, () => downloads.setCellular(v)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _heading(context, '存储'),
              Card(
                child: ListenableBuilder(
                  listenable: downloads,
                  builder: (context, _) {
                    final bytes = downloads.manifestLoaded
                        ? downloads.bytesFor(downloads.entries)
                        : null;
                    return ListTile(
                      leading: const Icon(Icons.storage_outlined),
                      title: const Text('存储管理'),
                      subtitle: Text(
                        bytes == null
                            ? '查看下载与缓存占用，按需清理'
                            : '${formatDownloadBytes(bytes)} 下载 · 查看缓存与清理',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              StoragePage(store: store, downloads: downloads),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              _heading(context, '记录备份'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.ios_share),
                      title: const Text('导出记录备份'),
                      subtitle: const Text('收藏、观看历史和新季提醒，不含视频文件'),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: !_fileBusy,
                      onTap: () => perform(
                        context,
                        () => _backup(context, importing: false),
                        failureMessage: '备份导出失败，请检查可用空间后重试',
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.restore_page_outlined),
                      title: const Text('导入记录备份'),
                      subtitle: const Text('先预览，再合并到当前设备'),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: !_fileBusy,
                      onTap: () => perform(
                        context,
                        () => _backup(context, importing: true),
                        failureMessage: '备份导入失败，原记录未修改，请稍后重试',
                      ),
                    ),
                    if (_backingUp) const LinearProgressIndicator(),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _heading(context, '关于与支持'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.speed_rounded),
                  title: const Text('问题反馈与诊断'),
                  subtitle: const Text('复制播放诊断，用于反馈问题'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PlaybackDiagnosticsPage(store: store),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snapshot) => Text(
                    snapshot.hasData
                        ? '果果 · ${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                        : snapshot.hasError
                        ? '果果 · 版本信息暂不可用'
                        : '果果 · 正在读取版本',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.8,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: ExpansionTile(
                  title: const Text('高级工具'),
                  subtitle: const Text('播放实验与剧库互通'),
                  leading: const Icon(Icons.handyman_outlined),
                  children: [
                    SwitchListTile(
                      title: const Text('提前开播（实验）'),
                      subtitle: const Text(
                        '从头看部分视频时可边准备边播，缓冲范围逐步增加。续播、手动画中画和投屏等待完整准备。',
                      ),
                      value: store.preferences.progressivePreparation,
                      onChanged: (value) => perform(
                        context,
                        () => store.preferences.setPlayback(progressive: value),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.library_add_outlined),
                      title: const Text('导入剧库 JSON / XZ'),
                      subtitle: const Text('先预览，再补全现有剧集资料'),
                      enabled: !_fileBusy,
                      onTap: () => perform(
                        context,
                        () => _library(context, importing: true),
                        failureMessage: '剧库导入失败，请检查文件后重试',
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.ios_share),
                      title: const Text('导出剧库 XZ'),
                      subtitle: const Text('供果果与真果·鉴互通，不包含视频'),
                      enabled: !_fileBusy,
                      onTap: () => perform(
                        context,
                        () => _library(context, importing: false),
                        failureMessage: '剧库导出失败，请检查可用空间后重试',
                      ),
                    ),
                    if (_exchangingLibrary) const LinearProgressIndicator(),
                  ],
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
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}
