import 'package:flutter/material.dart';

import '../data/record_store.dart';
import '../domain/models.dart';
import 'components.dart';

Future<void> toggleFavoriteWithUndo(
  BuildContext context,
  RecordStore records,
  Drama drama,
) => perform(context, () async {
  final previous = records.favorites[drama.key];
  await records.toggleFavorite(drama);
  if (context.mounted && previous != null) {
    _offerUndo(
      context,
      '已取消收藏：${previous.title}',
      () => records.restoreFavorite(previous),
    );
  }
});

Future<void> removeHistoryWithUndo(
  BuildContext context,
  RecordStore records,
  WatchRecord record,
) => perform(context, () async {
  await records.removeHistory(record.drama.key);
  if (context.mounted) {
    _offerUndo(
      context,
      '已删除历史：${record.drama.title}',
      () => records.restoreHistory(record),
    );
  }
});

void _offerUndo(
  BuildContext context,
  String message,
  Future<void> Function() undo,
) {
  final messenger = ScaffoldMessenger.of(context);
  Future<void> restore() async {
    try {
      await undo();
    } catch (_) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: const Text('撤销未完成，请检查设备空间后重试'),
            action: SnackBarAction(label: '重试', onPressed: restore),
          ),
        );
      }
    }
  }

  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(label: '撤销', onPressed: restore),
    ),
  );
}
