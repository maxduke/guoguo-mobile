import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../domain/catalog_query.dart';
import '../domain/models.dart';
import 'components.dart';
import 'source_selector.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.store,
    required this.onOpen,
    required this.onSearch,
    this.autoLoad = true,
  });
  final AppStore store;
  final ValueChanged<Drama> onOpen;
  final VoidCallback onSearch;
  final bool autoLoad;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late DramaSource _source = widget.store.catalog.source;
  String _category = '全部';
  CatalogSort _sort = CatalogSort.recommended;
  bool _routeActive = true;

  @override
  void initState() {
    super.initState();
    widget.store.catalog.addListener(_sourceChanged);
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    oldWidget.store.catalog.removeListener(_sourceChanged);
    widget.store.catalog.addListener(_sourceChanged);
    _source = widget.store.catalog.source;
    _category = '全部';
    _sort = CatalogSort.recommended;
    _scheduleInitial();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive = ModalRoute.of(context)?.isCurrent != false;
    _scheduleInitial();
  }

  void _scheduleInitial() {
    if (widget.autoLoad) unawaited(Future<void>.microtask(_ensureCatalog));
  }

  Future<void> _ensureCatalog() async {
    if (!mounted || !_routeActive || widget.store.offline) return;
    final catalog = widget.store.catalog;
    if (!catalog.libraryLoaded) {
      await catalog.refresh();
    } else if (catalog.source.remoteCategories &&
        !catalog.sourceCategories.containsKey(catalog.source)) {
      await catalog.loadCategories();
    }
  }

  void _sourceChanged() {
    if (!mounted || _source == widget.store.catalog.source) return;
    setState(() {
      _source = widget.store.catalog.source;
      _category = '全部';
    });
    _scheduleInitial();
  }

  @override
  void dispose() {
    widget.store.catalog.removeListener(_sourceChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store.catalog, widget.store]),
    builder: (context, _) {
      final store = widget.store, catalog = store.catalog;
      final source = catalog.source;
      final rows = queryCatalog(
        catalog.library,
        category: source.remoteCategories ? '全部' : _category,
        hideVip: source == DramaSource.huangdou && catalog.hideVip,
        sort: _sort,
      );
      final categories = {
        '全部',
        ...catalog.library
            .map((row) => row.category)
            .where((v) => v.isNotEmpty),
      };
      final loading = catalog.libraryLoading;
      final horizontal = MediaQuery.sizeOf(context).width >= 900 ? 40.0 : 22.0;
      final filtered =
          _category != '全部' ||
          catalog.selectedCategory.isNotEmpty ||
          _sort != CatalogSort.recommended;
      return Scaffold(
        appBar: AppBar(
          title: Text('${source.label}剧库'),
          actions: [
            IconButton(
              tooltip: '搜索剧名',
              onPressed: widget.onSearch,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: catalog.refresh,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification is ScrollUpdateNotification &&
                    notification.metrics.extentAfter < 700 &&
                    catalog.libraryHasMore &&
                    !catalog.libraryCanRetry &&
                    !loading &&
                    !store.offline) {
                  unawaited(catalog.loadMore());
                }
                return false;
              },
              child: CustomScrollView(
                key: PageStorageKey(
                  'library-${source.name}-${catalog.selectedCategory}',
                ),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 12),
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
                                value: source,
                                onChanged: (target) {
                                  if (target == null) return;
                                  perform(context, () async {
                                    await catalog.selectSource(target);
                                    if (mounted &&
                                        widget.store == store &&
                                        catalog.source == target) {
                                      await _ensureCatalog();
                                    }
                                  });
                                },
                              ),
                              IconButton(
                                tooltip: '更新当前站源',
                                onPressed: loading || store.offline
                                    ? null
                                    : catalog.refresh,
                                icon: const Icon(Icons.refresh),
                              ),
                              Text(
                                catalog.libraryLoaded
                                    ? '已加载 ${catalog.library.length} 部'
                                    : '已保存 ${catalog.library.length} 部资料',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          ExpansionTile(
                            key: const PageStorageKey('library-filters'),
                            tilePadding: EdgeInsets.zero,
                            title: Text(filtered ? '筛选 · 已调整' : '筛选'),
                            maintainState: true,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final sort in CatalogSort.values)
                                    ChoiceChip(
                                      label: Text(sort.label),
                                      selected: sort == _sort,
                                      onSelected: (_) =>
                                          setState(() => _sort = sort),
                                    ),
                                  if (source == DramaSource.huangdou)
                                    FilterChip(
                                      label: Text(
                                        catalog.hideVip ? '隐藏 VIP' : '显示 VIP',
                                      ),
                                      selected: catalog.hideVip,
                                      onSelected: (value) => perform(
                                        context,
                                        () => catalog.setHideVip(value),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (source.remoteCategories)
                                    for (final category in [
                                      const SourceCategory('', '全部'),
                                      ...?catalog.sourceCategories[source]
                                          ?.where(
                                            (category) =>
                                                category.id.isNotEmpty,
                                          ),
                                    ])
                                      ChoiceChip(
                                        label: Text(category.name),
                                        selected:
                                            catalog.selectedCategory ==
                                            category.id,
                                        onSelected: (_) => perform(
                                          context,
                                          () => catalog.selectCategory(
                                            category.id,
                                          ),
                                        ),
                                      )
                                  else
                                    for (final category in categories)
                                      ChoiceChip(
                                        label: Text(category),
                                        selected: _category == category,
                                        onSelected: (_) => setState(
                                          () => _category = category,
                                        ),
                                      ),
                                ],
                              ),
                              if (source == DramaSource.huangdou &&
                                  catalog.library.any((row) => row.vip == null))
                                const Text('部分会员状态待识别，打开详情后更新'),
                              const SizedBox(height: 12),
                            ],
                          ),
                          if (store.offline) const Text('当前离线 · 仅显示已保存内容'),
                          if (catalog.categoryErrors[source] != null)
                            _LibraryNotice(
                              catalog.categoryErrors[source]!,
                              onRetry:
                                  store.offline || catalog.categoriesLoading
                                  ? null
                                  : catalog.loadCategories,
                              retryLabel: '重试加载分类',
                            ),
                          if (catalog.libraryError != null)
                            _LibraryNotice(
                              catalog.libraryError!,
                              onRetry:
                                  !store.offline &&
                                      !loading &&
                                      catalog.libraryCanRetry
                                  ? catalog.retryLibrary
                                  : null,
                              retryLabel: '重试加载剧库',
                            ),
                          if (store.persistenceError != null)
                            Text(store.persistenceError!),
                          if (store.cachePersistenceError != null)
                            Text(store.cachePersistenceError!),
                          if (loading) const LinearProgressIndicator(),
                        ],
                      ),
                    ),
                  ),
                  if (rows.isEmpty)
                    SliverToBoxAdapter(
                      child: EmptyState(
                        icon: loading
                            ? Icons.travel_explore
                            : Icons.movie_outlined,
                        title: loading
                            ? '正在加载剧库'
                            : filtered
                            ? '当前筛选没有作品'
                            : '当前目录没有作品',
                        message: store.offline
                            ? '联网后可加载当前站源目录'
                            : filtered
                            ? '展开筛选，换个分类或排序'
                            : '可更新剧库，或搜索剧名',
                        action:
                            !store.offline &&
                                !loading &&
                                !catalog.libraryCanRetry
                            ? OutlinedButton(
                                onPressed: catalog.refresh,
                                child: const Text('更新剧库'),
                              )
                            : null,
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 24),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) => SliverGrid.builder(
                        itemCount: rows.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: (constraints.crossAxisExtent / 165)
                              .floor()
                              .clamp(2, 7),
                          mainAxisSpacing: 22,
                          crossAxisSpacing: 14,
                          childAspectRatio: .61,
                        ),
                        itemBuilder: (context, index) => ListenableBuilder(
                          listenable: store.records,
                          builder: (context, _) => DramaCard(
                            drama: rows[index],
                            onTap: () => widget.onOpen(rows[index]),
                            favorite: store.records.favorites.containsKey(
                              rows[index].key,
                            ),
                            onFavorite: () => perform(
                              context,
                              () => store.records.toggleFavorite(rows[index]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 24),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        children: [
                          Text(
                            !catalog.libraryLoaded
                                ? '已保存资料 · 尚未取得当前目录'
                                : catalog.libraryCanRetry
                                ? '目录加载未完成 · 等待重试'
                                : catalog.libraryHasMore
                                ? '继续下滑加载目录'
                                : '本轮目录已返回完毕',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          const Text('已加载数量不代表全站总量'),
                          if (catalog.libraryHasMore)
                            OutlinedButton.icon(
                              onPressed:
                                  loading ||
                                      store.offline ||
                                      catalog.libraryCanRetry
                                  ? null
                                  : catalog.loadMore,
                              icon: const Icon(Icons.expand_more),
                              label: Text(loading ? '正在加载…' : '加载更多短剧'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _LibraryNotice extends StatelessWidget {
  const _LibraryNotice(this.message, {this.onRetry, required this.retryLabel});
  final String message, retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
      ],
    ),
  );
}
