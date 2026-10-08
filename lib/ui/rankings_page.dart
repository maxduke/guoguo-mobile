import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../domain/models.dart';
import 'components.dart';

class _RankingBoard {
  const _RankingBoard(this.id, this.name);
  final String id, name;

  factory _RankingBoard.fromJson(Map<String, dynamic> value) =>
      _RankingBoard(value['id'] as String, value['name'] as String);
}

class _RankingRow {
  const _RankingRow(this.drama, this.rank);
  final Drama drama;
  final int rank;

  factory _RankingRow.fromJson(Map<String, dynamic> value) => _RankingRow(
    Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    value['rank'] as int? ?? 0,
  );
}

class RankingsPage extends StatefulWidget {
  const RankingsPage({super.key, required this.store, required this.onOpen});
  final AppStore store;
  final ValueChanged<Drama> onOpen;
  @override
  State<RankingsPage> createState() => _RankingsPageState();
}

class _RankingsPageState extends State<RankingsPage> {
  late final DramaSource source = widget.store.catalog.source;
  List<_RankingBoard> boards = const [];
  List<_RankingRow> rows = const [];
  String? selected, error, warning;
  String kind = "ranking", description = "";
  bool loading = false, hasMore = false;
  bool? failedMore;
  int page = 1, generation = 0;
  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  Future<void> _loadBoards() async {
    if (!mounted || loading) return;
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.store.provider.call('boards', {
        'source': source.name,
      });
      if (!mounted || request != generation) return;
      final incoming = List<_RankingBoard>.unmodifiable(
        (result['items'] as List).map(
          (v) => _RankingBoard.fromJson(Map<String, dynamic>.from(v as Map)),
        ),
      );
      setState(() {
        boards = incoming;
        loading = false;
      });
      if (boards.isNotEmpty) _selectBoard(boards.first.id);
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          error = '榜单列表暂时无法加载，请重试';
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  void _selectBoard(String board) {
    if (!mounted || board == selected) return;
    setState(() {
      selected = board;
      rows = const [];
      page = 1;
      hasMore = false;
      kind = 'ranking';
      description = '';
      warning = null;
      loading = false;
    });
    _load();
  }

  Future<void> _retry() =>
      selected == null ? _loadBoards() : _load(more: failedMore ?? false);

  Future<void> _load({bool more = false}) async {
    final board = selected;
    if (!mounted || board == null || loading || (more && !hasMore)) return;
    final request = ++generation;
    final nextPage = more ? page + 1 : 1;
    final previous = more ? rows : const <_RankingRow>[];
    setState(() {
      loading = true;
      error = null;
      failedMore = null;
    });
    try {
      final result = await widget.store.provider.call('ranking', {
        'board': board,
        'page': nextPage,
      });
      if (!mounted || request != generation) return;
      final incoming = (result['items'] as List)
          .map((v) => _RankingRow.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
      final nextKind = result['kind'] as String? ?? 'ranking';
      final nextDescription = result['description'] as String? ?? '';
      final nextWarning = result['warning'] as String?;
      final nextHasMore = result['hasMore'] as bool? ?? false;
      final nextRows = List<_RankingRow>.unmodifiable(
        {
          for (final row in [...previous, ...incoming]) row.drama.key: row,
        }.values,
      );
      setState(() {
        rows = nextRows;
        hasMore = nextHasMore;
        kind = nextKind;
        description = nextDescription;
        warning = nextWarning?.isNotEmpty == true ? nextWarning : null;
        page = nextPage;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          failedMore = more;
          error = rows.isEmpty
              ? '榜单暂时无法加载，请重试'
              : more
              ? '更多榜单内容暂时无法加载，已保留现有内容'
              : '榜单刷新失败，已保留现有内容';
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
        final drama = widget.store.catalog.currentDrama(row.drama);
        return source != DramaSource.huangdou ||
            !widget.store.catalog.hideVip ||
            drama.vip != true;
      }).toList();
      return Scaffold(
        appBar: AppBar(title: Text('${source.label}榜单')),
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
                      title: error != null ? '榜单暂时不可用' : '暂无榜单内容',
                      message: error != null ? '稍后重试，或返回剧库继续浏览' : '切换榜单，或稍后刷新',
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
                                          if (kind == "ranking" && row.rank > 0)
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
