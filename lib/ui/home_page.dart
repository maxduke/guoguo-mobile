import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../domain/catalog_query.dart';
import 'components.dart';
import 'source_selector.dart';
import 'detail_page.dart';
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
  });
  final AppStore store;
  final DownloadStore downloads;
  final bool autoLoad;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  bool _resuming = false;
  final _search = TextEditingController();
  String _query = '', _category = '全部';
  DramaSource? _personalSource;
  bool _favoritesOnly = true, _searching = false;
  int _searchGeneration = 0, _searchPage = 0;
  bool _searchHasMore = false;
  String? _searchError, _searchNotice;
  Timer? _suggestionTimer;
  String? _activeSearchId, _activeSearchQuery;
  DramaSource? _activeSearchSource;
  void _cancelSearch() {
    final id = _activeSearchId;
    if (id != null) {
      unawaited(
        store.cancelSearch(_activeSearchSource!, _activeSearchQuery!, id),
      );
    }
    _activeSearchId = null;
  }

  List<String> _suggestions = [];
  List<Drama>? _remoteResults;
  CatalogSort _sort = CatalogSort.recommended;
  AppStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _search.addListener(_queryChanged);
    if (widget.autoLoad) {
      if (store.library.isEmpty) {
        unawaited(store.refresh());
      } else {
        unawaited(store.loadCategories());
      }
    }
  }

  @override
  void dispose() {
    store.cancelUpdateChecks();
    WidgetsBinding.instance.removeObserver(this);
    _cancelSearch();
    _suggestionTimer?.cancel();
    _search.removeListener(_queryChanged);
    _search.dispose();
    super.dispose();
  }

  void _open(Drama drama) {
    store.cancelUpdateChecks();
    openDrama(context, store, widget.downloads, drama);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) store.cancelUpdateChecks();
  }

  void _queryChanged() {
    _cancelSearch();
    _suggestionTimer?.cancel();
    final generation = ++_searchGeneration;
    setState(() {
      _query = _search.text.trim();
      _remoteResults = null;
      _searchPage = 0;
      _searchHasMore = false;
      _suggestions = [];
      _searchNotice = null;
      _searchError = null;
      _searching = false;
      if (_query.isNotEmpty) _category = '全部';
    });
    if (_query.isEmpty ||
        store.source != DramaSource.hongguo ||
        store.offline ||
        !_search.value.composing.isCollapsed) {
      return;
    }
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final items = await store.suggestions(_query);
        if (mounted && generation == _searchGeneration) {
          setState(() => _suggestions = items);
        }
      } catch (_) {
        /* Explicit search remains available. */
      }
    });
  }

  Future<void> _submit(String text, {bool more = false}) async {
    if (more && (_searching || !_searchHasMore)) return;
    final page = more ? _searchPage + 1 : 1;
    if (text.trim().isEmpty || !_search.value.composing.isCollapsed) return;
    if (_search.text != text) {
      _search.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _suggestionTimer?.cancel();
    final generation = ++_searchGeneration;
    final source = store.source;
    _cancelSearch();
    final id = 'home-$generation-${DateTime.now().microsecondsSinceEpoch}';
    _activeSearchId = id;
    _activeSearchQuery = text.trim();
    _activeSearchSource = source;
    FocusScope.of(context).unfocus();
    setState(() {
      _query = text.trim();
      _suggestions = [];
      _searching = source.onlineSearch && !store.offline;
      _searchError = null;
      _searchNotice = null;
    });
    if (!source.onlineSearch || store.offline) return;
    try {
      final result = await store.searchCatalog(
        source,
        text,
        page: page,
        requestId: id,
        onPartial: (partial) {
          if (!mounted ||
              generation != _searchGeneration ||
              source != store.source) {
            return;
          }
          setState(() {
            _remoteResults = partial.items;
            _searchNotice = "正在补全结果…";
          });
        },
      );
      if (mounted &&
          generation == _searchGeneration &&
          source == store.source) {
        setState(() {
          _remoteResults = {
            for (final row in [
              ...(more ? _remoteResults ?? <Drama>[] : <Drama>[]),
              ...result.items,
            ])
              row.key: row,
          }.values.toList();
          _searchPage = page;
          _searchHasMore = result.hasMore;
          _searchNotice = result.warning.isNotEmpty
              ? result.warning
              : result.limited
              ? '已合并名称检索与官网结果；上游未提供完整分页，可用完整剧名继续查找。'
              : source == DramaSource.huangguo
              ? '在线检索范围：黄果 AI'
              : null;
        });
      }
    } catch (error) {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searchError = '$error');
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
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
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SettingsPage(store: store, downloads: widget.downloads),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Column(
          children: [
            if (store.offline)
              const _Notice('当前离线 · 可以浏览缓存与观看已下载分集', Icons.wifi_off_rounded),
            if (store.persistenceError != null)
              _Notice(store.persistenceError!, Icons.warning_amber_rounded),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _library(wide),
                  _personal(wide),
                  DownloadsPage(
                    store: store,
                    downloads: widget.downloads,
                    onOpen: _open,
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (v) {
            if (v != _tab) store.cancelUpdateChecks();
            setState(() => _tab = v);
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
    },
  );

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
      _remoteResults ?? store.library,
      query: _remoteResults == null ? _query : '',
      category: store.source.remoteCategories ? '全部' : _category,
      hideVip: store.source == DramaSource.huangdou && store.hideVip,
      sort: _sort,
    );
    final categories = {
      '全部',
      ...store.library.map((d) => d.category).where((s) => s.isNotEmpty),
    }.toList();
    final loading = store.libraryLoading;
    final horizontal = wide ? 40.0 : 22.0;
    return RefreshIndicator(
      onRefresh: () => store.refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter < 700 &&
              _query.isEmpty &&
              store.libraryError == null) {
            unawaited(store.loadMore());
          }
          return false;
        },
        child: CustomScrollView(
          key: PageStorageKey(
            'library-${store.source.name}-${store.selectedCategory}',
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
                      if (wide && store.source == DramaSource.hongguo)
                        TextButton.icon(
                          onPressed: _discover,
                          icon: const Icon(
                            Icons.auto_awesome_outlined,
                            size: 19,
                          ),
                          label: const Text('发现推荐'),
                        ),
                      if (store.source.rankings)
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
                    value: store.source,
                    onChanged: (source) {
                      if (source == null) return;
                      unawaited(
                        perform(context, () async {
                          _cancelSearch();
                          _search.clear();
                          ++_searchGeneration;
                          setState(() {
                            _query = '';
                            _category = '全部';
                            _remoteResults = null;
                            _searchError = null;
                            _searchNotice = null;
                            _searching = false;
                            _searchHasMore = false;
                            _searchPage = 0;
                          });
                          await store.selectSource(source);
                          if (store.library.isEmpty) {
                            await store.refresh(source);
                          } else {
                            await store.loadCategories(source);
                          }
                        }),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _search,
                    onSubmitted: _submit,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜索${store.source.label}短剧，找到下一部心动',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(15),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_search.text.isNotEmpty)
                                  IconButton(
                                    tooltip: '清空搜索',
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () => setState(() {
                                      _search.clear();
                                      _query = '';
                                      _searchError = null;
                                      _remoteResults = null;
                                      _searchPage = 0;
                                      _searchHasMore = false;
                                      _searching = false;
                                      ++_searchGeneration;
                                    }),
                                  ),
                                IconButton(
                                  tooltip: store.source.onlineSearch
                                      ? '联网搜索'
                                      : '筛选缓存',
                                  icon: const Icon(Icons.arrow_forward_rounded),
                                  onPressed: () => _submit(_search.text),
                                ),
                              ],
                            ),
                    ),
                  ),
                  if (_query.isNotEmpty &&
                      (!store.source.onlineSearch || store.offline))
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        store.offline
                            ? '离线搜索 · 仅显示已缓存的短剧'
                            : '${store.source.label}暂不支持联网搜索，当前筛选已加载内容',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (_suggestions.isNotEmpty)
                    Card(
                      margin: const EdgeInsets.only(top: 8),
                      child: Column(
                        children: [
                          for (final suggestion in _suggestions.take(6))
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.search, size: 18),
                              title: Text(
                                suggestion,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.north_west, size: 16),
                              onTap: () => _submit(suggestion),
                            ),
                        ],
                      ),
                    ),
                  if (_query.isEmpty &&
                      store.source.onlineSearch &&
                      store.recentSearches.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final query in store.recentSearches.take(5))
                            ActionChip(
                              label: Text(query),
                              onPressed: () => _submit(query),
                            ),
                          IconButton(
                            tooltip: '清除搜索记录',
                            onPressed: () =>
                                perform(context, store.clearSearches),
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ],
                      ),
                    ),
                  if (_searchNotice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _Notice(_searchNotice!, Icons.info_outline),
                    ),
                  if (_searchError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _Notice(_searchError!, Icons.info_outline_rounded),
                    ),
                  if (_query.isEmpty) ...[const SizedBox(height: 16)],
                  if (!wide &&
                      _query.isEmpty &&
                      store.source == DramaSource.hongguo) ...[
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
                  if (_query.isEmpty && store.recent.isNotEmpty) ...[
                    _continueCard(store.recent.first),
                    const SizedBox(height: 22),
                  ],
                  Row(
                    children: [
                      Text(
                        _query.isEmpty
                            ? '全部短剧'
                            : _remoteResults == null
                            ? '本地匹配'
                            : '联网结果',
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
                          onPressed: () => store.refresh(),
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
                      if (store.source == DramaSource.huangdou)
                        FilterChip(
                          label: Text(store.hideVip ? '隐藏 VIP' : '显示 VIP'),
                          selected: store.hideVip,
                          onSelected: (value) =>
                              perform(context, () => store.setHideVip(value)),
                        ),
                      if (_category != '全部' && _query.isNotEmpty)
                        TextButton(
                          onPressed: () => setState(() => _category = '全部'),
                          child: const Text('清除分类筛选'),
                        ),
                    ],
                  ),
                  if (store.source == DramaSource.huangdou &&
                      store.library.any((d) => d.vip == null))
                    Text(
                      '部分剧集会员状态待识别，打开详情后更新',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (store.source.remoteCategories && _query.isEmpty)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final category
                              in store.sourceCategories[store.source] ??
                                  [const SourceCategory('', '全部')])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(category.name),
                                selected: store.selectedCategory == category.id,
                                onSelected: (_) => perform(
                                  context,
                                  () => store.selectCategory(category.id),
                                ),
                              ),
                            ),
                          if (store.categoryErrors.containsKey(store.source))
                            TextButton(
                              onPressed: () => store.loadCategories(),
                              child: const Text('重试加载分类'),
                            ),
                        ],
                      ),
                    ),
                  if (!store.source.remoteCategories && categories.length > 1)
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
                  if (store.libraryError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _Notice(
                        store.libraryError!,
                        Icons.cloud_off_outlined,
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
                  title: loading
                      ? '正在找寻好故事'
                      : _query.isNotEmpty
                      ? '暂时没有找到'
                      : '你的下一部好剧，在这里',
                  message: loading
                      ? '首次加载需要一点时间，内容会保存在设备上'
                      : _query.isNotEmpty
                      ? '换个关键词，或点击搜索联网查找'
                      : '轻点更新，加载${store.source.label}剧库',
                  action: loading
                      ? null
                      : FilledButton.icon(
                          onPressed: () => store.refresh(),
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
                      itemBuilder: (context, index) => DramaCard(
                        drama: rows[index],
                        onTap: () => _open(rows[index]),
                        favorite: store.favorites.containsKey(rows[index].key),
                        onFavorite: () => perform(
                          context,
                          () => store.toggleFavorite(rows[index]),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_query.isNotEmpty &&
                store.source.onlineSearch &&
                (_searchHasMore || _searchError != null))
              SliverToBoxAdapter(
                child: Center(
                  child: OutlinedButton(
                    onPressed: _searching
                        ? null
                        : () => _submit(
                            _query,
                            more: _searchPage > 0 && _searchHasMore,
                          ),
                    child: Text(
                      _searching
                          ? '正在搜索…'
                          : _searchError != null
                          ? '重试搜索'
                          : '加载更多结果',
                    ),
                  ),
                ),
              ),
            if (store.library.isNotEmpty && _query.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Center(
                    child: Column(
                      children: [
                        Text(
                          '已加载 ${store.library.length} 部 · ${store.libraryHasMore ? "继续下滑加载" : "当前来源已返回完毕"}',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '已加载数量不代表全站总量',
                          style: TextStyle(fontSize: 12),
                        ),
                        if (store.libraryHasMore)
                          OutlinedButton.icon(
                            onPressed: loading ? null : store.loadMore,
                            icon: loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.expand_more),
                            label: Text(loading ? '正在加载…' : '加载更多短剧'),
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
    store.cancelUpdateChecks();
    setState(() => _resuming = true);
    await perform(
      context,
      () => continueDrama(context, store, widget.downloads, record),
    );
    if (mounted) setState(() => _resuming = false);
  }

  Widget _continueCard(WatchRecord record) => Card(
    margin: EdgeInsets.zero,
    child: InkWell(
      onTap: _resuming ? null : () => _continue(record),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 64,
              child: Poster(record.drama, radius: 9),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '接着上次看 · ${record.drama.source.label}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '第 ${record.episodeIndex + 1} 集 · 已看 ${record.durationMs > 0 ? '${(record.progress * 100).round()}%' : '${record.positionMs ~/ 60000}分${record.positionMs ~/ 1000 % 60}秒'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_resuming)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.play_circle_fill_rounded, size: 36),
          ],
        ),
      ),
    ),
  );

  Widget _personal(bool wide) {
    final records = store.recent
        .where(
          (v) => _personalSource == null || v.drama.source == _personalSource,
        )
        .toList();
    final favorites = store.favorites.values
        .where((v) => _personalSource == null || v.source == _personalSource)
        .toList();
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 22, vertical: 12),
      children: [
        Text('留给喜欢的故事', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          '收藏与足迹，都在这里',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        if (store.recent.isNotEmpty) ...[
          _continueCard(store.recent.first),
          const SizedBox(height: 24),
        ],
        SourceFilter(
          value: _personalSource,
          onChanged: (v) => setState(() => _personalSource = v),
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: true,
              label: Text('收藏 ${favorites.length}'),
              icon: const Icon(Icons.bookmark_border),
            ),
            ButtonSegment(
              value: false,
              label: Text('历史 ${records.length}'),
              icon: const Icon(Icons.history),
            ),
          ],
          selected: {_favoritesOnly},
          onSelectionChanged: (v) => setState(() => _favoritesOnly = v.first),
        ),
        if (_favoritesOnly)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed:
                  store.checkingUpdates ||
                      (favorites.isEmpty && store.seasonReminders.isEmpty)
                  ? null
                  : () => perform(context, () async {
                      final completed = await store.checkFavoriteUpdates();
                      if (mounted && completed) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('更新检查完成')));
                      }
                    }),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(store.checkingUpdates ? '正在检查更新…' : '检查更新'),
            ),
          ),
        const SizedBox(height: 18),
        if (_favoritesOnly &&
            store.seasonReminders.values.any(
              (r) =>
                  _personalSource == null || r.anchor.source == _personalSource,
            )) ...[
          Text('新季提醒', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final reminder in store.seasonReminders.values.where(
            (r) =>
                _personalSource == null || r.anchor.source == _personalSource,
          ))
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(
                      reminder.anchor.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      !reminder.initialized
                          ? '等待首次检查建立提醒基准'
                          : reminder.unreadCount == 0
                          ? '暂无新季'
                          : '发现 ${reminder.unreadCount} 部新季',
                    ),
                    onTap: () => _open(reminder.anchor),
                    trailing: IconButton(
                      tooltip: '关闭新季提醒',
                      icon: const Icon(Icons.notifications_off_outlined),
                      onPressed: () => perform(
                        context,
                        () => store.toggleSeasonReminder(reminder.anchor),
                      ),
                    ),
                  ),
                  for (final notice
                      in reminder.seasons.values.where((n) => !n.read).take(3))
                    ListTile(
                      title: Text(
                        notice.drama.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('新季'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(notice.drama),
                    ),
                  if (reminder.unreadCount > 3)
                    TextButton(
                      onPressed: () => _open(reminder.anchor),
                      child: const Text('查看全部新季'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 18),
        ],
        if (_favoritesOnly && favorites.isEmpty ||
            !_favoritesOnly && records.isEmpty)
          EmptyState(
            icon: _favoritesOnly
                ? Icons.bookmark_add_outlined
                : Icons.history_rounded,
            title: _favoritesOnly ? '把心动的故事留下' : '故事从这一刻开始',
            message: _favoritesOnly ? '点击海报上的收藏，随时回来接着看' : '开始观看后，这里会记住你的进度',
          )
        else
          ...(_favoritesOnly ? favorites : records.map((v) => v.drama)).map((
            drama,
          ) {
            final record = store.history[drama.key];
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.all(12),
                leading: SizedBox(
                  width: 48,
                  height: 66,
                  child: Poster(drama, radius: 9),
                ),
                title: Text(
                  drama.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${drama.source.label}${record == null ? '' : ' · 第 ${record.episodeIndex + 1} 集'}${store.newEpisodeCount(drama) > 0 ? ' · 新增 ${store.newEpisodeCount(drama)} 集' : ''}',
                ),
                onTap: () => _open(drama),
                trailing: IconButton(
                  tooltip: _favoritesOnly ? '取消收藏' : '删除历史',
                  icon: Icon(
                    _favoritesOnly ? Icons.bookmark_rounded : Icons.close,
                  ),
                  onPressed: () => perform(
                    context,
                    () => _favoritesOnly
                        ? store.toggleFavorite(drama)
                        : store.removeHistory(drama.key),
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, this.icon);
  final String message;
  final IconData icon;
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
      ],
    ),
  );
}
