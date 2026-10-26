import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../domain/models.dart';
import '../domain/discovery.dart';
import '../platform/provider_client.dart';
import 'components.dart';
import 'television_grid.dart';
import 'discovery_cache_status.dart';

class RecommendationsPage extends StatefulWidget {
  const RecommendationsPage({
    super.key,
    required this.store,
    required this.onOpen,
  });
  final AppStore store;
  final ValueChanged<Drama> onOpen;
  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  RecommendationGenre genre = RecommendationGenre.shortPlay;
  String session = '';
  DateTime? updatedAt;
  bool cachedOnly = false;
  int offset = 0, generation = 0;
  bool loading = false, hasMore = true;
  bool? failedMore;
  String? error;
  List<Drama> rows = const [];

  @override
  void initState() {
    super.initState();
    _restoreColumn();
    _load();
  }

  @override
  void didUpdateWidget(RecommendationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    generation++;
    _restoreColumn();
    _load();
  }

  void _restoreColumn() {
    final cached = widget.store.catalog.discoveryCache.recommendations(genre);
    rows =
        cached?.rows.map((row) => row.drama).toList(growable: false) ??
        const [];
    updatedAt = cached?.savedAt;
    cachedOnly = cached != null;
    offset = 0;
    session = '';
    hasMore = true;
    loading = false;
    error = null;
    failedMore = null;
  }

  void _selectGenre(RecommendationGenre value) {
    if (!mounted || value == genre) return;
    setState(() {
      genre = value;
      _restoreColumn();
    });
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (!mounted || loading || (more && (!hasMore || cachedOnly))) return;
    final request = ++generation;
    final requestStore = widget.store;
    final requestGenre = genre;
    final previous = more ? rows : const <Drama>[];
    final requestOffset = more ? offset : 0;
    final requestSession = more ? session : '';
    setState(() {
      loading = true;
      error = null;
      failedMore = null;
    });
    try {
      if (requestStore.offline) throw const ProviderException('当前离线，请联网后获取推荐');
      final result = await requestStore.provider.recommendations(
        requestGenre,
        offset: requestOffset,
        sessionId: requestSession,
        seen: previous.reversed.take(540).map((d) => d.id).toList(),
      );
      if (!mounted || request != generation) return;
      final nextRows = List<Drama>.unmodifiable(
        {
          for (final d in [...previous, ...result.items]) d.key: d,
        }.values,
      );
      final fetchedAt = requestStore.now();
      await requestStore.catalog.saveRecommendationColumn(
        requestGenre,
        nextRows,
        fetchedAt,
      );
      if (!mounted || request != generation) return;
      setState(() {
        rows = nextRows;
        updatedAt = fetchedAt;
        cachedOnly = false;
        offset = result.nextOffset;
        session = result.sessionId;
        hasMore = result.hasMore;
      });
    } catch (failure) {
      if (mounted && request == generation) {
        setState(() {
          failedMore = more;
          error = requestStore.offline
              ? '当前离线，联网后可重试推荐'
              : rows.isEmpty
              ? '推荐暂时无法加载，请重试'
              : more
              ? '更多推荐暂时无法加载，已保留现有内容'
              : '推荐刷新失败，已保留现有内容';
          if (!requestStore.offline) {
            error = providerFailureMessage(failure, error!);
          }
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('发现 · 红果')),
    body: SafeArea(
      child: RefreshIndicator(
        onRefresh: () => _load(),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '今天，看点什么',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '按喜欢的类型发现新故事',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 10,
                      children: [
                        for (final entry in RecommendationGenre.values)
                          ChoiceChip(
                            label: Text(entry.label),
                            selected: genre == entry,
                            onSelected: (_) => _selectGenre(entry),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '来自站源的公开推荐',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            if (updatedAt != null)
              SliverToBoxAdapter(
                child: DiscoveryCacheStatus(
                  savedAt: updatedAt!,
                  cached: cachedOnly,
                ),
              ),
            if (loading)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            if (error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    children: [
                      Text(error!),
                      TextButton.icon(
                        onPressed: loading
                            ? null
                            : () => _load(more: failedMore ?? false),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            if (rows.isEmpty && !loading && error == null)
              const SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.movie_outlined,
                  title: '暂时没有新推荐',
                  message: '切换类型，或稍后再来看看',
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(22),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns = (constraints.crossAxisExtent / 170)
                      .floor()
                      .clamp(2, 6);
                  return TelevisionGrid(
                    itemKeys: [for (final drama in rows) drama.key],
                    columns: columns,
                    mainAxisExtent:
                        constraints.crossAxisExtent / columns * 1.6 + 45,
                    itemBuilder: (context, index) => ListenableBuilder(
                      listenable: Listenable.merge([
                        widget.store.catalog,
                        widget.store.records,
                      ]),
                      builder: (context, _) {
                        final drama = widget.store.catalog.currentDrama(
                          rows[index],
                        );
                        return DramaCard(
                          drama: drama,
                          onTap: () => widget.onOpen(drama),
                          favorite: widget.store.records.favorites.containsKey(
                            drama.key,
                          ),
                          onFavorite: () => perform(
                            context,
                            () => widget.store.records.toggleFavorite(drama),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (rows.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 32),
                  child: FilledButton.tonalIcon(
                    onPressed:
                        loading || cachedOnly || !hasMore || error != null
                        ? null
                        : () => _load(more: true),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(
                      loading
                          ? '正在寻找…'
                          : cachedOnly
                          ? '刷新后可继续推荐'
                          : hasMore
                          ? '继续推荐'
                          : '这轮推荐已看完',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
