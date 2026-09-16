import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'player_page.dart';

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
  bool _completed = false, _selecting = false, _busy = false;
  bool _confirming = false;
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _completed =
        widget.downloads.entries.any((e) => e.complete) &&
        !widget.downloads.entries.any((e) => !e.complete);
  }

  void _toggle(DownloadEntry entry) => setState(() {
    _selecting = true;
    if (!_selected.add(entry.id)) _selected.remove(entry.id);
  });

  Future<void> _remove(List<DownloadEntry> entries) async {
    if (_busy || entries.isEmpty) return;
    setState(() {
      _busy = true;
      _confirming = true;
    });
    try {
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
      setState(() => _confirming = false);
      await _apply(entries, widget.downloads.remove);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
      }
    }
  }

  Future<void> _apply(
    List<DownloadEntry> entries,
    Future<void> Function(DownloadEntry) action,
  ) async {
    var failures = 0;
    for (final entry in entries) {
      try {
        await action(entry);
        _selected.remove(entry.id);
      } catch (_) {
        failures++;
      }
    }
    if (!mounted) return;
    setState(() {});
    if (failures > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$failures 个任务未能操作，请稍后重试（整理中的视频需等待完成）')),
      );
    }
  }

  Future<void> _batch(
    List<DownloadEntry> entries,
    Future<void> Function(DownloadEntry) action,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _apply(entries, action);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(DownloadEntry entry) async {
    await perform(context, () async {
      if (await widget.downloads.localFile(entry.drama, entry.episode) ==
          null) {
        await widget.downloads.reload();
        throw StateError('视频文件已不存在，请重新下载');
      }
      // Only queue downloaded episodes, so swiping never unexpectedly uses data.
      final queue =
          widget.downloads.entries
              .where((e) => e.complete && e.drama.key == entry.drama.key)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      final index = queue.indexWhere((e) => e.id == entry.id);
      if (!mounted || index < 0) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            store: widget.store,
            downloads: widget.downloads,
            drama: entry.drama,
            episodes: queue.map((e) => e.episode).toList(),
            initialIndex: index,
            episodeIndices: queue.map((e) => e.index).toList(),
            localOnly: true,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.downloads, widget.store]),
    builder: (context, _) {
      final sourceEntries = widget.downloads.entries
          .where((e) => _source == null || e.drama.source == _source)
          .toList();
      final entries = sourceEntries
          .where((e) => e.complete == _completed)
          .toList();
      _selected.retainAll(entries.map((e) => e.id));
      final chosen = entries.where((e) => _selected.contains(e.id)).toList();
      final groups = <String, List<DownloadEntry>>{};
      for (final entry in entries) {
        groups.putIfAbsent(entry.drama.key, () => []).add(entry);
      }
      final items = <Object>[];
      for (final group in groups.entries) {
        final episodes = group.value
          ..sort((a, b) => a.index.compareTo(b.index));
        items.add(episodes);
        if (!_collapsed.contains(group.key)) items.addAll(episodes);
      }
      return RefreshIndicator(
        onRefresh: widget.downloads.reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverList.list(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '下载管理',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _selecting = !_selecting;
                                _selected.clear();
                              }),
                        icon: Icon(
                          _selecting ? Icons.close : Icons.checklist_rounded,
                        ),
                        label: Text(_selecting ? '完成' : '多选'),
                      ),
                    ],
                  ),
                  Text(
                    widget.store.cellularDownloads
                        ? '允许移动数据下载 · 已完成视频可离线观看'
                        : '仅 Wi-Fi 下载 · 已完成视频可离线观看',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  SourceFilter(
                    value: _source,
                    onChanged: _busy
                        ? (_) {}
                        : (v) => setState(() {
                            _source = v;
                            _selected.clear();
                          }),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: Text(
                          '下载中 ${sourceEntries.where((e) => !e.complete).length}',
                        ),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text(
                          '已完成 ${sourceEntries.where((e) => e.complete).length}',
                        ),
                      ),
                    ],
                    selected: {_completed},
                    onSelectionChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _completed = v.first;
                            _selected.clear();
                          }),
                  ),
                  if (_selecting)
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy || entries.isEmpty
                              ? null
                              : () => setState(() {
                                  if (_selected.length == entries.length) {
                                    _selected.clear();
                                  } else {
                                    _selected.addAll(entries.map((e) => e.id));
                                  }
                                }),
                          child: Text(
                            _selected.length == entries.length &&
                                    entries.isNotEmpty
                                ? '取消全选'
                                : '全选',
                          ),
                        ),
                        TextButton(
                          onPressed: _busy || chosen.isEmpty
                              ? null
                              : () => _remove(chosen),
                          child: Text('删除 (${chosen.length})'),
                        ),
                        if (!_completed) ...[
                          TextButton(
                            onPressed: _busy || chosen.isEmpty
                                ? null
                                : () => _batch(
                                    chosen
                                        .where(
                                          (e) =>
                                              !e.processing &&
                                              !e.userPaused &&
                                              e.status != TaskStatus.failed,
                                        )
                                        .toList(),
                                    widget.downloads.pause,
                                  ),
                            child: const Text('暂停'),
                          ),
                          TextButton(
                            onPressed: _busy || chosen.isEmpty
                                ? null
                                : () => _batch(
                                    chosen.where((e) => e.userPaused).toList(),
                                    widget.downloads.resume,
                                  ),
                            child: const Text('恢复'),
                          ),
                          TextButton(
                            onPressed: _busy || chosen.isEmpty
                                ? null
                                : () => _batch(
                                    chosen
                                        .where(
                                          (e) => e.status == TaskStatus.failed,
                                        )
                                        .toList(),
                                    widget.downloads.retry,
                                  ),
                            child: const Text('重试'),
                          ),
                        ],
                      ],
                    ),
                  if (_busy && !_confirming) const LinearProgressIndicator(),
                  if (widget.downloads.error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(widget.downloads.error!),
                    ),
                  if (entries.isEmpty)
                    EmptyState(
                      icon: Icons.download_for_offline_outlined,
                      title: _completed ? '还没有已完成的视频' : '暂无下载任务',
                      message: '在短剧详情下载整部剧，或长按分集下载单集',
                    ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList.builder(
                itemCount: items.length,
                itemBuilder: (_, index) => switch (items[index]) {
                  final DownloadEntry entry => _entry(entry),
                  final List<DownloadEntry> episodes => _group(episodes),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _group(List<DownloadEntry> episodes) {
    final drama = episodes.first.drama;
    final collapsed = _collapsed.contains(drama.key);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _selecting
          ? Checkbox(
              tristate: true,
              value: episodes.every((e) => _selected.contains(e.id))
                  ? true
                  : episodes.any((e) => _selected.contains(e.id))
                  ? null
                  : false,
              onChanged: _busy
                  ? null
                  : (_) => setState(() {
                      if (episodes.every((e) => _selected.contains(e.id))) {
                        _selected.removeAll(episodes.map((e) => e.id));
                      } else {
                        _selected.addAll(episodes.map((e) => e.id));
                      }
                    }),
            )
          : null,
      title: Text(
        drama.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text('${drama.source.label} · ${episodes.length} 集'),
      trailing: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
      onTap: () => setState(() {
        if (!_collapsed.add(drama.key)) _collapsed.remove(drama.key);
      }),
      onLongPress: () => widget.onOpen(drama),
    );
  }

  Widget _entry(DownloadEntry entry) => Dismissible(
    key: ValueKey(entry.id),
    direction: _selecting || _busy || entry.processing
        ? DismissDirection.none
        : DismissDirection.endToStart,
    confirmDismiss: (_) async {
      await _remove([entry]);
      return false;
    },
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        Icons.delete_outline,
        color: Theme.of(context).colorScheme.onErrorContainer,
      ),
    ),
    child: Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: _busy ? null : () => _toggle(entry),
        onTap: _busy
            ? null
            : _selecting
            ? () => _toggle(entry)
            : entry.complete
            ? () => _play(entry)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              if (_selecting)
                Checkbox(
                  value: _selected.contains(entry.id),
                  onChanged: _busy ? null : (_) => _toggle(entry),
                ),
              SizedBox(
                width: 60,
                height: 80,
                child: Poster(entry.drama, radius: 8),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第 ${entry.episode.number} 集',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      entry.complete ? '已下载 · 点击播放' : entry.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (!entry.complete) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: entry.processing
                            ? null
                            : entry.progress.clamp(0, 1),
                        minHeight: 3,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${(entry.progress.clamp(0, 1) * 100).round()}%',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ],
                ),
              ),
              if (!_selecting) ...[
                if (entry.complete)
                  IconButton(
                    tooltip: '播放第 ${entry.episode.number} 集',
                    onPressed: _busy ? null : () => _play(entry),
                    icon: const Icon(Icons.play_circle_fill_rounded),
                  ),
                PopupMenuButton<String>(
                  tooltip: '管理下载',
                  enabled: !_busy && !entry.processing,
                  onSelected: (v) {
                    if (v == 'delete') {
                      _remove([entry]);
                      return;
                    }
                    _batch(
                      [entry],
                      switch (v) {
                        'pause' => widget.downloads.pause,
                        'resume' => widget.downloads.resume,
                        _ => widget.downloads.retry,
                      },
                    );
                  },
                  itemBuilder: (_) => [
                    if (!entry.complete &&
                        !entry.userPaused &&
                        entry.status != TaskStatus.failed)
                      const PopupMenuItem(value: 'pause', child: Text('暂停')),
                    if (entry.userPaused)
                      const PopupMenuItem(value: 'resume', child: Text('恢复')),
                    if (entry.status == TaskStatus.failed)
                      const PopupMenuItem(value: 'retry', child: Text('重新下载')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
