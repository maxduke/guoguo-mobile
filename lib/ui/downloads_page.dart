import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'player_page.dart';

enum _TaskFilter {
  all('全部'),
  pending('未完成'),
  complete('已完成'),
  failed('失败'),
  paused('暂停');

  const _TaskFilter(this.label);
  final String label;

  bool matches(DownloadEntry entry) => switch (this) {
    all => true,
    pending => !entry.complete,
    complete => entry.complete,
    failed => entry.canRetry,
    paused => entry.canResume,
  };
}

enum _Sort {
  recent('最近添加'),
  largest('占用从大到小'),
  title('剧名排序');

  const _Sort(this.label);
  final String label;
}

class _DownloadGroup {
  _DownloadGroup(List<DownloadEntry> entries, this.bytes)
    : entries = List.unmodifiable(
        entries..sort((a, b) => a.index.compareTo(b.index)),
      ),
      recent = entries
          .map((e) => e.id)
          .reduce((a, b) => a.compareTo(b) > 0 ? a : b),
      completed = entries.where((e) => e.complete).length;

  final List<DownloadEntry> entries;
  final int? bytes;
  final String recent;
  final int completed;
  Drama get drama => entries.first.drama;
  String get size => bytes == null ? '待统计' : formatDownloadBytes(bytes!);
}

class _DownloadView {
  const _DownloadView({
    required this.entries,
    required this.groups,
    required this.counts,
    required this.sourceCount,
    required this.completedCount,
    required this.sourceBytes,
  });

