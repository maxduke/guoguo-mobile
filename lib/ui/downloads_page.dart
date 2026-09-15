import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.onOpen,
  });
  final AppStore store;
  final DownloadStore downloads;
  final ValueChanged<Drama> onOpen;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DramaSource? _source;
  bool _completed = false, _selecting = false;
  final Set<String> _selected = {};
  Future<void> _remove(List<DownloadEntry> entries) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${entries.length} 个下载？'),
        content: const Text('将删除下载的视频文件，收藏与观看历史会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await perform(context, () async {
      for (final entry in entries) {
        await widget.downloads.remove(entry);
      }
    });
    if (mounted) {
      setState(() {
        _selected.clear();
        _selecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.downloads,
    builder: (context, _) {
      final entries = widget.downloads.entries
          .where(
            (e) =>
                e.complete == _completed &&
                (_source == null || e.drama.source == _source),
          )
          .toList();
      return RefreshIndicator(
        onRefresh: widget.downloads.reload,
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            Row(
              children: [
                Text(
                  '把好剧带在身边',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip: '批量管理',
                  onPressed: () => setState(() {
                    _selecting = !_selecting;
                    _selected.clear();
                  }),
                  icon: Icon(
                    _selecting ? Icons.close : Icons.checklist_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.store.cellularDownloads
                  ? '允许使用移动数据下载'
                  : '仅 Wi-Fi 下载 · 断网也能接着看',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SourceFilter(
              value: _source,
              onChanged: (value) => setState(() {
                _source = value;
                _selected.clear();
              }),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('下载中')),
                ButtonSegment(value: true, label: Text('已完成')),
              ],
              selected: {_completed},
              onSelectionChanged: (v) => setState(() {
                _completed = v.first;
                _selected.clear();
              }),
            ),
            const SizedBox(height: 16),
            if (_selecting)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => setState(
                      () => _selected.addAll(entries.map((e) => e.id)),
                    ),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => _remove(
                            entries
                                .where((e) => _selected.contains(e.id))
                                .toList(),
                          ),
                    child: Text('删除 (${_selected.length})'),
                  ),
                  if (!_completed)
                    TextButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => perform(context, () async {
                              for (final e in entries.where(
                                (e) =>
                                    _selected.contains(e.id) &&
                                    e.status == TaskStatus.running,
                              )) {
                                await widget.downloads.pause(e);
                              }
                            }),
                      child: const Text('暂停所选'),
                    ),
                ],
              ),
            if (widget.downloads.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(widget.downloads.error!),
              ),
            if (entries.isEmpty)
              const EmptyState(
                icon: Icons.download_for_offline_outlined,
                title: '为下一段旅途存好故事',
                message: '在短剧详情下载整部剧，或长按分集下载单集',
              ),
            for (final entry in entries)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      if (_selecting)
                        Checkbox(
                          value: _selected.contains(entry.id),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selected.add(entry.id);
                            } else {
                              _selected.remove(entry.id);
                            }
                          }),
                        ),
                      SizedBox(
                        width: 48,
                        height: 68,
                        child: Poster(entry.drama, radius: 9),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: InkWell(
                          onTap: entry.complete
                              ? () => widget.onOpen(entry.drama)
                              : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.drama.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                '${entry.drama.source.label} · 第 ${entry.episode.number} 集',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 7),
                              if (!entry.complete) ...[
                                LinearProgressIndicator(
                                  value: entry.progress,
                                  minHeight: 3,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                const SizedBox(height: 5),
                              ],
                              Text(
                                '${entry.label}${entry.complete ? '' : ' · ${(entry.progress * 100).round()}%'}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '管理下载',
                        onSelected: (v) => perform(context, () async {
                          switch (v) {
                            case 'pause':
                              await widget.downloads.pause(entry);
                            case 'resume':
                              await widget.downloads.resume(entry);
                            case 'retry':
                              await widget.downloads.retry(entry);
                            case 'delete':
                              await _remove([entry]);
                          }
                        }),
                        itemBuilder: (_) => [
                          if (entry.status == TaskStatus.running)
                            const PopupMenuItem(
                              value: 'pause',
                              child: Text('暂停'),
                            ),
                          if (entry.status == TaskStatus.paused)
                            const PopupMenuItem(
                              value: 'resume',
                              child: Text('恢复'),
                            ),
                          if (!entry.complete)
                            const PopupMenuItem(
                              value: 'retry',
                              child: Text('重新下载'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
