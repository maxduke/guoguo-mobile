import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:background_downloader/background_downloader.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../domain/episode_queue.dart';
import '../domain/watch_resume.dart';
import 'components.dart';
import 'episode_grid.dart';
import 'player_page.dart';
import 'download_range_sheet.dart';
import 'related_series_section.dart';
import 'television_scope.dart';

Future<void> openDrama(
  BuildContext context,
  AppStore store,
  DownloadStore downloads,
  Drama drama,
) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) =>
        DetailPage(store: store, downloads: downloads, drama: drama),
  ),
);

Future<void> continueDrama(
  BuildContext context,
  AppStore store,
  DownloadStore downloads,
  WatchRecord record, {
  bool Function()? isActive,
}) async {
  bool active() =>
      context.mounted &&
      ModalRoute.of(context)?.isCurrent != false &&
      (isActive?.call() ?? true);
  if (!active()) return;
  List<Episode> episodes;
  List<int>? indices;
  var localOnly = false;
  try {
    episodes = await store.catalog.episodes(record.drama);
  } catch (_) {
    if (!active()) return;
    final saved =
        downloads.entries
            .where((e) => e.complete && e.drama.key == record.drama.key)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (!saved.any((e) => e.episode.id == record.episodeId)) rethrow;
    episodes = saved.map((e) => e.episode).toList();
    indices = saved.map((e) => e.index).toList();
    localOnly = true;
  }
  if (!context.mounted || !active()) return;
  episodes = List<Episode>.unmodifiable(episodes);
  if (indices != null) indices = List<int>.unmodifiable(indices);
  int index;
  if (localOnly) {
    // A downloaded successor may skip several episodes. Advance only to the
    // adjacent original slot; otherwise replay the saved episode from zero.
    index = episodes.indexWhere((e) => e.id == record.episodeId);
    final next = nextAdjacentEpisodeIndex(
      index,
      episodes.length,
      episodeIndices: indices,
    );
    if (record.episodeCompleted && next != null) index = next;
  } else {
    index = WatchResume(record, episodes).index;
  }
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        store: store,
        downloads: downloads,
        drama: record.drama,
        episodes: episodes,
        initialIndex: index,
        episodeIndices: indices,
        localOnly: localOnly,
      ),
    ),
  );
}

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.drama,
  });
  final AppStore store;
  final DownloadStore downloads;
  final Drama drama;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  List<Episode> _episodes = const [];
  final _seriesKey = GlobalKey<RelatedSeriesSectionState>();
  final _episodesKey = GlobalKey<EpisodeGridState>();
  bool _loading = false, _episodeFailed = false;
  bool _choosingDownloads = false, _enqueueing = false, _expanded = false;
  bool get _downloadBusy => _choosingDownloads || _enqueueing;
  Drama get drama => widget.store.catalog.currentDrama(widget.drama);
  @override
  void initState() {
    super.initState();
    unawaited(_loadEpisodes());
    unawaited(widget.store.catalog.refreshDetail(widget.drama));
    unawaited(
      widget.store.records
          .markSeasonRead(widget.drama.key)
          .catchError((Object _) {}),
    );
  }

  Future<void> _play(List<Episode> rows, int index) {
    _seriesKey.currentState?.cancelLookup();
    widget.store.records.cancelUpdateChecks();
    final selected = drama;
    return Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          store: widget.store,
          downloads: widget.downloads,
          drama: selected,
          episodes: rows,
          initialIndex: index,
        ),
      ),
    );
  }

  Future<void> _loadEpisodes({bool refresh = false}) async {
    if (_loading || _downloadBusy) return;
    setState(() {
      _loading = true;
      _episodeFailed = false;
    });
    if (refresh) {
      unawaited(widget.store.catalog.refreshDetail(drama, force: true));
    }
    try {
      final rows = List<Episode>.unmodifiable(
        await widget.store.catalog.episodes(drama, refresh: refresh),
      );
      if (!mounted) return;
      setState(() {
        _episodes = rows;
        _loading = false;
      });
      unawaited(
        widget.store.records
            .markEpisodesSeen(drama, rows)
            .catchError((Object _) {}),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _episodeFailed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _downloadRange(List<Episode> rows, int resumeIndex) async {
    if (_downloadBusy || _loading || rows.isEmpty) return;
    final selected = drama;
    setState(() => _choosingDownloads = true);
    try {
      final range = await showModalBottomSheet<(int, int)>(
        context: context,
        isScrollControlled: true,
        builder: (_) =>
            DownloadRangeSheet(episodes: rows, startIndex: resumeIndex),
      );
      if (range == null || !mounted) return;
      setState(() {
        _choosingDownloads = false;
        _enqueueing = true;
      });
      var failed = 0;
      for (var i = range.$1; i <= range.$2; i++) {
        try {
          await widget.downloads.enqueue(selected, rows[i], i);
        } catch (_) {
          failed++;
        }
        if (!mounted) break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failed == 0
                  ? '所选分集已加入队列，已有下载自动跳过'
                  : '$failed 集未加入队列，请检查网络和设备空间后重试',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _choosingDownloads = false;
          _enqueueing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.store,
        widget.store.catalog,
        widget.store.records,
        widget.store.records.progress,
      ]),
      builder: (context, _) {
        final rows = _episodes;
        final record = widget.store.records.history[drama.key];
        final resume = WatchResume(record, rows);
        return Scaffold(
          appBar: AppBar(title: Text(drama.source.label)),
          body: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 900;
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 20),
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: 260,
                                  child: SingleChildScrollView(
                                    child: _summary(true),
                                  ),
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: _episodeContent(
                                      rows,
                                      record,
                                      resume.index,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _summary(false),
                                  _episodeContent(rows, record, resume.index),
                                ],
                              ),
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
          bottomNavigationBar: _bottomActions(rows, record, resume),
        );
      },
    );
  }

  Widget _bottomActions(
    List<Episode> rows,
    WatchRecord? record,
    WatchResume resume,
  ) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) {
      if (TelevisionScope.of(context) &&
          rows.isNotEmpty &&
          (event is KeyDownEvent || event is KeyRepeatEvent) &&
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _episodesKey.currentState?.focusCurrent();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: '选择下载分集',
                    onPressed: rows.isEmpty || _downloadBusy || _loading
                        ? null
                        : () => _downloadRange(rows, resume.index),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(52, 52),
                    ),
                    icon: _enqueueing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('detail-primary-play'),
                      autofocus: TelevisionScope.of(context),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onPressed: rows.isEmpty
                          ? null
                          : () => _play(rows, resume.index),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        rows.isEmpty
                            ? (_episodeFailed
                                  ? '分集加载失败'
                                  : _loading
                                  ? '正在加载分集…'
                                  : '暂无可播放分集')
                            : record == null
                            ? '开始观看'
                            : !resume.canContinue
                            ? resume.status == WatchStatus.completed
                                  ? '重新观看'
                                  : '重看第 ${resume.episode!.number} 集'
                            : '继续第 ${resume.episode!.number} 集',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _summary(bool wide) {
    final favorite = widget.store.records.favorites.containsKey(drama.key);
    final facts = [
      if (drama.episodes > 0) '${drama.episodes} 集',
      if (drama.statusLabel.isNotEmpty) drama.statusLabel,
      if (drama.vip == true) 'VIP',
    ].join(' · ');
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(drama.title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          '${drama.source.label} · ${drama.category.isEmpty ? '短剧' : drama.category}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(facts, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => perform(
            context,
            () => widget.store.records.toggleFavorite(drama),
          ),
          icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_add_outlined),
          label: Text(favorite ? '已收藏' : '收藏'),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide) ...[
          SizedBox(width: 180, height: 240, child: Poster(drama, radius: 20)),
          const SizedBox(height: 12),
          heading,
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 76,
                height: 104,
                child: Poster(drama, radius: 12),
              ),
              const SizedBox(width: 12),
              Expanded(child: heading),
            ],
          ),
        ],
        if (drama.vip == true) ...[
          const SizedBox(height: 8),
          const Text('部分分集需要站源授权，试看不作为完整正片', style: TextStyle(fontSize: 12)),
        ],
        if (drama.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            drama.description,
            maxLines: _expanded ? null : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
        if (_expanded && drama.date.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('上线 ${drama.date}', style: const TextStyle(fontSize: 12)),
        ],
        if (drama.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            drama.tags.join(' · '),
            maxLines: _expanded ? null : 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (drama.description.isNotEmpty ||
            drama.tags.isNotEmpty ||
            drama.date.isNotEmpty)
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '收起资料' : '展开资料'),
          ),
        if (widget.store.catalog.detailErrors[drama.key] != null)
          Text(
            widget.store.catalog.detailErrors[drama.key]!,
            style: const TextStyle(fontSize: 12),
          ),
        if (widget.store.persistenceError != null)
          Text(
            widget.store.persistenceError!,
            style: const TextStyle(fontSize: 12),
          ),
        if (widget.store.cachePersistenceError != null)
          Text(
            widget.store.cachePersistenceError!,
            style: const TextStyle(fontSize: 12),
          ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _episodeContent(
    List<Episode> rows,
    WatchRecord? record,
    int resumeIndex,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _chapterList(rows, record, resumeIndex),
      const SizedBox(height: 24),
      RelatedSeriesSection(
        key: _seriesKey,
        store: widget.store,
        drama: drama,
        onOpen: (row) =>
            openDrama(context, widget.store, widget.downloads, row),
      ),
      const SizedBox(height: 24),
    ],
  );

  Widget _chapterList(
    List<Episode> rows,
    WatchRecord? record,
    int resumeIndex,
  ) {
    if (rows.isEmpty) {
      if (_episodeFailed) {
        return ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) => EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '分集暂时没加载出来',
            message: widget.store.offline
                ? '当前离线，联网后可重新加载分集'
                : widget.store.catalog.episodeErrors[drama.key] ?? '请检查网络后重试',
            action: FilledButton(
              onPressed: () => _loadEpisodes(refresh: true),
              child: const Text('重新加载'),
            ),
          ),
        );
      }
      if (_loading) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(),
          ),
        );
      }
      return const Center(child: Text('暂无可播放分集'));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_loading &&
            (_episodeFailed ||
                widget.store.catalog.episodeErrors[drama.key] != null))
          Text(
            widget.store.catalog.episodeErrors[drama.key] ?? '暂未更新成功，正在显示缓存分集',
            style: const TextStyle(fontSize: 12),
          ),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('选集', style: Theme.of(context).textTheme.titleLarge),
            Text('共 ${rows.length} 集'),
            IconButton(
              tooltip: '刷新分集',
              onPressed: _loading || _downloadBusy
                  ? null
                  : () => _loadEpisodes(refresh: true),
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: widget.downloads,
          builder: (context, _) => _episodeGrid(rows, resumeIndex, record),
        ),
      ],
    );
  }

  Widget _episodeGrid(
    List<Episode> rows,
    int resumeIndex,
    WatchRecord? record,
  ) => EpisodeGrid(
    key: _episodesKey,
    episodes: rows,
    initialIndex: resumeIndex,
    shrinkWrap: true,
    onJump: (index) => _play(rows, index),
    builder: (context, index) => OutlinedButton(
      onPressed: () => _play(rows, index),
      onLongPress: () => perform(
        context,
        () => widget.downloads.enqueue(drama, rows[index], index),
      ),
      style: OutlinedButton.styleFrom(
        backgroundColor: record?.episodeId == rows[index].id
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${rows[index].number}'),
          if (rows[index].vip)
            const Text('VIP', style: TextStyle(fontSize: 10)),
          if (widget.downloads.entryFor(drama, rows[index]) case final entry?)
            Text(
              entry.complete
                  ? '已下载'
                  : entry.failure != null || entry.status == TaskStatus.failed
                  ? '失败'
                  : entry.userPaused
                  ? '已暂停'
                  : '下载中',
              style: const TextStyle(fontSize: 10),
            ),
        ],
      ),
    ),
  );
}
