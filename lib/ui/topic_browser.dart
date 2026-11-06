import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../domain/catalog_topic.dart';
import '../domain/models.dart';
import '../platform/provider_client.dart';
import 'components.dart';
import 'record_actions.dart';
import 'television_grid.dart';

List<CatalogTopic> _topics(AppStore store, DramaSource source) => catalogTopics(
  source,
  store.catalog.cachedDramas(source),
  categories: store.catalog.sourceCategories[source] ?? const [],
);

Future<void> openTopicBrowser(
  BuildContext context, {
  required AppStore store,
  required DramaSource source,
  required CatalogTopic topic,
  required ValueChanged<Drama> onOpen,
  Drama? seed,
}) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => TopicBrowserPage(
        store: store,
        source: source,
        topic: topic,
        onOpen: onOpen,
        seed: seed,
      ),
    ),
  );
}

Future<void> showTopicPicker(
  BuildContext context, {
  required AppStore store,
  required DramaSource source,
  required ValueChanged<Drama> onOpen,
}) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  FocusScope.of(context).unfocus();
  final topic = await showModalBottomSheet<CatalogTopic>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TopicPicker(store: store, source: source),
  );
  if (topic == null || !context.mounted) return;
  await openTopicBrowser(
    context,
    store: store,
    source: source,
    topic: topic,
    onOpen: onOpen,
  );
}

/// The same finite topic entry is used alongside search and source browsing.
class TopicShortcuts extends StatelessWidget {
  const TopicShortcuts({
    super.key,
    required this.store,
    required this.source,
    required this.onOpen,
  });
  final AppStore store;
  final DramaSource source;
  final ValueChanged<Drama> onOpen;

