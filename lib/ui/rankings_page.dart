import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../domain/models.dart';
import 'components.dart';

class RankingsPage extends StatefulWidget {
  const RankingsPage({super.key, required this.store, required this.onOpen});
  final AppStore store;
  final ValueChanged<Drama> onOpen;
  @override
  State<RankingsPage> createState() => _RankingsPageState();
}

class _RankingsPageState extends State<RankingsPage> {
  late final DramaSource source = widget.store.source;
  List<Map<String, dynamic>> boards = [], rows = [];
  String? selected, error;
  bool loading = true, hasMore = false;
  int page = 1, generation = 0;
  @override
  void initState() {
    super.initState();
    _loadBoards();
  }

  Future<void> _loadBoards() async {
    try {
      final result = await widget.store.provider.call('boards', {
        'source': source.name,
      });
      if (!mounted) return;
      boards = (result['items'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      if (boards.isEmpty) {
        setState(() => loading = false);
        return;
      }
      await _load(boards.first['id'] as String);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _load(String board, {bool more = false}) async {
    final request = ++generation;
    final nextPage = more ? page + 1 : 1;
    setState(() {
      loading = true;
      error = null;
      selected = board;
      if (!more) rows = [];
    });
    try {
      final result = await widget.store.provider.call('ranking', {
        'board': board,
        'page': nextPage,
      });
      if (!mounted || request != generation) return;
      setState(() {
        rows.addAll(
          (result['items'] as List).map(
            (v) => Map<String, dynamic>.from(v as Map),
          ),
        );
        hasMore = result['hasMore'] == true;
        page = nextPage;
        final warning = result['warning'] as String?;
        if (warning != null && warning.isNotEmpty) error = warning;
      });
    } catch (e) {
      if (mounted && request == generation) setState(() => error = '$e');
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
                    label: Text(board['name'] as String),
                    selected: selected == board['id'],
                    onSelected: (_) => _load(board['id'] as String),
                  ),
                ),
            ],
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: rows.isEmpty && !loading
              ? EmptyState(
                  icon: Icons.bar_chart,
                  title: '榜单暂时不可用',
                  message: '稍后重试，或返回剧库继续浏览',
                  action: OutlinedButton(
                    onPressed: () =>
                        selected == null ? _loadBoards() : _load(selected!),
                    child: const Text('重试'),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(22),
                  itemCount: rows.length + (hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == rows.length) {
                      return TextButton(
                        onPressed: loading
                            ? null
                            : () => _load(selected!, more: true),
                        child: const Text('加载更多'),
                      );
                    }
                    final row = rows[index];
                    final drama = Drama.fromJson(
                      Map<String, dynamic>.from(row['drama'] as Map),
                    );
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(14),
                        onTap: () => widget.onOpen(drama),
                        leading: SizedBox(
                          width: 92,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 30,
                                child: Text(
                                  '${row['rank']}',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 42,
                                height: 56,
                                child: Poster(drama, radius: 6),
                              ),
                            ],
                          ),
                        ),
                        title: Text(
                          drama.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            drama.source.label,
                            if (drama.category.isNotEmpty) drama.category,
                            if (drama.episodes > 0) '${drama.episodes} 集',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
