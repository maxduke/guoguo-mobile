import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'player_page.dart';

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
  bool _enqueueing = false;
  @override
  void initState() {
    super.initState();
    _episodes = widget.store.episodes(widget.drama);
  }

  void _play(int index) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        store: widget.store,
        downloads: widget.downloads,
        drama: widget.drama,
        episodes: _loaded,
        initialIndex: index,
      ),
    ),
  );
  Future<void> _downloadAll() async {
    if (_enqueueing) return;
    setState(() => _enqueueing = true);
    var failed = 0;
    String? error;
    for (var i = 0; i < _loaded.length; i++) {
      try {
        await widget.downloads.enqueue(widget.drama, _loaded[i], i);
      } catch (e) {
        failed++;
        error = '$e';
      }
      if (!mounted) break;
    }
    if (mounted) {
      setState(() => _enqueueing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failed == 0 ? '已加入下载队列' : '$failed 集未加入下载：$error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    return Scaffold(
      appBar: AppBar(title: Text(widget.drama.source.label)),
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
      final favorite = widget.store.favorites.containsKey(widget.drama.key);
      final description = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.drama.title,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            '${widget.drama.source.label} · ${widget.drama.category.isEmpty ? '短剧' : widget.drama.category}',
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 8),
          if (widget.drama.episodes > 0) Text('${widget.drama.episodes} 集'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => perform(
              context,
              () => widget.store.toggleFavorite(widget.drama),
            ),
            icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_add_outlined),
            label: Text(favorite ? '已收藏' : '收藏这部剧'),
          ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wide) ...[
            AspectRatio(
              aspectRatio: 3 / 4,
              child: Poster(widget.drama, radius: 22),
            ),
            const SizedBox(height: 22),
            description,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 125, height: 168, child: Poster(widget.drama)),
                const SizedBox(width: 20),
                Expanded(child: description),
              ],
            ),
          const SizedBox(height: 24),
          Text(
            widget.drama.description.isEmpty
                ? '好故事，从第一集开始。'
                : widget.drama.description,
            maxLines: wide ? 12 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.7,
            ),
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
                () => _episodes = widget.store.episodes(
                  widget.drama,
                  refresh: true,
                ),
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
      final record = widget.store.history[widget.drama.key];
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
                    record == null ? '开始观看' : '继续第 ${resumeIndex + 1} 集',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: '下载整部短剧',
                onPressed: _enqueueing ? null : _downloadAll,
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
          Row(
            children: [
              Text('选集', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              Text('共 ${_loaded.length} 集'),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 80,
                mainAxisExtent: 52,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
              ),
              itemCount: _loaded.length,
              itemBuilder: (context, index) => OutlinedButton(
                onPressed: () => _play(index),
                onLongPress: () => perform(
                  context,
                  () => widget.downloads.enqueue(
                    widget.drama,
                    _loaded[index],
                    index,
                  ),
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
                child: Text('${_loaded[index].number}'),
              ),
            ),
          ),
        ],
      );
    },
  );
}
