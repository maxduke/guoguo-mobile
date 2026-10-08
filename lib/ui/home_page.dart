import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/app_startup.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../domain/catalog_query.dart';
import 'components.dart';
import 'search_page.dart';
import 'source_selector.dart';
import 'detail_page.dart';
import 'personal_page.dart';
import 'continue_watching_card.dart';
import 'downloads_page.dart';
import 'settings_page.dart';
import 'rankings_page.dart';
import 'recommendations_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.store,
    required this.downloads,
    this.autoLoad = true,
    this.startup,
  });
  final AppStore store;
  final DownloadStore downloads;
  final bool autoLoad;
  final AppStartup? startup;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  bool _resuming = false;
  bool _routeActive = true;
  int _resumeGeneration = 0;
  void _cancelResume() {
    _resumeGeneration++;
    _resuming = false;
  }

  String _category = '全部';
  CatalogSort _sort = CatalogSort.recommended;
  AppStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialCatalog();
  }

  void _loadInitialCatalog() {
    if (widget.autoLoad) {
      if (store.catalog.library.isEmpty) {
        unawaited(store.catalog.refresh());
      } else {
        unawaited(store.catalog.loadCategories());
      }
    }
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      oldWidget.store.records.cancelUpdateChecks();
      _category = '全部';
      _loadInitialCatalog();
    }
    if (oldWidget.store != store || oldWidget.downloads != widget.downloads) {
      _cancelResume();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = ModalRoute.of(context)?.isCurrent != false;
    if (_routeActive && !active) _cancelResume();
    _routeActive = active;
  }

  @override
  void dispose() {
    store.records.cancelUpdateChecks();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _open(Drama drama) {
    setState(_cancelResume);
    store.records.cancelUpdateChecks();
    openDrama(context, store, widget.downloads, drama);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) store.records.cancelUpdateChecks();
  }

  Future<void> _openSearch() async {
    setState(_cancelResume);
    final owner = store, downloads = widget.downloads;
    final initialSource = owner.catalog.source;
    owner.records.cancelUpdateChecks();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) => SearchPage(
          store: owner,
          onOpen: (drama) {
            owner.records.cancelUpdateChecks();
            openDrama(routeContext, owner, downloads, drama);
          },
        ),
      ),
    );
    if (mounted && store == owner && widget.downloads == downloads) {
      if (owner.catalog.source != initialSource) {
        setState(() => _category = '全部');
      }
      _loadInitialCatalog();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: wide ? 32 : 22,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: Theme.of(context).colorScheme.onPrimary,
                size: 28,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              '果果',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 23,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '好故事，接着看',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () {
              setState(_cancelResume);
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SettingsPage(store: store, downloads: widget.downloads),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([
              store,
              if (widget.startup != null) widget.startup!,
            ]),
            builder: (context, _) => Column(
              children: [
                if (widget.startup?.coreLoading == true)
                  const _Notice('正在连接站源，可先浏览已有记录', Icons.hourglass_top_rounded),
                if (widget.startup?.coreError != null)
                  _Notice(
                    widget.startup!.coreError!,
                    Icons.warning_amber_rounded,
                    retryLabel: '重试站源',
                    onRetry: () => unawaited(widget.startup!.retryCore()),
                  ),
                if (widget.startup?.networkError != null)
                  _Notice(
                    widget.startup!.networkError!,
                    Icons.wifi_off_rounded,
                    retryLabel: '重试网络',
                    onRetry: widget.startup!.networkLoading
                        ? null
                        : () => unawaited(widget.startup!.retryNetwork()),
                  ),
                if (store.offline)
                  const _Notice(
                    '当前离线 · 可以浏览缓存与观看已下载分集',
                    Icons.wifi_off_rounded,
                  ),
                if (store.persistenceError != null)
                  _Notice(store.persistenceError!, Icons.warning_amber_rounded),
                if (store.cachePersistenceError != null)
                  _Notice(
                    store.cachePersistenceError!,
                    Icons.warning_amber_rounded,
                  ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([store.catalog, store]),
                  builder: (context, _) => _library(wide),
                ),
                PersonalPage(
                  store: store,
                  downloads: widget.downloads,
                  active: _tab == 1 && _routeActive,
                ),
                DownloadsPage(
                  store: store,
                  downloads: widget.downloads,
                  onOpen: _open,
                  active: _tab == 2 && _routeActive,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (v) {
          if (v != _tab) store.records.cancelUpdateChecks();
          setState(() {
            _cancelResume();
            _tab = v;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: '剧库',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmarks_outlined),
            selectedIcon: Icon(Icons.bookmarks_rounded),
            label: '追剧',
          ),
          NavigationDestination(
            icon: Icon(Icons.downloading_outlined),
            selectedIcon: Icon(Icons.downloading_rounded),
            label: '下载',
          ),
        ],
      ),
    );
  }

  Widget _sortMenu() => PopupMenuButton<CatalogSort>(
    initialValue: _sort,
    tooltip: '排序短剧',
    onSelected: (sort) => setState(() => _sort = sort),
    itemBuilder: (_) => [
      for (final sort in CatalogSort.values)
        PopupMenuItem(value: sort, child: Text(sort.label)),
    ],
    child: Chip(
      avatar: const Icon(Icons.sort, size: 18),
      label: Text(_sort.label),
    ),
  );

  void _discover() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => RecommendationsPage(store: store, onOpen: _open),
    ),
  );

  Widget _library(bool wide) {
    final rows = queryCatalog(
      store.catalog.library,
      category: store.catalog.source.remoteCategories ? '全部' : _category,
      hideVip:
          store.catalog.source == DramaSource.huangdou && store.catalog.hideVip,
      sort: _sort,
    );
    final categories = {
      '全部',
      ...store.catalog.library
          .map((d) => d.category)
          .where((s) => s.isNotEmpty),
    }.toList();
    final loading = store.catalog.libraryLoading;
    final horizontal = wide ? 40.0 : 22.0;
    return RefreshIndicator(
      onRefresh: () => store.catalog.refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter < 700 &&
              !store.catalog.libraryCanRetry) {
            unawaited(store.catalog.loadMore());
          }
          return false;
        },
        child: CustomScrollView(
          key: PageStorageKey(
            'library-${store.catalog.source.name}-${store.catalog.selectedCategory}',
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 0),
              sliver: SliverList.list(
                children: [
                  Row(
                    children: [
                      Text(
                        '发现好剧',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const Spacer(),
                      if (wide && store.catalog.source == DramaSource.hongguo)
                        TextButton.icon(
                          onPressed: _discover,
                          icon: const Icon(
                            Icons.auto_awesome_outlined,
                            size: 19,
                          ),
                          label: const Text('发现推荐'),
                        ),
                      if (store.catalog.source.rankings)
                        TextButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  RankingsPage(store: store, onOpen: _open),
                            ),
                          ),
                          icon: const Icon(Icons.bar_chart_rounded, size: 19),
                          label: const Text('榜单'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SourceSelector(
                    value: store.catalog.source,
                    onChanged: (source) {
                      if (source == null) return;
                      setState(_cancelResume);
                      unawaited(
                        perform(context, () async {
                          _category = '全部';
                          await store.catalog.selectSource(source);
                          if (store.catalog.library.isEmpty) {
                            await store.catalog.refresh(source);
                          } else {
                            await store.catalog.loadCategories(source);
                          }
                        }),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: _openSearch,
                    icon: const Icon(Icons.search),
                    label: const Text('搜索剧名'),
                  ),
                  const SizedBox(height: 16),
                  if (!wide && store.catalog.source == DramaSource.hongguo) ...[
                    Card(
                      margin: const EdgeInsets.only(bottom: 18),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => RecommendationsPage(
                              store: store,
                              onOpen: _open,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            children: [
                              Icon(
                                Icons.auto_awesome_outlined,
                                color: Theme.of(context).colorScheme.primary,
                                size: 28,
                              ),
                              const SizedBox(width: 14),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '今天，看点什么',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      '真人剧 · 漫剧 · AI 剧',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.arrow_forward_rounded),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      store.records,
                      store.records.progress,
                    ]),
                    builder: (context, _) {
                      final recent = store.records.continuable;
                      return recent.isEmpty
                          ? const SizedBox.shrink()
                          : Column(
                              children: [
                                _continueCard(recent.first),
                                const SizedBox(height: 22),
                              ],
                            );
                    },
                  ),
                  Row(
                    children: [
                      Text(
                        '全部短剧',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      if (loading)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          tooltip: '更新当前站源',
                          onPressed: () => store.catalog.refresh(),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      Text(
                        '已加载 ${rows.length} 部',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (!wide || categories.length <= 1) _sortMenu(),
                      if (store.catalog.source == DramaSource.huangdou)
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
                  if (store.catalog.source == DramaSource.huangdou &&
                      store.catalog.library.any((d) => d.vip == null))
                    Text(
                      '部分剧集会员状态待识别，打开详情后更新',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (store.catalog.source.remoteCategories)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final category
                              in store.catalog.sourceCategories[store
                                      .catalog
                                      .source] ??
                                  [const SourceCategory('', '全部')])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(category.name),
                                selected:
                                    store.catalog.selectedCategory ==
                                    category.id,
                                onSelected: (_) => perform(
                                  context,
                                  () =>
                                      store.catalog.selectCategory(category.id),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (store.catalog.categoryErrors.containsKey(
                    store.catalog.source,
                  ))
                    _Notice(
                      store.catalog.categoryErrors[store.catalog.source]!,
                      Icons.cloud_off_outlined,
                      onRetry: store.offline || store.catalog.categoriesLoading
                          ? null
                          : () => store.catalog.loadCategories(),
                      retryLabel: '重试加载分类',
                    ),
                  if (!store.catalog.source.remoteCategories &&
                      categories.length > 1)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (wide) ...[_sortMenu(), const SizedBox(width: 12)],
                          for (final category in categories)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(category),
                                selected: _category == category,
                                onSelected: (_) =>
                                    setState(() => _category = category),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (store.catalog.libraryError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _Notice(
                        store.catalog.libraryError!,
                        Icons.cloud_off_outlined,
                        onRetry:
                            store.catalog.library.isEmpty &&
                                store.catalog.libraryCanRetry &&
                                !store.offline &&
                                !loading
                            ? store.catalog.retryLibrary
                            : null,
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            if (rows.isEmpty)
              SliverToBoxAdapter(
                child: EmptyState(
                  icon: loading
                      ? Icons.travel_explore
                      : Icons.movie_filter_outlined,
                  title: loading ? '正在找寻好故事' : '你的下一部好剧，在这里',
                  message: loading
                      ? '首次加载需要一点时间，内容会保存在设备上'
                      : '轻点更新，加载${store.catalog.source.label}剧库',
                  action:
                      loading || store.offline || store.catalog.libraryCanRetry
                      ? null
                      : FilledButton.icon(
                          onPressed: () => store.catalog.refresh(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('更新剧库'),
                        ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 28),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.crossAxisExtent / 165)
                        .floor()
                        .clamp(2, 7);
                    return SliverGrid.builder(
                      itemCount: rows.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 22,
                        crossAxisSpacing: 14,
                        childAspectRatio: .61,
                      ),
                      itemBuilder: (context, index) => ListenableBuilder(
                        listenable: store.records,
                        builder: (context, _) => DramaCard(
                          drama: rows[index],
                          onTap: () => _open(rows[index]),
                          favorite: store.records.favorites.containsKey(
                            rows[index].key,
                          ),
                          onFavorite: () => perform(
                            context,
                            () => store.records.toggleFavorite(rows[index]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (store.catalog.library.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Center(
                    child: Column(
                      children: [
                        Text(
                          '已加载 ${store.catalog.library.length} 部 · ${store.catalog.libraryCanRetry
                              ? "等待重试"
                              : store.catalog.libraryHasMore
                              ? "继续下滑加载"
                              : "当前来源已返回完毕"}',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '已加载数量不代表全站总量',
                          style: TextStyle(fontSize: 12),
                        ),
                        if (store.catalog.libraryHasMore ||
                            store.catalog.libraryCanRetry)
                          OutlinedButton.icon(
                            onPressed: loading || store.offline
                                ? null
                                : store.catalog.libraryCanRetry
                                ? store.catalog.retryLibrary
                                : store.catalog.loadMore,
                            icon: loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    store.catalog.libraryCanRetry
                                        ? Icons.refresh
                                        : Icons.expand_more,
                                  ),
                            label: Text(
                              loading
                                  ? '正在加载…'
                                  : store.catalog.libraryCanRetry
                                  ? '重试加载剧库'
                                  : '加载更多短剧',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _continue(WatchRecord record) async {
    if (_resuming) return;
    final generation = ++_resumeGeneration;
    final owner = store, downloads = widget.downloads;
    bool active() =>
        mounted &&
        _tab == 0 &&
        generation == _resumeGeneration &&
        store == owner &&
        widget.downloads == downloads;
    store.records.cancelUpdateChecks();
    setState(() => _resuming = true);
    await perform(
      context,
      () => continueDrama(context, owner, downloads, record, isActive: active),
    );
    if (active()) setState(() => _resuming = false);
  }

  Widget _continueCard(WatchRecord record) => ContinueWatchingCard(
    records: store.records,
    record: record,
    busy: _resuming,
    onContinue: _resuming ? null : () => _continue(record),
    onDetails: () => _open(record.drama),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(
    this.message,
    this.icon, {
    this.onRetry,
    this.retryLabel = '重试',
  });
  final String message;
  final IconData icon;
  final VoidCallback? onRetry;
  final String retryLabel;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.secondaryContainer.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 9),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
      ],
    ),
  );
}
