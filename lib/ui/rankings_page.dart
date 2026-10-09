import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/discovery_cache.dart';
import '../domain/discovery.dart';
import '../platform/provider_client.dart';
import '../domain/models.dart';
import 'components.dart';
import 'discovery_cache_status.dart';

class RankingsPage extends StatefulWidget {
  const RankingsPage({super.key, required this.store, required this.onOpen});
  final AppStore store;
  final ValueChanged<Drama> onOpen;
  @override
  State<RankingsPage> createState() => _RankingsPageState();
}

class _RankingsPageState extends State<RankingsPage> {
  late DramaSource source = widget.store.catalog.source;
  List<DiscoveryBoard> boards = const [];
  List<DiscoveryRow> rows = const [];
  String? selected, error, warning;
  DiscoveryKind kind = DiscoveryKind.ranking;
  String description = '';
  DateTime? updatedAt;
  bool cachedOnly = false, failedBoards = false;
  bool loading = false, hasMore = false;
  bool? failedMore;
  int page = 1, generation = 0;
  @override
  void initState() {
    super.initState();
    _restoreBoards();
    _loadBoards();
  }

  @override
  void didUpdateWidget(RankingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    generation++;
    source = widget.store.catalog.source;
    _restoreBoards();
    _loadBoards();
  }

  void _restoreBoards() {
    boards =
        widget.store.catalog.discoveryCache.boards(source)?.boards ?? const [];
    selected = boards.isEmpty ? null : boards.first.id;
    _restoreColumn();
  }

  void _restoreColumn() {
    final cached = selected == null
        ? null
        : widget.store.catalog.discoveryCache.ranking(source, selected!);
    rows = cached?.rows ?? const [];
    updatedAt = cached?.savedAt;
    cachedOnly = cached != null;
    kind = cached?.kind ?? DiscoveryKind.ranking;
    description = cached?.description ?? '';
    warning = cached?.warning;
    page = 1;
    hasMore = false;
    loading = false;
    error = null;
    failedMore = null;
    failedBoards = false;
  }

