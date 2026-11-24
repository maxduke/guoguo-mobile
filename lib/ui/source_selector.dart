import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../data/catalog_store.dart';
import '../data/preferences_store.dart';
import 'discovery_cache_status.dart';
import 'source_diagnostics_page.dart';
import 'source_request_status.dart';
import 'television_scope.dart';

class _SourceChoice {
  const _SourceChoice(this.source);
  final DramaSource? source;
}

enum _SourceGroup {
  all('全部'),
  shortDrama('短剧'),
  film('综合影视'),
  plugins('插件库');

  const _SourceGroup(this.label);
  final String label;

  bool includes(DramaSource? source) => switch (this) {
    all => true,
    shortDrama =>
      source != null && !source.adult && !source.offersLongFormVideo,
    film => source?.offersLongFormVideo ?? false,
    plugins => source?.inPluginLibrary ?? false,
  };
}

Future<void> showSourceManagement(
  BuildContext context, {
  required PreferencesStore preferences,
  required CatalogStore catalog,
  required bool Function() isCurrent,
}) {
  final television = TelevisionScope.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SourceSheet(
      selected: catalog.source,
      includeAll: false,
      preferences: preferences,
      catalog: catalog,
      isCurrent: isCurrent,
      managementOnly: true,
      television: television,
    ),
  );
}

/// A fixed-width entry to all sources, shared by browsing and record filters.
class SourceSelector extends StatefulWidget {
  const SourceSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.includeAll = false,
    this.preferences,
    this.catalog,
  });
  final DramaSource? value;
  final ValueChanged<DramaSource?> onChanged;
  final bool includeAll;
  final PreferencesStore? preferences;
  final CatalogStore? catalog;
  @override
  State<SourceSelector> createState() => _SourceSelectorState();
}

class _SourceSelectorState extends State<SourceSelector> {
  bool _opening = false;
  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    final preferences = widget.preferences, catalog = widget.catalog;
    bool current() =>
        mounted &&
        widget.preferences == preferences &&
        widget.catalog == catalog;
    final television = TelevisionScope.of(context);
    try {
      final choice = await showModalBottomSheet<_SourceChoice>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _SourceSheet(
          selected: widget.value,
          includeAll: widget.includeAll,
          preferences: preferences,
          catalog: catalog,
          isCurrent: current,
          television: television,
        ),
      );
      if (current() && choice != null && choice.source != widget.value) {
        widget.onChanged(choice.source);
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    widthFactor: 1,
    child: OutlinedButton.icon(
      onPressed: _open,
      icon: const Icon(Icons.grid_view_rounded, size: 20),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.value?.label ?? '全部站源'),
          const SizedBox(width: 8),
          const Icon(Icons.expand_more, size: 20),
        ],
      ),
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
    ),
  );
}

class _SourceSheet extends StatefulWidget {
  const _SourceSheet({
    required this.selected,
    required this.includeAll,
    required this.isCurrent,
    required this.television,
    this.preferences,
    this.catalog,
    this.managementOnly = false,
  });
  final DramaSource? selected;
  final bool includeAll;
  final PreferencesStore? preferences;
  final CatalogStore? catalog;
  final bool Function() isCurrent;
  final bool television, managementOnly;
  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  final _scroll = ScrollController();
  String _query = '';
  bool _managing = false, _saving = false, _stale = false;
  bool _showHidden = false;
  _SourceGroup _group = _SourceGroup.all;
  bool _retrying = false;
  String? _error;
  bool get _management => widget.managementOnly || _managing;

