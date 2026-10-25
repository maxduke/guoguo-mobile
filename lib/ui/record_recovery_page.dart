import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/startup_record_recovery.dart';
import '../domain/models.dart';
import '../domain/user_input_exception.dart';
import 'record_backup_picker.dart';

class RecordRecoveryPage extends StatefulWidget {
  const RecordRecoveryPage({
    super.key,
    required this.recovery,
    this.selectBackup = pickRecordBackup,
    this.shareOriginal = shareOriginalRecords,
  });
  final StartupRecordRecovery recovery;
  final Future<RecordBackup?> Function() selectBackup;
  final Future<void> Function(BuildContext, File) shareOriginal;
  @override
  State<RecordRecoveryPage> createState() => _RecordRecoveryPageState();
}

class _RecordRecoveryPageState extends State<RecordRecoveryPage> {
  bool _busy = false;
  bool _confirming = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is UserInputException
              ? error.message
              : '恢复操作未完成，请检查设备空间与文件权限后重试。原文件仍会保留。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore({required bool fresh}) => _run(() async {
    final backup = fresh ? null : await widget.selectBackup();
    if (!mounted || (!fresh && backup == null)) return;
    setState(() => _confirming = true);
    final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(fresh ? '重新建立记录' : '从备份恢复记录'),
          content: Text(
            fresh
                ? '将重新建立收藏、观看记录、新季提醒与偏好设置。原记录文件会先保留，已下载视频不受影响。'
                : '备份包含 ${backup!.favorites.length} 部收藏、${backup.history.length} 条观看记录、${backup.seasonReminders.length} 项新季提醒。\n\n将用这份备份恢复记录，并重新建立偏好设置。原记录文件会先保留，已下载视频不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(fresh ? '保留原文件并重新建立' : '保留原文件并恢复'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (!mounted || confirmed != true) return;
    if (fresh) {
      await widget.recovery.startFresh();
    } else {
      await widget.recovery.restore(backup!);
    }
    if (mounted) Navigator.pop(context, true);
  });

  Future<void> _export() => _run(() async {
    final original = await widget.recovery.preserve();
    if (mounted) await widget.shareOriginal(context, original);
  });

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('记录恢复')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('原记录文件尚未改动。可以先导出原文件，或从果果记录备份恢复。恢复前会在本机保留一份原文件。'),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => unawaited(_export()),
              icon: const Icon(Icons.ios_share),
              label: const Text('导出原记录文件'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_restore(fresh: false)),
              child: const Text('选择记录备份'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : () => unawaited(_restore(fresh: true)),
              child: const Text('保留原文件，重新建立记录'),
            ),
            if (_busy && !_confirming)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> shareOriginalRecords(BuildContext context, File file) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null
      ? const Rect.fromLTWH(0, 0, 1, 1)
      : box.localToGlobal(Offset.zero) & box.size;
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/octet-stream')],
      subject: '果果原记录文件',
      sharePositionOrigin: origin,
    ),
  );
}
