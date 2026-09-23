import 'dart:async';

import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'episode_grid.dart';
import 'player_page.dart';
import 'download_range_sheet.dart';

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
  WatchRecord record,
) async {
  List<Episode> episodes;
  List<int>? indices;
  var localOnly = false;
  try {
    episodes = await store.episodes(record.drama);
  } catch (_) {
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
  if (!context.mounted) return;
  final index = episodes.indexWhere((e) => e.id == record.episodeId);
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        store: store,
        downloads: downloads,
        drama: record.drama,
        episodes: episodes,
        initialIndex: index < 0 ? 0 : index,
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
  late Future<List<Episode>> _episodes;
  List<Episode> _loaded = [];
  bool _enqueueing = false, _refreshing = false, _expanded = false;
  Drama get drama => widget.store.currentDrama(widget.drama);
  @override
  void initState() {
    super.initState();
    _episodes = _fetch();
    unawaited(widget.store.refreshDetail(widget.drama));
  }

  void _play(int index) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        store: widget.store,
        downloads: widget.downloads,
        drama: drama,
        episodes: _loaded,
        initialIndex: index,
      ),
    ),
  );
  Future<List<Episode>> _fetch({bool refresh = false}) async {
    final rows = await widget.store.episodes(drama, refresh: refresh);
    if (mounted) {
      unawaited(
        widget.store.markEpisodesSeen(drama, rows).catchError((Object _) {}),
      );
    }
    return rows;
  }

  Future<void> _refresh() async {
    if (_refreshing || _enqueueing) return;
    setState(() => _refreshing = true);
    await perform(context, () async {
      unawaited(widget.store.refreshDetail(drama, force: true));
      final rows = await _fetch(refresh: true);
      if (mounted) setState(() => _episodes = Future.value(rows));
    });
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _downloadRange(int resumeIndex) async {
    if (_enqueueing || _loaded.isEmpty) return;
    final rows = List<Episode>.of(_loaded);
    final range = await showModalBottomSheet<(int, int)>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          DownloadRangeSheet(episodes: rows, startIndex: resumeIndex),
    );
    if (range == null || !mounted) return;
    setState(() => _enqueueing = true);
    var failed = 0;
    for (var i = range.$1; i <= range.$2; i++) {
      try {
        await widget.downloads.enqueue(drama, rows[i], i);
      } catch (_) {
        failed++;
      }
      if (!mounted) break;
    }
    if (mounted) {
      setState(() => _enqueueing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failed == 0 ? '所选分集已加入队列，已有下载自动跳过' : '$failed 集未加入队列，请检查网络和设备空间后重试',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    return Scaffold(
      appBar: AppBar(title: Text(drama.source.label)),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 22),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 320,
                      child: SingleChildScrollView(child: _summary(true)),
                    ),
                    const SizedBox(width: 40),
                    Expanded(child: _chapterList()),
                  ],
                )
              : CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _summary(false)),
                    SliverFillRemaining(
                      hasScrollBody: true,
                      child: _chapterList(),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _summary(bool wide) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final favorite = widget.store.favorites.containsKey(drama.key);
      final description = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(drama.title, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(
            '${drama.source.label} · ${drama.category.isEmpty ? '短剧' : drama.category}',
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (drama.episodes > 0) Chip(label: Text('${drama.episodes} 集')),
              if (drama.statusLabel.isNotEmpty)
                Chip(label: Text(drama.statusLabel)),
              if (drama.vip == true) const Chip(label: Text('VIP')),
            ],
          ),
          if (drama.vip == true)
            const Text('部分分集需要站源授权，试看不作为完整正片', style: TextStyle(fontSize: 12)),
          if (drama.date.isNotEmpty)
            Text('上线 ${drama.date}', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () =>
                perform(context, () => widget.store.toggleFavorite(drama)),
            icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_add_outlined),
            label: Text(favorite ? '已收藏' : '收藏这部剧'),
          ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wide) ...[
            AspectRatio(aspectRatio: 3 / 4, child: Poster(drama, radius: 22)),
            const SizedBox(height: 22),
            description,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 125, height: 168, child: Poster(drama)),
                const SizedBox(width: 20),
                Expanded(child: description),
              ],
            ),
          const SizedBox(height: 24),
          Text(
            drama.description.isEmpty ? '好故事，从第一集开始。' : drama.description,
            maxLines: _expanded
                ? null
                : wide
                ? 12
                : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
          if (drama.description.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起简介' : '展开简介'),
            ),
          if (drama.tags.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final tag in drama.tags.take(8)) Chip(label: Text(tag)),
              ],
            ),
          if (widget.store.detailErrors[drama.key] != null)
            Text(
              widget.store.detailErrors[drama.key]!,
              style: const TextStyle(fontSize: 12),
            ),
          const SizedBox(height: 24),
        ],
      );
    },
  );
  Widget _chapterList() => FutureBuilder<List<Episode>>(
    future: _episodes,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '分集暂时没加载出来',
            message: '${snapshot.error}',
            action: FilledButton(
              onPressed: () => setState(
                () => _episodes = widget.store.episodes(drama, refresh: true),
              ),
              child: const Text('重新加载'),
            ),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      _loaded = snapshot.data!;
      if (_loaded.isEmpty) return const Center(child: Text('暂无可播放分集'));
      final record = widget.store.history[drama.key];
      var resumeIndex = record == null
          ? 0
          : _loaded.indexWhere((e) => e.id == record.episodeId);
      if (resumeIndex < 0) resumeIndex = 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _play(resumeIndex),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    record == null
                        ? '开始观看'
                        : '继续第 ${_loaded[resumeIndex].number} 集',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: '选择下载分集',
                onPressed: _enqueueing || _refreshing
                    ? null
                    : () => _downloadRange(resumeIndex),
                icon: _enqueueing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (widget.store.episodeErrors[drama.key] != null)
            const Text('暂未更新成功，正在显示缓存分集', style: TextStyle(fontSize: 12)),
          Row(
            children: [
              Text('选集', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              Text('共 ${_loaded.length} 集'),
              IconButton(
                tooltip: '刷新分集',
                onPressed: _refreshing || _enqueueing ? null : _refresh,
                icon: _refreshing
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
          Expanded(
            child: ListenableBuilder(
              listenable: widget.downloads,
              builder: (context, _) => EpisodeGrid(
                episodes: _loaded,
                initialIndex: resumeIndex,
                onJump: _play,
                builder: (context, index) => OutlinedButton(
                  onPressed: () => _play(index),
                  onLongPress: () => perform(
                    context,
                    () =>
                        widget.downloads.enqueue(drama, _loaded[index], index),
                  ),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: record?.episodeId == _loaded[index].id
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_loaded[index].number}'),
                      if (_loaded[index].vip)
                        const Text('VIP', style: TextStyle(fontSize: 10)),
                      if (widget.downloads.entryFor(drama, _loaded[index])
                          case final entry?)
                        Text(
                          entry.complete
                              ? '已下载'
                              : entry.failure != null ||
                                    entry.status == TaskStatus.failed
                              ? '失败'
                              : entry.userPaused
                              ? '已暂停'
                              : '下载中',
                          style: const TextStyle(fontSize: 10),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
