import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../domain/catalog_query.dart';
import '../domain/models.dart';
import 'catalog_search_controller.dart';
import 'components.dart';
import 'source_selector.dart';
import 'television_grid.dart';
import 'television_scope.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.store,
    required this.onOpen,
    this.autofocus = true,
  });
  final AppStore store;
  final ValueChanged<Drama> onOpen;
  final bool autofocus;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late CatalogSearchController _search;
  final _scroll = ScrollController();
  final _results = GlobalKey<TelevisionGridState>();

  @override
  void initState() {
    super.initState();
    _search = CatalogSearchController(widget.store.catalog);
  }

  @override
  void didUpdateWidget(SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    _search.dispose();
    _search = CatalogSearchController(widget.store.catalog);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit(String text) async {
    final search = _search, source = widget.store.catalog.source;
    FocusScope.of(context).unfocus();
    if (!_search.loading && _scroll.hasClients) _scroll.jumpTo(0);
    await search.submit(text);
    if (!mounted || !TelevisionScope.of(context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          search == _search &&
          source == widget.store.catalog.source &&
          search.query == text.trim() &&
          FocusManager.instance.primaryFocus is FocusScopeNode) {
        _results.currentState?.focusItem(0);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _search,
      widget.store,
      widget.store.catalog,
      widget.store.records,
    ]),
    builder: (context, _) {
      final store = widget.store;
      final source = store.catalog.source;
      final online = source.onlineSearch && !store.offline;
      final rows = _search.query.isEmpty
          ? const <Drama>[]
          : queryCatalog(
              _search.results ?? store.catalog.cachedDramas(source),
              query: _search.results == null ? _search.query : '',
              hideVip: source == DramaSource.huangdou && store.catalog.hideVip,
            );
      return Scaffold(
        appBar: AppBar(title: const Text('搜索')),
        body: SafeArea(
          child: CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _search.input,
                        autofocus: widget.autofocus,
                        onSubmitted: _submit,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: '输入剧名',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_search.input.text.isNotEmpty)
                                IconButton(
                                  tooltip: '清空搜索',
                                  onPressed: _search.input.clear,
                                  icon: const Icon(Icons.close),
                                ),
                              if (_search.loading)
                                const Padding(
                                  padding: EdgeInsets.all(15),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              else
                                IconButton(
                                  tooltip: online ? '联网搜索' : '筛选缓存',
                                  onPressed: () => _submit(_search.input.text),
                                  icon: const Icon(Icons.arrow_forward),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SourceSelector(
                            preferences: store.preferences,
                            catalog: store.catalog,
                            value: source,
                            onChanged: (target) {
                              if (target == null) return;
                              if (_scroll.hasClients) _scroll.jumpTo(0);
                              perform(
                                context,
                                () => store.catalog.selectSource(target),
                              );
                            },
                          ),
                          Text(
                            online
                                ? '联网搜索当前站源'
                                : store.offline
                                ? '离线搜索 · 仅查找已保存的剧集资料'
                                : '当前站源仅支持本地搜索',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (source == DramaSource.huangdou)
                            FilterChip(
                              label: Text(
                                store.catalog.hideVip ? '隐藏 VIP' : '显示 VIP',
                              ),
                              selected: store.catalog.hideVip,
                              onSelected: (value) => perform(
                                context,
                                () => store.catalog.setHideVip(value),
                              ),
                            ),
                        ],
                      ),
                      if (_search.suggestions.isNotEmpty)
                        Card(
                          margin: const EdgeInsets.only(top: 12),
                          child: Column(
                            children: [
                              for (final suggestion in _search.suggestions.take(
                                6,
                              ))
                                ListTile(
                                  leading: const Icon(Icons.search),
                                  title: Text(
                                    suggestion,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Icon(Icons.north_west),
                                  onTap: () => _submit(suggestion),
                                ),
                            ],
                          ),
                        ),
                      if (_search.query.isEmpty &&
                          store.catalog.recentSearches.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '最近搜索',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            IconButton(
                              tooltip: '清除搜索记录',
                              onPressed: () =>
                                  perform(context, store.catalog.clearSearches),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final query in store.catalog.recentSearches)
                              ActionChip(
                                label: Text(query),
                                onPressed: () => _submit(query),
                              ),
                          ],
                        ),
                      ],
                      if (_search.query.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          _search.results == null ? '本地匹配' : '搜索结果',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (_search.fromCache)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('本页来自缓存'),
                          ),
                      ],
                      if (_search.notice != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_search.notice!),
                        ),
                      if (_search.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _search.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (store.persistenceError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(store.persistenceError!),
                        ),
                      if (store.cachePersistenceError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(store.cachePersistenceError!),
                        ),
                    ],
                  ),
                ),
              ),
              if (_search.query.isNotEmpty && rows.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: _search.loading
                        ? Icons.travel_explore
                        : Icons.search_off,
                    title: _search.loading ? '正在搜索…' : '暂时没有找到',
                    message: _search.loading
                        ? '正在查找当前站源，结果会陆续显示'
                        : online
                        ? '换个关键词，或点击搜索继续查找'
                        : '换个关键词，仅查找已保存的剧集资料',
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.crossAxisExtent / 165)
                        .floor()
                        .clamp(2, 7);
                    return TelevisionGrid(
                      key: _results,
                      itemKeys: [for (final drama in rows) drama.key],
                      columns: columns,
                      mainAxisExtent:
                          (constraints.crossAxisExtent - (columns - 1) * 14) /
                          columns /
                          .61,
                      itemBuilder: (context, index) {
                        final drama = store.catalog.currentDrama(rows[index]);
                        return DramaCard(
                          drama: drama,
                          onTap: () {
                            if (!TelevisionScope.of(context)) {
                              FocusScope.of(context).unfocus();
                            }
                            widget.onOpen(drama);
                          },
                          favorite: store.records.favorites.containsKey(
                            drama.key,
                          ),
                          onFavorite: () => perform(
                            context,
                            () => store.records.toggleFavorite(drama),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              if (_search.query.isNotEmpty &&
                  (_search.hasMore || _search.error != null))
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Center(
                      child: OutlinedButton(
                        onPressed: _search.loading
                            ? null
                            : _search.error != null
                            ? _search.retry
                            : _search.loadMore,
                        child: Text(
                          _search.loading
                              ? '正在搜索…'
                              : _search.error != null
                              ? '重试搜索'
                              : '加载更多结果',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