  Future<void> _loadBoards() async {
    if (!mounted || loading) return;
    final request = ++generation;
    final requestStore = widget.store;
    final requestSource = source;
    setState(() {
      loading = true;
      error = null;
      failedBoards = false;
    });
    try {
      final incoming = await requestStore.provider.discoveryBoards(
        requestSource,
      );
      if (!mounted || request != generation) return;
      await requestStore.catalog.saveDiscoveryBoards(requestSource, incoming);
      if (!mounted || request != generation) return;
      setState(() {
        boards = incoming;
        loading = false;
      });
      if (boards.isNotEmpty) {
        final board = boards.any((board) => board.id == selected)
            ? selected!
            : boards.first.id;
        _selectBoard(board, refresh: true);
      } else {
        setState(() {
          selected = null;
          _restoreColumn();
        });
      }
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          failedBoards = true;
          error = '栏目列表暂时无法加载，请重试';
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  void _selectBoard(String board, {bool refresh = false}) {
    if (!mounted || (!refresh && board == selected)) return;
    setState(() {
      selected = board;
      _restoreColumn();
    });
    _load();
  }

  Future<void> _retry() => failedBoards || selected == null
      ? _loadBoards()
      : _load(more: failedMore ?? false);

  Future<void> _load({bool more = false}) async {
    final board = selected;
    if (!mounted ||
        board == null ||
        loading ||
        (more && (!hasMore || cachedOnly))) {
      return;
    }
    final request = ++generation;
    final requestStore = widget.store;
    final requestSource = source;
    final nextPage = more ? page + 1 : 1;
    final previous = more ? rows : const <DiscoveryRow>[];
    setState(() {
      loading = true;
      error = null;
      failedMore = null;
    });
    try {
      if (requestStore.offline) throw const ProviderException('当前离线');
      final result = await requestStore.provider.discoveryColumn(
        requestSource,
        board,
        page: nextPage,
      );
      if (!mounted || request != generation) return;
      final nextRows = List<DiscoveryRow>.unmodifiable(
        {
          for (final row in [...previous, ...result.rows]) row.drama.key: row,
        }.values,
      );
      final fetchedAt = requestStore.now();
      await requestStore.catalog.saveRankingColumn(
        requestSource,
        board,
        CachedDiscoveryColumn(
          nextRows,
          savedAt: fetchedAt,
          kind: result.kind,
          description: result.description,
          warning: result.warning,
        ),
      );
      if (!mounted || request != generation) return;
      setState(() {
        rows = nextRows;
        updatedAt = fetchedAt;
        cachedOnly = false;
        hasMore = result.hasMore;
        kind = result.kind;
        description = result.description;
        warning = result.warning?.isNotEmpty == true ? result.warning : null;
        page = nextPage;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          failedMore = more;
          error = requestStore.offline
              ? '当前离线，联网后可重试栏目'
              : rows.isEmpty
              ? '栏目暂时无法加载，请重试'
              : more
              ? '更多栏目内容暂时无法加载，已保留现有内容'
              : '栏目刷新失败，已保留现有内容';
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store.catalog, widget.store.records]),
    builder: (context, _) {
      final visible = rows.where((row) {
        return source != DramaSource.huangdou ||
            !widget.store.catalog.hideVip ||
            widget.store.catalog.currentDrama(row.drama).vip != true;
      }).toList();
      return Scaffold(
        appBar: AppBar(title: Text('${source.label}栏目')),
        body: Column(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                children: [
                  for (final board in boards)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(board.name),
                        selected: selected == board.id,
                        onSelected: (_) => _selectBoard(board.id),
                      ),
                    ),
                ],
              ),
            ),
            if (source == DramaSource.huangdou)
              FilterChip(
                label: Text(widget.store.catalog.hideVip ? '隐藏 VIP' : '显示 VIP'),
                selected: widget.store.catalog.hideVip,
                onSelected: (value) => perform(
                  context,
                  () => widget.store.catalog.setHideVip(value),
                ),
              ),
            if (description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(description),
              ),
            if (updatedAt != null)
              DiscoveryCacheStatus(savedAt: updatedAt!, cached: cachedOnly),
            if (loading) const LinearProgressIndicator(),
            if (warning != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(warning!)),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: loading ? null : _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: visible.isEmpty && !loading && !hasMore
                  ? EmptyState(
                      icon: Icons.bar_chart,
                      title: error != null ? '栏目暂时不可用' : '暂无栏目内容',
                      message: error != null ? '稍后重试，或返回剧库继续浏览' : '切换栏目，或稍后刷新',
                      action: error == null
                          ? OutlinedButton(
                              onPressed: _retry,
                              child: const Text('刷新'),
                            )
                          : null,
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(),
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: visible.length + (hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == visible.length) {
                            return TextButton(
                              onPressed: loading || error != null
                                  ? null
                                  : () => _load(more: true),
                              child: const Text('加载更多'),
                            );
                          }
                          final row = visible[index];
                          final drama = widget.store.catalog.currentDrama(
                            row.drama,
                          );
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => widget.onOpen(drama),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 96,
                                      height: 132,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          Poster(drama, radius: 10),
                                          if (kind == DiscoveryKind.ranking &&
                                              row.rank > 0)
                                            Positioned(
                                              top: 0,
                                              left: 0,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 9,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: index < 3
                                                      ? Theme.of(
                                                          context,
                                                        ).colorScheme.primary
                                                      : Colors.black87,
                                                  borderRadius:
                                                      const BorderRadius.only(
                                                        topLeft:
                                                            Radius.circular(10),
                                                        bottomRight:
                                                            Radius.circular(10),
                                                      ),
                                                ),
                                                child: Text(
                                                  '${row.rank}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            drama.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            [
                                              drama.source.label,
                                              if (drama.category.isNotEmpty)
                                                drama.category,
                                              if (drama.episodes > 0)
                                                '${drama.episodes} 集',
                                            ].join(' · '),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                          if (drama.description.isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              drama.description,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ],
                                          const SizedBox(height: 10),
                                          Text(
                                            '查看分集 ›',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}