  final List<DownloadEntry> entries;
  final List<_DownloadGroup> groups;
  final Map<_TaskFilter, int> counts;
  final int sourceCount, completedCount;
  final int? sourceBytes;
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.onOpen,
    this.active = true,
  });
  final AppStore store;
  final DownloadStore downloads;
  final ValueChanged<Drama> onOpen;
  final bool active;
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
  bool _defaultFilterSet = false;
  String? _openingEntry;
  int _playGeneration = 0;

  bool get _locked => _busy || _openingEntry != null;
  bool get _interactive =>
      mounted && widget.active && ModalRoute.of(context)?.isCurrent != false;

  @override
  void initState() {
    super.initState();
    _setDefaultFilter();
    widget.downloads.addListener(_downloadsChanged);
    unawaited(widget.downloads.refreshUsage());
  }

  void _setDefaultFilter() {
    if (_defaultFilterSet ||
        (widget.downloads.initializing && !widget.downloads.manifestLoaded)) {
      return;
    }
    _defaultFilterSet = true;
    if (widget.downloads.entries.isNotEmpty &&
        widget.downloads.entries.every((e) => e.complete)) {
      _filter = _TaskFilter.complete;
    }
  }

  void _downloadsChanged() {
    if (!mounted) return;
    if (!_defaultFilterSet) setState(_setDefaultFilter);
    if (_selected.isNotEmpty) {
      _selected.retainAll(
        widget.downloads.entries.where(_visible).map((e) => e.id),
      );
    }
  }

  @override
  void didUpdateWidget(DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloads != widget.downloads) {
      oldWidget.downloads.removeListener(_downloadsChanged);
      widget.downloads.addListener(_downloadsChanged);
      _defaultFilterSet = false;
      _filter = _TaskFilter.pending;
      _focusedDrama = null;
      _setDefaultFilter();
      _selected.clear();
      _collapsed.clear();
      unawaited(widget.downloads.refreshUsage());
    }
    if ((oldWidget.active && !widget.active) ||
        oldWidget.downloads != widget.downloads ||
        oldWidget.store != widget.store) {
      ++_playGeneration;
      _openingEntry = null;
    }
  }

  @override
  void dispose() {
    widget.downloads.removeListener(_downloadsChanged);
    super.dispose();
  }

  bool _inScope(DownloadEntry entry) =>
      (_source == null || entry.drama.source == _source) &&
      (_space || _focusedDrama == null || entry.drama.key == _focusedDrama);

  bool _visible(DownloadEntry entry) =>
      _inScope(entry) && (_space || _filter.matches(entry));

  _DownloadView _view() {
    final sourceEntries = widget.downloads.entries
        .where((e) => _source == null || e.drama.source == _source)
        .toList();
    final scoped = sourceEntries.where(_inScope).toList();
    final entries = scoped.where((e) => _space || _filter.matches(e)).toList();
    final byDrama = <String, List<DownloadEntry>>{};
    for (final entry in entries) {
      byDrama.putIfAbsent(entry.drama.key, () => []).add(entry);
    }
    final groups = byDrama.values
        .map(
          (entries) =>
              _DownloadGroup(entries, widget.downloads.bytesFor(entries)),
        )
        .toList();
    groups.sort((a, b) {
      final order = switch (_sort) {
        _Sort.largest => (b.bytes ?? -1).compareTo(a.bytes ?? -1),
        _Sort.title => a.drama.title.compareTo(b.drama.title),
        _Sort.recent => b.recent.compareTo(a.recent),
      };
      return order != 0 ? order : a.drama.key.compareTo(b.drama.key);
    });
    return _DownloadView(
      entries: List.unmodifiable(entries),
      groups: List.unmodifiable(groups),
      counts: Map.unmodifiable({
        for (final filter in _TaskFilter.values)
          filter: scoped.where(filter.matches).length,
      }),
      sourceCount: sourceEntries.length,
      completedCount: sourceEntries.where((e) => e.complete).length,
      sourceBytes: widget.downloads.bytesFor(sourceEntries),
    );
  }

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
    if (!_interactive || _locked || entries.isEmpty) return;
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
    if (!_interactive || _locked || entries.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _apply(entries, action, label);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(DownloadEntry entry) async {
    if (!_interactive || _locked || !entry.complete) return;
    final generation = ++_playGeneration;
    bool current() => _interactive && generation == _playGeneration;
    setState(() => _openingEntry = entry.id);
    try {
      final file = await widget.downloads.localFile(entry.drama, entry.episode);
      if (!mounted || !current()) return;
      if (file == null) {
        await widget.downloads.reload();
        if (current()) _playNotice('视频文件已不存在，请重新下载');
        return;
      }
      // Only queue downloaded episodes, so swiping never unexpectedly uses data.
      final queue =
          widget.downloads.entries
              .where((e) => e.complete && e.drama.key == entry.drama.key)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      final index = queue.indexWhere((e) => e.id == entry.id);
      if (index < 0) {
        _playNotice('视频文件已不存在，请重新下载');
        return;
      }
      final store = widget.store, downloads = widget.downloads;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            store: store,
            downloads: downloads,
            drama: entry.drama,
            episodes: queue.map((e) => e.episode).toList(),
            initialIndex: index,
            episodeIndices: queue.map((e) => e.index).toList(),
            localOnly: true,
          ),
        ),
      );
    } catch (_) {
      if (current()) _playNotice('视频暂时无法打开，请重试');
    } finally {
      if (mounted && generation == _playGeneration) {
        setState(() => _openingEntry = null);
      }
    }
  }

  void _playNotice(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.downloads, widget.store.preferences]),
    builder: (context, _) {
      final view = _view();
      final entries = view.entries;
      final groups = view.groups;
      final chosen = entries.where((e) => _selected.contains(e.id)).toList();
      final items = <Object>[
        for (final group in groups) ...[
          group,
          if (!_space && !_collapsed.contains(group.drama.key))
            ...group.entries,
        ],
      ];
      final retryable = entries.where((e) => e.canRetry).toList();
      return RefreshIndicator(
        onRefresh: () async {
          if (widget.downloads.initializationError != null) {
            await widget.downloads.initialize();
          } else {
            await widget.downloads.reload();
          }
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
                        onPressed: _locked
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
                    onSelectionChanged: _locked
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
                    onChanged: _locked
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
                              view.sourceBytes == null
                                  ? '待统计'
                                  : formatDownloadBytes(view.sourceBytes!),
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${groups.length} 部剧 · ${view.completedCount} 集已完成 / ${view.sourceCount} 集任务',
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
                      widget.store.preferences.cellularDownloads
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
                                  '${filter.label} ${view.counts[filter]}',
                                ),
                                selected: _filter == filter,
                                onSelected: _locked
                                    ? null
                                    : (_) => setState(() {
                                        _defaultFilterSet = true;
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
                          onPressed: _locked
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
                        enabled: !_locked,
                        initialValue: _sort,
                        onSelected: (value) => setState(() => _sort = value),
                        itemBuilder: (_) => [
                          for (final sort in const [
                            _Sort.largest,
                            _Sort.recent,
                            _Sort.title,
                          ])
                            PopupMenuItem(value: sort, child: Text(sort.label)),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_sort.label),
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
                        onPressed: _locked
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
                      _openingEntry != null ||
                      widget.downloads.measuringUsage)
                    const LinearProgressIndicator(),
                  if (widget.downloads.initializing)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('正在恢复下载，可先观看已保存视频'),
                    ),
                  if (widget.downloads.initializationError != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: widget.downloads.initializing
                            ? null
                            : () => unawaited(widget.downloads.initialize()),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试下载恢复'),
                      ),
                    ),
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
                  final _DownloadGroup group =>
                    _space ? _storageGroup(group) : _group(group),
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
          onPressed: _locked || entries.isEmpty
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
          onPressed: _locked || chosen.isEmpty ? null : () => _remove(chosen),
          child: Text('删除 (${chosen.length})'),
        ),
        if (!_space) ...[
          TextButton(
            onPressed: _locked || pausable.isEmpty
                ? null
                : () => _batch(pausable, widget.downloads.pause, '暂停'),
            child: Text('暂停 (${pausable.length})'),
          ),
          TextButton(
            onPressed: _locked || resumable.isEmpty
                ? null
                : () => _batch(resumable, widget.downloads.resume, '恢复'),
            child: Text('恢复 (${resumable.length})'),
          ),
          TextButton(
            onPressed: _locked || retryable.isEmpty
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
    onChanged: _locked ? null : (_) => _toggleGroup(episodes),
  );

  Widget _storageGroup(_DownloadGroup group) {
    final episodes = group.entries;
    final drama = group.drama;
    return Card(
      key: ValueKey('storage-${drama.key}'),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: _locked ? null : () => _toggleGroup(episodes),
        onTap: _locked
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
                      '${drama.source.label} · 已完成 ${group.completed}/${episodes.length} 集',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      group.size,
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
                  onPressed: _locked ? null : () => _remove(episodes),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _group(_DownloadGroup group) {
    final episodes = group.entries;
    final drama = group.drama;
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
        '${drama.source.label} · ${episodes.length} 集 · ${group.size}',
      ),
      trailing: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
      onTap: _locked
          ? null
          : () => setState(() {
              if (!_collapsed.add(drama.key)) _collapsed.remove(drama.key);
            }),
      onLongPress: _locked ? null : () => widget.onOpen(drama),
    );
  }

  Widget _entry(DownloadEntry entry) => Dismissible(
    key: ValueKey(entry.id),
    direction: _selecting || _locked || entry.processing
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
        onLongPress: _locked ? null : () => _toggle(entry),
        onTap: _locked
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
                  onChanged: _locked ? null : (_) => _toggle(entry),
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
                        onPressed: _locked ? null : () => _play(entry),
                        icon: _openingEntry == entry.id
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  semanticsLabel: '正在检查视频',
                                ),
                              )
                            : const Icon(Icons.play_circle_fill_rounded),
                      )
                    else if (entry.canRetry)
                      IconButton(
                        tooltip: '重试第 ${entry.episode.number} 集',
                        onPressed: _locked
                            ? null
                            : () =>
                                  _batch([entry], widget.downloads.retry, '重试'),
                        icon: const Icon(Icons.refresh),
                      ),
                    PopupMenuButton<String>(
                      tooltip: '管理下载',
                      enabled: !_locked && !entry.processing,
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
