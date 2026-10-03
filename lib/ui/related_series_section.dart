import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/series_lookup.dart';
import '../domain/models.dart';
import '../domain/catalog_query.dart';
import '../domain/series_title.dart';
import 'components.dart';

class RelatedSeriesSection extends StatefulWidget {
  const RelatedSeriesSection({
    super.key,
    required this.store,
    required this.drama,
    required this.onOpen,
  });
  final AppStore store;
  final Drama drama;
  final Future<void> Function(Drama) onOpen;
  @override
  RelatedSeriesSectionState createState() => RelatedSeriesSectionState();
}

class RelatedSeriesSectionState extends State<RelatedSeriesSection>
    with WidgetsBindingObserver {
  SeriesLookup? _lookup;
  int _generation = 0;
  bool _loading = false, _changing = false, _showAll = false;
  bool _foreground = true;
  String? _notice;
  List<Drama> _partial = [];

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(RelatedSeriesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drama.key != widget.drama.key ||
        oldWidget.store != widget.store) {
      cancelLookup();
      _showAll = false;
      _notice = null;
      _partial = [];
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) cancelLookup();
  }

  void cancelLookup() {
    _generation++;
    _lookup?.cancel();
    _lookup = null;
    if (mounted && _loading) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _generation++;
    _lookup?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _search() async {
    if (!_foreground) return;
    cancelLookup();
    final generation = ++_generation;
    final expected = widget.store.seasonReminders[widget.drama.key];
    setState(() {
      _loading = true;
      _notice = null;
    });
    try {
      final lookup = widget.store.lookupSeries(
        widget.drama,
        refresh: true,
        onPartial: (result) {
          if (mounted && generation == _generation) {
            setState(() => _partial = result.items);
          }
        },
      );
      _lookup = lookup;
      final result = await lookup.result;
      if (!mounted || generation != _generation) return;
      _partial = result.items;
      if (expected != null) {
        await widget.store.observeSeasons(
          widget.drama,
          result,
          expected: expected,
        );
      }
      if (!mounted || generation != _generation) return;
      setState(
        () => _notice =
            result.warning.isNotEmpty || result.limited || result.hasMore
            ? '补全尚未完成，保留已找到的作品，可稍后重试'
            : result.items.isEmpty
            ? '暂未找到同系列作品'
            : null,
      );
    } on SeriesLookupCancelled {
      // A cancelled owner must not report a search failure.
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _notice = '同系列暂时未补全，请重试；已有作品仍可查看');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _lookup = null;
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggleReminder() async {
    final enabled = widget.store.seasonReminders.containsKey(widget.drama.key);
    cancelLookup();
    final generation = _generation;
    setState(() => _changing = true);
    try {
      await widget.store.toggleSeasonReminder(widget.drama);
      if (mounted &&
          _foreground &&
          generation == _generation &&
          !enabled &&
          !widget.store.offline) {
        await _search();
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final rows = relatedSeries(widget.drama, [
        ...widget.store.relatedTo(widget.drama),
        ..._partial,
      ]);
      final reminder = widget.store.seasonReminders[widget.drama.key];
      final title = SeriesTitle.parse(widget.drama.title);
      final online =
          widget.drama.source == DramaSource.hongguo &&
          title != null &&
          title.baseTitle.runes.length <= 80;
      if (!online && rows.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('同系列', style: Theme.of(context).textTheme.titleLarge),
          const Text('按标题匹配，可能与站源的系列划分不同', style: TextStyle(fontSize: 12)),
          if (online)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: _loading
                      ? cancelLookup
                      : widget.store.offline
                      ? null
                      : _search,
                  icon: Icon(_loading ? Icons.close : Icons.search),
                  label: Text(_loading ? '取消补全' : '联网补全'),
                ),
                TextButton.icon(
                  onPressed: _changing
                      ? null
                      : () => perform(context, _toggleReminder),
                  icon: Icon(
                    reminder == null
                        ? Icons.notifications_none
                        : Icons.notifications_active_outlined,
                  ),
                  label: Text(reminder == null ? '提醒新季' : '关闭新季提醒'),
                ),
              ],
            ),
          if (reminder != null)
            Text(
              reminder.initialized
                  ? '新季提醒已开启，可在收藏页检查更新'
                  : '首次完整检查记录已有季，之后发现新季会在应用内提醒',
              style: const TextStyle(fontSize: 12),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_notice != null)
            Text(_notice!, style: const TextStyle(fontSize: 12)),
          if (widget.store.offline)
            const Text('当前离线，显示已有作品', style: TextStyle(fontSize: 12)),
          if (rows.isEmpty && !_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('暂无同系列作品'),
            ),
          for (final row in rows.take(_showAll ? 200 : 5))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                row.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                reminder?.seasons[row.key]?.read == false
                    ? '新季'
                    : row.source.label,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                cancelLookup();
                await widget.onOpen(row);
              },
            ),
          if (rows.length > 5)
            TextButton(
              onPressed: () => setState(() => _showAll = !_showAll),
              child: Text(_showAll ? '收起同系列' : '查看全部 ${rows.length} 部'),
            ),
          const SizedBox(height: 20),
        ],
      );
    },
  );
}