  bool _checkOwner() {
    if (widget.isCurrent()) return true;
    setState(() => _stale = true);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    return false;
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_saving || !_checkOwner()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && widget.isCurrent()) {
        setState(() => _error = '站源设置尚未保存，请重试');
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _stale = !widget.isCurrent();
        });
      }
    }
  }

  void _manage(
    bool value, {
    bool showHidden = false,
    _SourceGroup group = _SourceGroup.all,
  }) {
    if (!_checkOwner()) return;
    setState(() {
      _managing = value;
      _showHidden = showHidden;
      _group = group;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(DramaSource? source) {
    if (!_saving && _checkOwner()) {
      Navigator.pop(context, _SourceChoice(source));
    }
  }

  void _diagnostics(DramaSource source) {
    final diagnostics = widget.catalog?.diagnostics;
    if (diagnostics == null || !_checkOwner()) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            SourceDiagnosticsPage(diagnostics: diagnostics, source: source),
      ),
    );
  }

  Future<void> _retrySource() async {
    final catalog = widget.catalog, source = widget.selected;
    if (_retrying ||
        catalog == null ||
        source == null ||
        catalog.source != source ||
        catalog.isOffline() ||
        !_checkOwner()) {
      return;
    }
    setState(() => _retrying = true);
    try {
      await catalog.refresh(source);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      if (widget.preferences != null) widget.preferences!,
      if (widget.catalog != null) widget.catalog!,
      if (widget.catalog?.diagnostics != null) widget.catalog!.diagnostics!,
    ]),
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final media = MediaQuery.of(context);
    final available =
        media.size.height - media.viewInsets.bottom - media.padding.top;
    final query = _query.trim().toLowerCase();
    final preferences = widget.preferences;
    final favorite = preferences?.favoriteSources ?? const <DramaSource>{};
    final hidden = preferences?.hiddenSources ?? const <DramaSource>{};
    final groupSources = DramaSource.values.where(_group.includes).toList();
    final shownCount = groupSources
        .where((source) => !hidden.contains(source))
        .length;
    final hiddenCount = groupSources.length - shownCount;
    final sources =
        <DramaSource?>[if (widget.includeAll) null, ...DramaSource.values]
            .where(
              (source) => '${source?.label ?? '全部站源'} ${source?.name ?? ''}'
                  .toLowerCase()
                  .contains(query),
            )
            .where((source) => query.isNotEmpty || _group.includes(source))
            .where(
              (source) =>
                  _management ||
                  preferences == null ||
                  source == widget.selected ||
                  source?.plugin != true ||
                  !hidden.contains(source),
            )
            .toList();
    final visible = sources
        .where(
          (source) => source == widget.selected || !hidden.contains(source),
        )
        .toList();
    final favorites = visible
        .where((source) => favorite.contains(source))
        .toList();
    final recent =
        preferences?.recentSources
            .where(
              (source) =>
                  visible.contains(source) && !favorites.contains(source),
            )
            .toList() ??
        <DramaSource>[];
    final remaining = visible
        .where(
          (source) => !favorites.contains(source) && !recent.contains(source),
        )
        .toList();
    final shortForm = remaining
        .where(_SourceGroup.shortDrama.includes)
        .toList();
    final generalVideo = remaining.where(_SourceGroup.film.includes).toList();
    final adult = remaining.where((source) => source?.adult ?? false).toList();
    final managed = sources
        .whereType<DramaSource>()
        .where(
          (source) =>
              query.isNotEmpty || hidden.contains(source) == _showHidden,
        )
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: math.min(650, math.max(0, available - 32)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scale = media.textScaler.scale(14) / 14;
                final showStatus = widget.catalog?.diagnostics != null;
                final columns = showStatus
                    ? scale >= 1.6
                          ? 1
                          : constraints.maxWidth >= 560
                          ? 3
                          : 2
                    : scale >= 1.5
                    ? 2
                    : constraints.maxWidth >= 480
                    ? 4
                    : 3;
                final width =
                    (constraints.maxWidth - (columns - 1) * 8) / columns;
                final header = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _management ? '站源管理' : '选择站源',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (preferences != null && !widget.managementOnly)
                          IconButton(
                            tooltip: _managing ? '返回站源选择' : '管理站源',
                            onPressed: _saving || _stale
                                ? null
                                : () => _manage(!_managing),
                            icon: Icon(
                              _managing ? Icons.arrow_back : Icons.tune,
                            ),
                          ),
                        if (preferences != null && !_management)
                          IconButton(
                            tooltip: '打开插件库',
                            onPressed: _saving || _stale
                                ? null
                                : () => _manage(
                                    true,
                                    showHidden: true,
                                    group: _SourceGroup.plugins,
                                  ),
                            icon: const Icon(Icons.extension_outlined),
                          ),
                        IconButton(
                          tooltip: widget.managementOnly ? '关闭站源管理' : '关闭站源选择',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: const InputDecoration(
                        hintText: '搜索站源',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 16),
                    if (preferences != null &&
                        !widget.includeAll &&
                        query.isEmpty &&
                        available > 265) ...[
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final group in _SourceGroup.values)
                            if (_management || group != _SourceGroup.plugins)
                              FilterChip(
                                label: Text(group.label),
                                selected: _group == group,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => _group = group),
                              ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (showStatus && !_management && query.isEmpty) ...[
                      Text(
                        '最近请求记录 · 未验证视频播放',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (widget.selected != null &&
                          widget.catalog!.diagnostics!.latestFor(
                                widget.selected!,
                              ) !=
                              null) ...[
                        const SizedBox(height: 12),
                        _currentStatus(widget.selected!),
                      ],
                      const SizedBox(height: 16),
                    ],
                    if (_stale) const Text('页面已更新，请关闭后重新选择站源'),
                    if (_saving) const LinearProgressIndicator(),
                    if (_error != null) ...[
                      Text(_error!),
                      TextButton(
                        onPressed: _saving || _stale
                            ? null
                            : () => _change(preferences!.saveSources),
                        child: const Text('重试保存'),
                      ),
                    ],
                    if (_management && query.isEmpty) ...[
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: Text('已显示 $shownCount'),
                            selected: !_showHidden,
                            autofocus:
                                widget.television && widget.managementOnly,
                            onSelected: (_) =>
                                setState(() => _showHidden = false),
                          ),
                          ChoiceChip(
                            label: Text('已隐藏 $hiddenCount'),
                            selected: _showHidden,
                            onSelected: (_) =>
                                setState(() => _showHidden = true),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (sources.isEmpty || _management && managed.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          query.isNotEmpty
                              ? '没有匹配的站源'
                              : _showHidden
                              ? '没有隐藏的站源'
                              : '没有显示的站源',
                        ),
                      )
                    else if (!_management &&
                        (query.isNotEmpty || preferences == null))
                      _grid(sources, width, scale, favorite, hidden)
                    else if (!_management) ...[
                      if (widget.includeAll) ...[
                        _grid([null], width, scale, favorite, hidden),
                        const SizedBox(height: 16),
                      ],
                      if (favorites.isNotEmpty) ...[
                        const Text('常用站源'),
                        const SizedBox(height: 8),
                        _grid(favorites, width, scale, favorite, hidden),
                        const SizedBox(height: 16),
                      ],
                      if (recent.isNotEmpty) ...[
                        const Text('最近选择'),
                        const SizedBox(height: 8),
                        _grid(recent, width, scale, favorite, hidden),
                        const SizedBox(height: 16),
                      ],
                      if (shortForm.isNotEmpty) ...[
                        const Text('短剧站源'),
                        const SizedBox(height: 8),
                        _grid(shortForm, width, scale, favorite, hidden),
                        const SizedBox(height: 16),
                      ],
                      if (generalVideo.isNotEmpty) ...[
                        const Text('综合影视站源'),
                        const SizedBox(height: 8),
                        _grid(generalVideo, width, scale, favorite, hidden),
                      ],
                      if (adult.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text('成人内容'),
                        const SizedBox(height: 8),
                        _grid(adult, width, scale, favorite, hidden),
                      ],
                      if (hidden.isNotEmpty)
                        TextButton.icon(
                          onPressed: _saving || _stale
                              ? null
                              : () => _manage(true, showHidden: true),
                          icon: const Icon(Icons.visibility_off_outlined),
                          label: Text('已隐藏 ${hidden.length} 个站源'),
                        ),
                    ],
                  ],
                );
                if (!_management) {
                  return SingleChildScrollView(
                    controller: _scroll,
                    child: header,
                  );
                }
                return CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(child: header),
                    SliverList.builder(
                      itemCount: managed.length,
                      itemBuilder: (_, index) {
                        final source = managed[index];
                        return _managementCard(
                          source,
                          favorite.contains(source),
                          hidden.contains(source),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _grid(
    List<DramaSource?> sources,
    double width,
    double scale,
    Set<DramaSource> favorite,
    Set<DramaSource> hidden,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final source in sources)
        SizedBox(
          width: width,
          height: widget.catalog?.diagnostics == null
              ? math.max(56, 48 * scale)
              : null,
          child: ChoiceChip(
            label: SizedBox(
              width: math.max(0, width - 16),
              height: widget.catalog?.diagnostics == null
                  ? null
                  : math.max(60, 78 * scale - 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (favorite.contains(source) ||
                          hidden.contains(source)) ...[
                        Icon(
                          hidden.contains(source)
                              ? Icons.visibility_off_outlined
                              : Icons.star,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          source?.label ?? '全部站源',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                  if (widget.catalog?.diagnostics != null) ...[
                    const SizedBox(height: 5),
                    if (source == null)
                      Text(
                        '汇总已保存记录',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    else
                      SourceRequestStatus(
                        sample: widget.catalog!.diagnostics!.latestFor(source),
                        compact: true,
                      ),
                  ],
                ],
              ),
            ),
            labelPadding: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            showCheckmark: false,
            selected: widget.selected == source,
            autofocus: widget.television && widget.selected == source,
            onSelected: _saving || _stale ? null : (_) => _select(source),
          ),
        ),
    ],
  );

  Widget _currentStatus(DramaSource source) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .5),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前 · ${source.label}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              SourceRequestStatus(
                sample: widget.catalog!.diagnostics!.latestFor(source),
                compact: true,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '查看${source.label}请求记录',
          onPressed: () => _diagnostics(source),
          icon: const Icon(Icons.history),
        ),
        if (source == widget.catalog!.source && !widget.catalog!.isOffline())
          IconButton(
            tooltip: _retrying || widget.catalog!.libraryLoading
                ? '正在加载…'
                : '重试当前剧库',
            onPressed: _retrying || widget.catalog!.libraryLoading
                ? null
                : _retrySource,
            icon: const Icon(Icons.refresh),
          ),
      ],
    ),
  );

  Widget _managementCard(DramaSource source, bool favorite, bool hidden) {
    final preferences = widget.preferences!;
    final retrieved = widget.catalog?.discoveryCache.lastContentRetrieval(
      source,
    );
    final notice = widget.catalog?.directoryNotice(source);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    source == widget.selected
                        ? '${source.label} · 当前'
                        : source.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '${favorite ? '取消收藏' : '收藏'}站源${source.label}',
                  onPressed: _saving || _stale || source.browserOnly
                      ? null
                      : () => _change(
                          () => preferences.toggleFavoriteSource(source),
                        ),
                  icon: Icon(favorite ? Icons.star : Icons.star_outline),
                ),
                IconButton(
                  tooltip:
                      '${hidden ? (source.plugin ? '启用' : '恢复') : '隐藏'}站源${source.label}',
                  onPressed: _saving || _stale || source.browserOnly
                      ? null
                      : () => _change(
                          () => preferences.setSourceHidden(source, !hidden),
                        ),
                  icon: Icon(
                    hidden
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ],
            ),
            Text(
              [
                source.onlineSearch ? '联网搜名' : '本地搜名',
                source.remoteCategories ? '站源分类' : '本地分类',
                if (source.rankings) '栏目入口',
              ].join(' · '),
            ),
            if (source.defaultDisabledReason != null)
              Text(
                source.browserOnly
                    ? source.defaultDisabledReason!
                    : source.plugin
                    ? source.subtitle
                    : '${hidden ? '默认停用' : '兼容性提示'} · ${source.defaultDisabledReason}',
              ),
            if (source.browserUrl case final address?)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: address));
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已复制站点地址')));
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制站点地址'),
              ),
            Text(
              retrieved == null
                  ? '尚无栏目获取记录'
                  : '栏目上次获取 ${formatDiscoveryTimestamp(retrieved)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (notice != null) Text('剧库提示：$notice'),
            if (widget.catalog?.diagnostics != null) ...[
              const SizedBox(height: 8),
              SourceRequestStatus(
                sample: widget.catalog!.diagnostics!.latestFor(source),
              ),
              TextButton.icon(
                onPressed: () => _diagnostics(source),
                icon: const Icon(Icons.history, size: 18),
                label: const Text('查看记录'),
              ),
            ],
            if (hidden && !source.browserOnly)
              Text(
                source == widget.selected
                    ? '已隐藏 · 当前站源仍保留选择入口'
                    : source.plugin
                    ? '启用后可在选源中找到'
                    : '已隐藏 · 可搜索选择或恢复显示',
              ),
          ],
        ),
      ),
    );
  }
}
