import 'package:flutter/material.dart';
import '../data/app_store.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import '../domain/watch_resume.dart';
import 'components.dart';
import 'continue_watching_card.dart';
import 'detail_page.dart';

class PersonalPage extends StatefulWidget {
  const PersonalPage({
    super.key,
    required this.store,
    required this.downloads,
    this.active = true,
  });
  final AppStore store;
  final DownloadStore downloads;
  final bool active;
  @override
  State<PersonalPage> createState() => _PersonalPageState();
}

class _PersonalPageState extends State<PersonalPage> {
  AppStore get store => widget.store;
  DramaSource? _personalSource;
  bool _favoritesOnly = true;
  String? _resuming;
  int _resumeGeneration = 0;
  final _scroll = ScrollController();

  void _cancelResume() {
    _resumeGeneration++;
    _resuming = null;
  }

  @override
  void didUpdateWidget(PersonalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active ||
        oldWidget.store != store ||
        oldWidget.downloads != widget.downloads) {
      _cancelResume();
    }
  }

  @override
  void dispose() {
    _cancelResume();
    _scroll.dispose();
    super.dispose();
  }

  void _changeView({DramaSource? source, bool? history}) {
    setState(() {
      _cancelResume();
      if (history != null) {
        _favoritesOnly = !history;
      } else {
        _personalSource = source;
      }
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _open(Drama drama) {
    setState(_cancelResume);
    store.records.cancelUpdateChecks();
    openDrama(context, store, widget.downloads, drama);
  }

  Future<void> _continue(WatchRecord record) async {
    if (_resuming != null) return;
    final generation = ++_resumeGeneration;
    final owner = store, downloads = widget.downloads;
    bool active() =>
        mounted &&
        widget.active &&
        generation == _resumeGeneration &&
        owner == store &&
        downloads == widget.downloads;
    owner.records.cancelUpdateChecks();
    setState(() => _resuming = record.drama.key);
    await perform(
      context,
      () => continueDrama(context, owner, downloads, record, isActive: active),
      failureMessage: '暂时无法续播，请重试或打开详情',
    );
    if (active()) setState(() => _resuming = null);
  }

  String _playLabel(WatchRecord record) =>
      switch (store.records.resumeFor(record).status) {
        WatchStatus.completed => '重新观看',
        WatchStatus.episodeCompleted => '重播本集',
        WatchStatus.nextEpisode =>
          '接着看第 ${store.records.resumeFor(record).episode!.number} 集',
        _ => '继续观看',
      };
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.active || _favoritesOnly,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.active) _changeView(history: false);
    },
    child: ListenableBuilder(
      listenable: Listenable.merge([
        store,
        store.catalog,
        store.records,
        store.records.progress,
      ]),
      builder: (context, _) =>
          _content(MediaQuery.sizeOf(context).width >= 900),
    ),
  );

  Widget _content(bool wide) {
    final records = store.records.recent
        .where(
          (v) => _personalSource == null || v.drama.source == _personalSource,
        )
        .toList();
    final favorites = store.records.favorites.values
        .where((v) => _personalSource == null || v.source == _personalSource)
        .toList();
    final continuable = records
        .where((record) => store.records.resumeFor(record).canContinue)
        .take(3)
        .toList();
    final rows = _favoritesOnly
        ? favorites
        : records.map((r) => r.drama).toList();
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _favoritesOnly ? '接着看' : '观看历史',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        SourceFilter(
          value: _personalSource,
          onChanged: (v) => _changeView(source: v),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _favoritesOnly
                    ? continuable.isEmpty
                          ? '我的收藏 ${favorites.length}'
                          : '最近观看'
                    : '历史 ${records.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: () => _changeView(history: _favoritesOnly),
              icon: Icon(
                _favoritesOnly ? Icons.history : Icons.bookmark_outline,
              ),
              label: Text(_favoritesOnly ? '历史 ${records.length}' : '返回收藏'),
            ),
          ],
        ),
        if (_favoritesOnly && continuable.isNotEmpty) ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 300).floor().clamp(
                1,
                continuable.length,
              );
              final width =
                  (constraints.maxWidth - 12 * (columns - 1)) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final record in continuable)
                    SizedBox(
                      width: width,
                      child: ContinueWatchingCard(
                        records: store.records,
                        record: record,
                        busy: _resuming == record.drama.key,
                        onContinue: _resuming == null
                            ? () => _continue(record)
                            : null,
                        onDetails: () => _open(record.drama),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          Text(
            '我的收藏 ${favorites.length}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
        if (_favoritesOnly)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed:
                  store.records.checkingUpdates ||
                      (favorites.isEmpty &&
                          store.records.seasonReminders.isEmpty)
                  ? null
                  : () => perform(context, () async {
                      final completed = await store.records
                          .checkFavoriteUpdates();
                      if (mounted && completed) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('更新检查完成')));
                      }
                    }),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(store.records.checkingUpdates ? '正在检查更新…' : '检查更新'),
            ),
          ),
        const SizedBox(height: 18),
        if (_favoritesOnly &&
            store.records.seasonReminders.values.any(
              (r) =>
                  _personalSource == null || r.anchor.source == _personalSource,
            )) ...[
          Text('新季提醒', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final reminder in store.records.seasonReminders.values.where(
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
                        () =>
                            store.records.toggleSeasonReminder(reminder.anchor),
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
          ),
      ],
    );
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 22, vertical: 12),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) =>
          index == 0 ? header : _entry(rows[index - 1]),
    );
  }

  Widget _entry(Drama drama) {
    final record = store.records.history[drama.key];
    return Card(
      key: ValueKey('personal:${drama.key}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: SizedBox(
              width: 48,
              height: 66,
              child: Poster(drama, radius: 9),
            ),
            title: Text(
              drama.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${drama.source.label}${record == null ? '' : ' · ${watchLabel(store.records, record)}'}${store.records.newEpisodeCount(drama) > 0 ? ' · 新增 ${store.records.newEpisodeCount(drama)} 集' : ''}',
            ),
            onTap: () => _open(drama),
            trailing: IconButton(
              tooltip: _favoritesOnly ? '取消收藏' : '删除历史',
              icon: Icon(_favoritesOnly ? Icons.bookmark_rounded : Icons.close),
              onPressed: () {
                setState(_cancelResume);
                perform(
                  context,
                  () => _favoritesOnly
                      ? store.records.toggleFavorite(drama)
                      : store.records.removeHistory(drama.key),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (record != null &&
                    store.records.resumeFor(record).status !=
                        WatchStatus.waiting)
                  FilledButton.icon(
                    onPressed: _resuming == null
                        ? () => _continue(record)
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_playLabel(record)),
                  ),
                OutlinedButton(
                  onPressed: () => _open(drama),
                  child: const Text('查看详情'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
