import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../domain/models.dart';
import '../platform/provider_client.dart';
import 'components.dart';

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
  String genre = 'short_play', session = '';
  int offset = 0, generation = 0;
  bool loading = false, hasMore = true;
  String? error;
  List<Drama> rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (loading && !reset) return;
    final request = ++generation;
    if (reset) {
      rows = [];
      offset = 0;
      session = '';
      hasMore = true;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (widget.store.offline) throw const ProviderException('当前离线，请联网后获取推荐');
      final result = await widget.store.provider.call('recommendations', {
        'recommendation': {
          'genre': genre,
          'offset': offset,
          'sessionId': session,
          'seen': rows.reversed.take(540).map((d) => d.id).toList(),
        },
      });
      if (!mounted || request != generation) return;
      final incoming = (result['items'] as List)
          .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
      if (incoming.any((d) => d.source != DramaSource.hongguo)) {
        throw const FormatException('推荐站源不匹配');
      }
      await widget.store.catalog.saveRecommendations(incoming);
      if (!mounted || request != generation) return;
      setState(() {
        rows = {
          for (final d in [...rows, ...incoming]) d.key: d,
        }.values.toList();
        offset = result['nextOffset'] as int;
        session = result['sessionId'] as String? ?? '';
        hasMore = result['hasMore'] == true;
      });
    } catch (e) {
      if (mounted && request == generation) setState(() => error = '$e');
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('发现 · 红果')),
    body: SafeArea(
      child: RefreshIndicator(
        onRefresh: () => _load(reset: true),
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
                        for (final entry in const {
                          'short_play': '真人剧',
                          'comic_series': '漫剧',
                          'ai_series': 'AI 剧',
                        }.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: genre == entry.key,
                            onSelected: (_) {
                              setState(() => genre = entry.key);
                              _load(reset: true);
                            },
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
                        onPressed: () => _load(),
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
                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 22,
                      crossAxisSpacing: 14,
                      mainAxisExtent:
                          constraints.crossAxisExtent / columns * 1.6 + 45,
                    ),
                    itemCount: rows.length,
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
                    onPressed: loading || !hasMore ? null : () => _load(),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(
                      loading
                          ? '正在寻找…'
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
