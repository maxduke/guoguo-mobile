import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'player_page.dart';

enum _TaskFilter { all, pending, complete, failed, paused }

enum _Sort { recent, largest, title }

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
  String? _focusedDrama;
  bool _space = false, _selecting = false, _busy = false, _confirming = false;
  _TaskFilter _filter = _TaskFilter.pending;
  _Sort _sort = _Sort.recent;
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    if (widget.downloads.entries.isNotEmpty &&
        widget.downloads.entries.every((e) => e.complete)) {
      _filter = _TaskFilter.complete;
    }
    unawaited(widget.downloads.refreshUsage());
  }

  bool _matches(DownloadEntry entry, _TaskFilter filter) => switch (filter) {
    _TaskFilter.all => true,
    _TaskFilter.pending => !entry.complete,
    _TaskFilter.complete => entry.complete,
    _TaskFilter.failed => entry.canRetry,
    _TaskFilter.paused => entry.canResume,
  };

  void _toggle(DownloadEntry entry) => setState(() {
    _selecting = true;
    if (!_selected.add(entry.id)) _selected.remove(entry.id);
  });

  void _toggleGroup(List<DownloadEntry> entries) => setState(() {
    _selecting = true;
    if (entries.every((e) => _selected.contains(e.id))) {
      _selected.removeAll(entries.map((e) => e.id));
    } else {
      _selected.addAll(entries.map((e) => e.id));
    }
  });

  String _size(Iterable<DownloadEntry> entries) {
    final bytes = widget.downloads.bytesFor(entries);
    return bytes == null ? '待统计' : formatDownloadBytes(bytes);
  }

  Future<void> _remove(List<DownloadEntry> entries) async {
    if (_busy || entries.isEmpty) return;
    setState(() {
      _busy = true;
      _confirming = true;
    });
    try {
      final dramas = entries.map((e) => e.drama.key).toSet().length;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除 ${entries.length} 个下载？'),
          content: Text(
            '涉及 $dramas 部剧、${entries.length} 集，已保存文件占用 ${_size(entries)}。\n\n下载会先停止，再删除文件。收藏与观看历史会保留。',
          ),
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
      await _apply(entries, widget.downloads.remove, '删除');
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
    String label,
  ) async {
    var succeeded = 0;
    final failures = <DownloadEntry>[];
    for (final entry in entries) {
      try {
        await action(entry);
        succeeded++;
        _selected.remove(entry.id);
      } catch (_) {
        failures.add(entry);
      }
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failures.isEmpty
              ? '已$label $succeeded 个任务'
              : '$succeeded 个已$label，${failures.length} 个未完成。${failures.first.processing ? '整理中的视频请稍后再操作' : '未完成的任务已保留，请检查状态后重试'}',
        ),
      ),
    );
  }

  Future<void> _batch(
    List<DownloadEntry> entries,
    Future<void> Function(DownloadEntry) action,
    String label,
  ) async {
    if (_busy || entries.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _apply(entries, action, label);
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
      final scoped = sourceEntries
          .where(
            (e) =>
                _space || _focusedDrama == null || e.drama.key == _focusedDrama,
          )
          .toList();
      final entries = scoped
          .where((e) => _space || _matches(e, _filter))
          .toList();
      _selected.retainAll(entries.map((e) => e.id));
      final chosen = entries.where((e) => _selected.contains(e.id)).toList();
      final byDrama = <String, List<DownloadEntry>>{};
      for (final entry in entries) {
        byDrama.putIfAbsent(entry.drama.key, () => []).add(entry);
      }
      final groups = byDrama.values.toList();
      groups.sort((a, b) {
        final order = switch (_sort) {
          _Sort.largest => (widget.downloads.bytesFor(b) ?? -1).compareTo(
            widget.downloads.bytesFor(a) ?? -1,
          ),
          _Sort.title => a.first.drama.title.compareTo(b.first.drama.title),
          _Sort.recent =>
            b
                .map((e) => e.id)
                .reduce((a, b) => a.compareTo(b) > 0 ? a : b)
                .compareTo(
                  a
                      .map((e) => e.id)
                      .reduce((a, b) => a.compareTo(b) > 0 ? a : b),
                ),
        };
        return order != 0
            ? order
            : a.first.drama.key.compareTo(b.first.drama.key);
      });
      final items = <Object>[];
      for (final group in groups) {
        group.sort((a, b) => a.index.compareTo(b.index));
        items.add(group);
        if (!_space && !_collapsed.contains(group.first.drama.key)) {
          items.addAll(group);
        }
      }
      final retryable = entries.where((e) => e.canRetry).toList();
      return RefreshIndicator(
        onRefresh: () async {
          await widget.downloads.reload();
        },
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
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('下载任务')),
                      ButtonSegment(value: true, label: Text('按剧空间')),
                    ],
                    selected: {_space},
                    onSelectionChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _space = value.first;
                            _focusedDrama = null;
                            _selected.clear();
                            _sort = _space ? _Sort.largest : _Sort.recent;
                            if (_space) {
                              unawaited(widget.downloads.refreshUsage());
                            }
                          }),
                  ),
                  const SizedBox(height: 12),
                  SourceFilter(
                    value: _source,
                    onChanged: _busy
                        ? (_) {}
                        : (value) => setState(() {
                            _source = value;
                            _focusedDrama = null;
                            _selected.clear();
                          }),
                  ),
                  if (_space) ...[
                    const SizedBox(height: 8),
                    Card(
                      margin: EdgeInsets.zero,
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('已保存文件占用'),
                            const SizedBox(height: 4),
                            Text(
                              _size(sourceEntries),
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${groups.length} 部剧 · ${sourceEntries.where((e) => e.complete).length} 集已完成 / ${sourceEntries.length} 集任务',
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '包含视频与已保存的临时文件；系统下载临时文件不计入。下拉可更新占用。',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.store.cellularDownloads
                          ? '允许移动数据下载'
                          : '仅 Wi-Fi 下载 · 无 Wi-Fi 时任务等待网络',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final filter in _TaskFilter.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  '${switch (filter) {
                                    _TaskFilter.all => '全部',
                                    _TaskFilter.pending => '未完成',
                                    _TaskFilter.complete => '已完成',
                                    _TaskFilter.failed => '失败',
                                    _TaskFilter.paused => '暂停',
                                  }} ${scoped.where((e) => _matches(e, filter)).length}',
                                ),
                                selected: _filter == filter,
                                onSelected: _busy
                                    ? null
                                    : (_) => setState(() {
                                        _filter = filter;
                                        _selected.clear();
                                      }),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_focusedDrama != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ActionChip(
                          label: const Text('正在查看单部剧 · 显示全部'),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _focusedDrama = null;
                                  _selected.clear();
                                }),
                        ),
                      ),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selecting
                              ? '已选 ${chosen.length} 集 · ${_size(chosen)}'
                              : '${groups.length} 部剧',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      PopupMenuButton<_Sort>(
                        tooltip: '排序',
                        enabled: !_busy,
                        initialValue: _sort,
                        onSelected: (value) => setState(() => _sort = value),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _Sort.largest,
                            child: Text('占用从大到小'),
                          ),
                          PopupMenuItem(
                            value: _Sort.recent,
                            child: Text('最近添加'),
                          ),
                          PopupMenuItem(
                            value: _Sort.title,
                            child: Text('剧名排序'),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(switch (_sort) {
                                _Sort.largest => '占用从大到小',
                                _Sort.recent => '最近添加',
                                _Sort.title => '剧名排序',
                              }),
                              const Icon(Icons.arrow_drop_down),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_selecting) _selectionActions(entries, chosen),
                  if (!_selecting && !_space && retryable.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _batch(
                                retryable,
                                widget.downloads.retry,
                                '重试',
                              ),
                        icon: const Icon(Icons.refresh),
                        label: Text('重试失败任务 (${retryable.length})'),
                      ),
                    ),
                  if ((_busy && !_confirming) ||
                      widget.downloads.measuringUsage)
                    const LinearProgressIndicator(),
                  if (widget.downloads.error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(widget.downloads.error!),
                    ),
                  if (widget.downloads.usageError != null && _space)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(widget.downloads.usageError!),
                    ),
                  if (entries.isEmpty)
                    EmptyState(
                      icon: Icons.download_for_offline_outlined,
                      title: _space
                          ? '还没有下载文件'
                          : switch (_filter) {
                              _TaskFilter.complete => '还没有已完成的视频',
                              _TaskFilter.failed => '没有失败任务',
                              _TaskFilter.paused => '没有暂停任务',
                              _ => '暂无下载任务',
                            },
                      message: '在短剧详情选择需要下载的集数',
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
                  final List<DownloadEntry> episodes =>
                    _space ? _storageGroup(episodes) : _group(episodes),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _selectionActions(
    List<DownloadEntry> entries,
    List<DownloadEntry> chosen,
  ) {
    final pausable = chosen.where((e) => e.canPause).toList();
    final resumable = chosen.where((e) => e.canResume).toList();
    final retryable = chosen.where((e) => e.canRetry).toList();
    return Wrap(
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
            _selected.length == entries.length && entries.isNotEmpty
                ? '取消全选'
                : '全选',
          ),
        ),
        TextButton(
          onPressed: _busy || chosen.isEmpty ? null : () => _remove(chosen),
          child: Text('删除 (${chosen.length})'),
        ),
        if (!_space) ...[
          TextButton(
            onPressed: _busy || pausable.isEmpty
                ? null
                : () => _batch(pausable, widget.downloads.pause, '暂停'),
            child: Text('暂停 (${pausable.length})'),
          ),
          TextButton(
            onPressed: _busy || resumable.isEmpty
                ? null
                : () => _batch(resumable, widget.downloads.resume, '恢复'),
            child: Text('恢复 (${resumable.length})'),
          ),
          TextButton(
            onPressed: _busy || retryable.isEmpty
                ? null
                : () => _batch(retryable, widget.downloads.retry, '重试'),
            child: Text('重试 (${retryable.length})'),
          ),
        ],
      ],
    );
  }

  Widget _groupCheckbox(List<DownloadEntry> episodes) => Checkbox(
    tristate: true,
    value: episodes.every((e) => _selected.contains(e.id))
        ? true
        : episodes.any((e) => _selected.contains(e.id))
        ? null
        : false,
    onChanged: _busy ? null : (_) => _toggleGroup(episodes),
  );

  Widget _storageGroup(List<DownloadEntry> episodes) {
    final drama = episodes.first.drama;
    return Card(
      key: ValueKey('storage-${drama.key}'),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: _busy ? null : () => _toggleGroup(episodes),
        onTap: _busy
            ? null
            : () {
                if (_selecting) {
                  _toggleGroup(episodes);
                } else {
                  setState(() {
                    _space = false;
                    _focusedDrama = drama.key;
                    _filter = _TaskFilter.all;
                  });
                }
              },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (_selecting) _groupCheckbox(episodes),
              SizedBox(width: 54, height: 76, child: Poster(drama, radius: 8)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${drama.source.label} · 已完成 ${episodes.where((e) => e.complete).length}/${episodes.length} 集',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _size(episodes),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!_selecting)
                IconButton(
                  tooltip: '删除整部剧下载',
                  onPressed: _busy ? null : () => _remove(episodes),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _group(List<DownloadEntry> episodes) {
    final drama = episodes.first.drama;
    final collapsed = _collapsed.contains(drama.key);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _selecting ? _groupCheckbox(episodes) : null,
      title: Text(
        drama.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '${drama.source.label} · ${episodes.length} 集 · ${_size(episodes)}',
      ),
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
                width: 52,
                height: 72,
                child: Poster(entry.drama, radius: 8),
              ),
              const SizedBox(width: 10),
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
                      entry.complete ? '已下载 · 点击播放' : entry.phase.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: entry.canRetry
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    if (entry.failure != null && !entry.complete)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          entry.failure!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
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
                        entry.awaitingProcessing
                            ? '下载完成，整理后可播放'
                            : '${(entry.progress.clamp(0, 1) * 100).round()}%${entry.totalBytes == null ? '' : ' · ${formatDownloadBytes(entry.downloadedBytes)} / ${formatDownloadBytes(entry.totalBytes!)}'}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ] else
                      Text(
                        _size([entry]),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                ),
              ),
              if (!_selecting)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (entry.complete)
                      IconButton(
                        tooltip: '播放第 ${entry.episode.number} 集',
                        onPressed: _busy ? null : () => _play(entry),
                        icon: const Icon(Icons.play_circle_fill_rounded),
                      )
                    else if (entry.canRetry)
                      IconButton(
                        tooltip: '重试第 ${entry.episode.number} 集',
                        onPressed: _busy
                            ? null
                            : () =>
                                  _batch([entry], widget.downloads.retry, '重试'),
                        icon: const Icon(Icons.refresh),
                      ),
                    PopupMenuButton<String>(
                      tooltip: '管理下载',
                      enabled: !_busy && !entry.processing,
                      onSelected: (value) {
                        switch (value) {
                          case 'delete':
                            _remove([entry]);
                          case 'pause':
                            _batch([entry], widget.downloads.pause, '暂停');
                          case 'resume':
                            _batch([entry], widget.downloads.resume, '恢复');
                          case 'retry':
                            _batch([entry], widget.downloads.retry, '重试');
                        }
                      },
                      itemBuilder: (_) => [
                        if (entry.canPause)
                          const PopupMenuItem(
                            value: 'pause',
                            child: Text('暂停'),
                          ),
                        if (entry.canResume)
                          const PopupMenuItem(
                            value: 'resume',
                            child: Text('恢复'),
                          ),
                        if (entry.canRetry)
                          const PopupMenuItem(
                            value: 'retry',
                            child: Text('重试'),
                          ),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
