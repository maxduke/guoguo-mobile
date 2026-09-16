import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'detail_page.dart';
import 'downloads_page.dart';
import 'settings_page.dart';
import 'rankings_page.dart';

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

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  bool _resuming = false;
  final _search = TextEditingController();
  String _query = '', _category = '全部';
  DramaSource? _personalSource;
  bool _favoritesOnly = true, _searching = false;
  int _searchGeneration = 0;
  String? _searchError;
  AppStore get store => widget.store;
  @override
  void initState() {
    super.initState();
    if (widget.autoLoad && store.library.isEmpty) unawaited(store.refresh());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(Drama drama) => openDrama(context, store, widget.downloads, drama);
  Future<void> _submit(String text) async {
    if (text.trim().isEmpty) return;
    final generation = ++_searchGeneration;
    final source = store.source;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      await store.search(source, text);
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
          onDestinationSelected: (v) => setState(() => _tab = v),
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

  Widget _library(bool wide) {
    final rows = store.library
        .where(
          (d) =>
              (_query.isEmpty ||
                  d.title.toLowerCase().contains(_query.toLowerCase())) &&
              (_category == '全部' || d.category == _category),
        )
        .toList();
    final categories = {
      '全部',
      ...store.library.map((d) => d.category).where((s) => s.isNotEmpty),
    }.take(12).toList();
    final loading = store.loadingSources.contains(store.source);
    final horizontal = wide ? 40.0 : 22.0;
    return RefreshIndicator(
      onRefresh: () => store.refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter < 700 &&
              _query.isEmpty &&
              store.sourceErrors[store.source] == null) {
            unawaited(store.loadMore());
          }
          return false;
        },
        child: CustomScrollView(
          key: PageStorageKey('library-${store.source.name}'),
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
                  Row(
                    children: [
                      for (final source in DramaSource.values)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: source == DramaSource.values.last ? 0 : 10,
                            ),
                            child: Semantics(
                              selected: store.source == source,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(15),
                                onTap: () => perform(context, () async {
                                  _search.clear();
                                  ++_searchGeneration;
                                  setState(() {
                                    _query = '';
                                    _category = '全部';
                                    _searchError = null;
                                    _searching = false;
                                  });
                                  await store.selectSource(source);
                                  if ((store.catalogs[source] ?? []).isEmpty) {
                                    await store.refresh(source);
                                  }
                                }),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: store.source == source
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                  child: Text(
                                    source.label,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: store.source == source
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onPrimary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _search,
                    onChanged: (v) {
                      ++_searchGeneration;
                      setState(() {
                        _query = v.trim();
                        if (_query.isNotEmpty) _category = '全部';
                        _searchError = null;
                        _searching = false;
                      });
                    },
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
                                      ++_searchGeneration;
                                    }),
                                  ),
                                IconButton(
                                  tooltip: '联网搜索',
                                  icon: const Icon(Icons.arrow_forward_rounded),
                                  onPressed: () => _submit(_search.text),
                                ),
                              ],
                            ),
                    ),
                  ),
                  if (_searchError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _Notice(_searchError!, Icons.info_outline_rounded),
                    ),
                  if (_query.isEmpty) ...[const SizedBox(height: 16)],
                  if (_query.isEmpty && store.recent.isNotEmpty) ...[
                    _continueCard(store.recent.first),
                    const SizedBox(height: 22),
                  ],
                  Row(
                    children: [
                      Text(
                        _query.isEmpty ? '全部短剧' : '搜索结果',
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
                  if (categories.length > 1)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
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
                  if (store.sourceErrors[store.source] != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _Notice(
                        store.sourceErrors[store.source]!,
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
            if (store.library.isNotEmpty && _query.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Center(
                    child: Column(
                      children: [
                        Text(
                          '已加载 ${store.library.length} 部 · ${store.hasMore[store.source] == true ? "继续下滑加载" : "当前来源已返回完毕"}',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '已加载数量不代表全站总量',
                          style: TextStyle(fontSize: 12),
                        ),
                        if (store.hasMore[store.source] == true)
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
                    '第 ${record.episodeIndex + 1} 集 · 已看 ${(record.progress * 100).round()}%',
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
              onPressed: store.checkingUpdates || favorites.isEmpty
                  ? null
                  : () => perform(context, () async {
                      await store.checkFavoriteUpdates();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('收藏分集已更新')),
                        );
                      }
                    }),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(store.checkingUpdates ? '正在检查更新…' : '检查新集'),
            ),
          ),
        const SizedBox(height: 18),
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
