import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/discovery_cache.dart';
import '../domain/discovery.dart';
import '../domain/models.dart';
import '../platform/provider_client.dart';
import 'components.dart';
import 'discovery_cache_status.dart';
import 'source_selector.dart';

/// A finite preview; directory and full-feed pagination belong to their pages.
class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({
    super.key,
    required this.store,
    required this.source,
    required this.onOpen,
    required this.onSearch,
    required this.onLibrary,
    required this.onMore,
    this.continuation,
    this.active = true,
    this.ready = true,
    this.autoLoad = true,
  });
  final AppStore store;
  final DramaSource source;
  final ValueChanged<Drama> onOpen;
  final VoidCallback onSearch, onLibrary, onMore;
  final Widget? continuation;
  final bool active, ready, autoLoad;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  static const _genre = RecommendationGenre.shortPlay;
  List<DiscoveryRow> _rows = const [];
  DiscoveryBoard? _board;
  DiscoveryKind _kind = DiscoveryKind.recommendation;
  String _description = '';
  String? _error, _warning;
  DateTime? _savedAt;
  bool _cached = false, _loading = false, _attempted = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _restore();
    _loadWhenReady();
  }

  @override
  void didUpdateWidget(DiscoveryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store || oldWidget.source != widget.source) {
      _generation++;
      _restore();
    }
    _loadWhenReady();
  }

  void _restore() {
    final cache = widget.store.catalog.discoveryCache;
    _board = widget.source == DramaSource.hongguo
        ? null
        : cache.boards(widget.source)?.boards.firstOrNull;
    final column = widget.source == DramaSource.hongguo
        ? cache.recommendations(_genre)
        : _board == null
        ? null
        : cache.ranking(widget.source, _board!.id);
    _rows = column?.rows ?? const [];
    _kind = column?.kind ?? _board?.kind ?? DiscoveryKind.recommendation;
    _description = column?.description ?? _board?.description ?? '';
    if (widget.source == DramaSource.hongguo && _description.isEmpty) {
      _description = '来自红果的公开推荐';
    }
    _savedAt = column?.savedAt;
    _cached = column != null;
    _loading = _attempted = false;
    _error = _warning = null;
    _warning = column?.warning;
  }

  void _loadWhenReady() {
    if (widget.autoLoad && widget.ready && widget.active && !_attempted) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!mounted || _loading || !widget.ready || !widget.active) return;
    final request = ++_generation;
    final store = widget.store, source = widget.source;
    bool current() =>
        mounted &&
        request == _generation &&
        widget.store == store &&
        widget.source == source &&
        store.catalog.source == source;
    setState(() {
      _attempted = true;
      _loading = true;
      _error = null;
    });
    try {
      if (store.offline) throw const ProviderException('当前离线');
      if (source == DramaSource.hongguo) {
        final result = await store.provider.recommendations(_genre);
        if (!current()) return;
        final savedAt = store.now();
        await store.catalog.saveRecommendationColumn(
          _genre,
          result.items,
          savedAt,
        );
        if (!current()) return;
        setState(() {
          _rows = result.items.map(DiscoveryRow.new).toList(growable: false);
          _kind = DiscoveryKind.recommendation;
          _description = '来自红果的公开推荐';
          _savedAt = savedAt;
          _cached = false;
          _warning = null;
        });
      } else {
        final boards = await store.provider.discoveryBoards(source);
        if (!current()) return;
        await store.catalog.saveDiscoveryBoards(source, boards);
        if (!current()) return;
        if (boards.isEmpty) {
          setState(() {
            _board = null;
            _rows = const [];
            _description = '';
            _savedAt = null;
            _cached = false;
            _warning = null;
          });
          return;
        }
        final board = boards.first;
        if (_board?.id != board.id) {
          final cached = store.catalog.discoveryCache.ranking(source, board.id);
          setState(() {
            _rows = cached?.rows ?? const [];
            _savedAt = cached?.savedAt;
            _cached = cached != null;
            _warning = cached?.warning;
          });
        }
        setState(() {
          _board = board;
          _kind = board.kind;
          _description = board.description;
        });
        final result = await store.provider.discoveryColumn(source, board.id);
        if (!current()) return;
        final column = CachedDiscoveryColumn(
          result.rows,
          savedAt: store.now(),
          kind: result.kind,
          description: result.description,
          warning: result.warning,
        );
        await store.catalog.saveRankingColumn(source, board.id, column);
        if (!current()) return;
        setState(() {
          _rows = result.rows;
          _kind = result.kind;
          _description = result.description.isEmpty
              ? board.description
              : result.description;
          _savedAt = column.savedAt;
          _cached = false;
          _warning = result.warning;
        });
      }
    } catch (_) {
      if (current()) {
        setState(() {
          _error = store.offline
              ? '当前离线，联网后可更新栏目'
              : _rows.isEmpty
              ? '栏目暂时无法加载，请重试'
              : '栏目更新失败，已保留现有内容';
        });
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store.catalog,
    builder: (context, _) {
      final store = widget.store;
      final rows = {
        for (final row in _rows)
          if (widget.source != DramaSource.huangdou ||
              !store.catalog.hideVip ||
              store.catalog.currentDrama(row.drama).vip != true)
            row.drama.key: row,
      }.values.take(6).toList(growable: false);
      final title = widget.source == DramaSource.hongguo
          ? '真人剧推荐'
          : _board?.name ?? '当前站源栏目';
      return RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          key: PageStorageKey('discovery-${widget.source.name}'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SourceSelector(
                          preferences: store.preferences,
                          catalog: store.catalog,
                          value: widget.source,
                          onChanged: (source) {
                            if (source != null) {
                              perform(
                                context,
                                () => store.catalog.selectSource(source),
                              );
                            }
                          },
                        ),
                        TextButton.icon(
                          onPressed: widget.onLibrary,
                          icon: const Icon(Icons.grid_view_outlined),
                          label: const Text('完整剧库'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: widget.onSearch,
                      icon: const Icon(Icons.search),
                      label: const Text('搜索剧名'),
                    ),
                    if (widget.continuation != null) widget.continuation!,
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onMore,
                          child: Text(
                            widget.source == DramaSource.hongguo
                                ? '更多推荐'
                                : '查看全部栏目',
                          ),
                        ),
                        IconButton(
                          tooltip: '更新首页栏目',
                          onPressed: widget.ready && !_loading ? _load : null,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    Text(
                      _description.isNotEmpty
                          ? _description
                          : '查看当前站源内容，或进入完整剧库浏览',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            if (_savedAt != null)
              SliverToBoxAdapter(
                child: DiscoveryCacheStatus(
                  savedAt: _savedAt!,
                  cached: _cached,
                ),
              ),
            if (_loading)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            if (_error != null || _warning?.isNotEmpty == true)
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_warning?.isNotEmpty == true) Text(_warning!),
                      if (_error != null) ...[
                        Text(_error!),
                        TextButton.icon(
                          onPressed: widget.ready && !_loading ? _load : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试栏目'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (rows.isEmpty && !_loading && _error == null)
              const SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.movie_outlined,
                  title: '暂时没有栏目内容',
                  message: '可搜索剧名，或进入完整剧库浏览',
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) => SliverGrid.builder(
                  itemCount: rows.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: (constraints.crossAxisExtent / 165)
                        .floor()
                        .clamp(2, 6),
                    mainAxisSpacing: 22,
                    crossAxisSpacing: 14,
                    childAspectRatio: .61,
                  ),
                  itemBuilder: (context, index) => ListenableBuilder(
                    listenable: Listenable.merge([
                      store.catalog,
                      store.records,
                    ]),
                    builder: (context, _) {
                      final row = rows[index];
                      final drama = store.catalog.currentDrama(row.drama);
                      return Stack(
                        children: [
                          DramaCard(
                            drama: drama,
                            onTap: () => widget.onOpen(drama),
                            favorite: store.records.favorites.containsKey(
                              drama.key,
                            ),
                            onFavorite: () => perform(
                              context,
                              () => store.records.toggleFavorite(drama),
                            ),
                          ),
                          if (_kind == DiscoveryKind.ranking && row.rank > 0)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: IgnorePointer(
                                child: Semantics(
                                  label: '排名第 ${row.rank} 名',
                                  child: Chip(label: Text('${row.rank}')),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