  @override
  Widget build(BuildContext context) {
    final topics = _topics(store, source);
    if (topics.isEmpty && !source.remoteCategories) return const SizedBox();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.explore_outlined, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '按题材找剧',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              source.remoteCategories ? '浏览站源分类，也可发现已保存的题材' : '来自已保存资料的分类与标签',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (topics.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final topic in topics.take(6))
                    ActionChip(
                      backgroundColor: scheme.primary.withValues(alpha: .08),
                      side: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: .5),
                      ),
                      tooltip: topic.name,
                      label: Text(
                        topic.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        openTopicBrowser(
                          context,
                          store: store,
                          source: source,
                          topic: topic,
                          onOpen: onOpen,
                        );
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => showTopicPicker(
                context,
                store: store,
                source: source,
                onOpen: onOpen,
              ),
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(topics.isEmpty ? '浏览站源分类' : '更多题材'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopicPicker extends StatefulWidget {
  const _TopicPicker({required this.store, required this.source});
  final AppStore store;
  final DramaSource source;
  @override
  State<_TopicPicker> createState() => _TopicPickerState();
}

class _TopicPickerState extends State<_TopicPicker> {
  String _query = '';
  @override
  void initState() {
    super.initState();
    if (!widget.store.catalog.sourceCategories.containsKey(widget.source)) {
      unawaited(
        Future<void>.microtask(() async {
          if (mounted) await widget.store.catalog.loadCategories(widget.source);
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.store,
      widget.store.catalog,
      widget.store.records,
    ]),
    builder: (context, _) {
      final media = MediaQuery.of(context),
          store = widget.store,
          source = widget.source;
      final topics = _topics(store, source)
          .where(
            (topic) =>
                topic.name.toLowerCase().contains(_query.trim().toLowerCase()),
          )
          .toList();
      final loading = store.catalog.categoriesLoadingFor(source);
      final error = store.catalog.categoryErrors[source];
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: math.min(
              620,
              math.max(
                0,
                media.size.height -
                    media.viewInsets.bottom -
                    media.padding.top -
                    72,
              ),
            ),
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${source.label} · 题材',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭题材选择',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: '查找分类或标签',
                            prefixIcon: Icon(Icons.search),
                          ),
                          onChanged: (value) => setState(() => _query = value),
                        ),
                      ),
                      if (loading) const LinearProgressIndicator(),
                      if (error != null && !loading)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(error),
                              if (!store.offline)
                                TextButton(
                                  onPressed: () =>
                                      store.catalog.loadCategories(source),
                                  child: const Text('重试分类'),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                if (topics.isEmpty)
                  SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          loading
                              ? '正在读取分类…'
                              : _query.isNotEmpty
                              ? '没有匹配的题材'
                              : '暂时没有分类或已保存的标签',
                        ),
                      ),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: topics.length,
                    itemBuilder: (context, index) {
                      final topic = topics[index];
                      return ListTile(
                        leading: Icon(
                          topic.remote
                              ? Icons.grid_view_outlined
                              : Icons.label_outline,
                        ),
                        title: Text(
                          topic.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(topic.remote ? '站源分类' : '已保存资料'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context, topic),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class TopicBrowserPage extends StatefulWidget {
  const TopicBrowserPage({
    super.key,
    required this.store,
    required this.source,
    required this.topic,
    required this.onOpen,
    this.seed,
  });
  final AppStore store;
  final DramaSource source;
  final CatalogTopic topic;
  final ValueChanged<Drama> onOpen;
  final Drama? seed;
  @override
  State<TopicBrowserPage> createState() => _TopicBrowserPageState();
}

class _TopicBrowserPageState extends State<TopicBrowserPage> {
  late CatalogTopic _topic;
  List<Drama>? _rows;
  bool _loading = false, _resolving = false, _more = false, _failedMore = false;
  int _page = 0, _generation = 0;
  String? _error;
  ({String id, int page, String category})? _request;

  @override
  void initState() {
    super.initState();
    _topic = widget.topic;
    unawaited(Future<void>.microtask(_resolve));
  }

  Future<void> _resolve() async {
    if (!mounted || widget.store.offline) return;
    if (!_topic.remote && widget.source.remoteCategories) {
      final generation = _generation;
      setState(() => _resolving = true);
      if (!widget.store.catalog.sourceCategories.containsKey(widget.source)) {
        await widget.store.catalog.loadCategories(widget.source);
      }
      if (!mounted || generation != _generation) return;
      final match = _topics(widget.store, widget.source)
          .where(
            (topic) =>
                topic.remote &&
                topic.name.toLowerCase() == _topic.name.toLowerCase(),
          )
          .firstOrNull;
      setState(() {
        if (match != null) _topic = match;
        _resolving = false;
      });
    }
    if (mounted &&
        ModalRoute.of(context)?.isCurrent != false &&
        _topic.remote) {
      await _load();
    }
  }

  void _cancel() {
    ++_generation;
    final request = _request;
    _request = null;
    _loading = _resolving = false;
    if (request != null) {
      unawaited(
        widget.store.provider
            .cancelCatalog(
              widget.source,
              request.id,
              page: request.page,
              category: request.category,
            )
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (!mounted ||
        _loading ||
        widget.store.offline ||
        !_topic.remote ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final generation = ++_generation;
    final page = more ? _page + 1 : 1;
    final request = (
      id: 'topic-$generation-${DateTime.now().microsecondsSinceEpoch}',
      page: page,
      category: _topic.categoryId!,
    );
    _request = request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.store.provider.catalogPage(
        widget.source,
        category: request.category,
        page: page,
        requestId: request.id,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _rows = {
          for (final drama in [
            ...(more ? _rows ?? const <Drama>[] : const <Drama>[]),
            ...result.items,
          ])
            drama.key: drama,
        }.values.toList();
        _page = page;
        _more = result.hasMore;
        _failedMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failedMore = more;
        _error = providerFailureMessage(error, '分类暂时无法加载，已保留现有资料');
      });
    } finally {
      if (mounted && generation == _generation) {
        _request = null;
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.store,
      widget.store.catalog,
      widget.store.records,
    ]),
    builder: (context, _) {
      final store = widget.store, source = widget.source;
      final rows =
          _rows ??
          topicDramas(source, _topic, [
            if (widget.seed != null) widget.seed!,
            ...store.catalog.cachedDramas(source),
          ]);
      final scheme = Theme.of(context).colorScheme;
      final saved = _rows == null;
      return Scaffold(
        appBar: AppBar(
          title: const Text('题材'),
          actions: [
            IconButton(
              tooltip: '更多题材',
              onPressed: () {
                _cancel();
                setState(() {});
                showTopicPicker(
                  context,
                  store: store,
                  source: source,
                  onOpen: widget.onOpen,
                );
              },
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        body: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.label,
                        style: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(color: scheme.primary),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _topic.name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        !saved
                            ? '站源分类 · 已加载 ${rows.length} 部'
                            : '已保存资料 · ${rows.length} 部',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (saved) ...[
                        const SizedBox(height: 6),
                        Text(
                          '仅匹配本机已保存资料中的分类与标签',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      if (_loading || _resolving) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!),
                        if (!store.offline)
                          TextButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _load(more: _failedMore),
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试分类'),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              if (rows.isEmpty && !_loading && !_resolving)
                const SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.local_offer_outlined,
                    title: '暂时没有同题材作品',
                    message: '可浏览其他题材，或稍后再来看看',
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final layout = dramaGridLayout(
                      context,
                      constraints.crossAxisExtent,
                    );
                    return TelevisionGrid(
                      itemKeys: [for (final drama in rows) drama.key],
                      columns: layout.columns,
                      mainAxisExtent: layout.extent,
                      itemBuilder: (context, index) => DramaCard(
                        drama: rows[index],
                        favorite: store.records.favorites.containsKey(
                          rows[index].key,
                        ),
                        onFavorite: () => toggleFavoriteWithUndo(
                          context,
                          store.records,
                          rows[index],
                        ),
                        onTap: () {
                          _cancel();
                          setState(() {});
                          widget.onOpen(rows[index]);
                        },
                      ),
                    );
                  },
                ),
              ),
              if (_topic.remote && !store.offline)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        if (_more)
                          FilledButton.tonal(
                            onPressed: _loading
                                ? null
                                : () => _load(more: true),
                            child: Text(_loading ? '正在加载…' : '加载更多'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _loading ? null : () => _load(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新分类'),
                        ),
                      ],
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
