import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_store.dart';
import '../data/app_startup.dart';
import '../data/download_store.dart';
import '../domain/models.dart';
import 'components.dart';
import 'search_page.dart';
import 'discovery_page.dart';
import 'library_page.dart';
import 'detail_page.dart';
import 'personal_page.dart';
import 'continue_watching_card.dart';
import 'downloads_page.dart';
import 'settings_page.dart';
import 'television_scope.dart';
import 'rankings_page.dart';
import 'recommendations_page.dart';

const _destinations = [
  (icon: Icons.explore_outlined, selectedIcon: Icons.explore, label: '发现'),
  (
    icon: Icons.bookmarks_outlined,
    selectedIcon: Icons.bookmarks_rounded,
    label: '追剧',
  ),
  (
    icon: Icons.downloading_outlined,
    selectedIcon: Icons.downloading_rounded,
    label: '下载',
  ),
];

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
  bool _savingRecords = false;
  int _resumeGeneration = 0;
  void _cancelResume() {
    _resumeGeneration++;
    _resuming = false;
  }

  AppStore get store => widget.store;

  Future<void> _retrySave() async {
    if (_savingRecords) return;
    setState(() => _savingRecords = true);
    try {
      await store.persist(cache: false);
    } catch (_) {
      // AppStore keeps the original intent and its save error available.
    } finally {
      if (mounted) setState(() => _savingRecords = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      oldWidget.store.records.cancelUpdateChecks();
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
    await _showSearch(context, store, widget.downloads);
  }

  void _openLibrary() {
    setState(_cancelResume);
    final owner = store, downloads = widget.downloads;
    owner.records.cancelUpdateChecks();
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) => LibraryPage(
          store: owner,
          onSearch: () => _showSearch(routeContext, owner, downloads),
          onOpen: (drama) => openDrama(routeContext, owner, downloads, drama),
        ),
      ),
    );
  }

  void _openFeed() {
    setState(_cancelResume);
    final owner = store, downloads = widget.downloads;
    final source = owner.catalog.source;
    owner.records.cancelUpdateChecks();
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) {
          void open(Drama drama) =>
              openDrama(routeContext, owner, downloads, drama);
          return source == DramaSource.hongguo
              ? RecommendationsPage(store: owner, onOpen: open)
              : RankingsPage(store: owner, onOpen: open);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildLayout);

  Widget _buildLayout(BuildContext context, BoxConstraints bounds) {
    final television = TelevisionScope.of(context);
    final wide =
        television || bounds.maxWidth >= 900 && bounds.maxHeight >= 480;
    return Scaffold(
      appBar: AppBar(
        title: const Text('果果'),
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
      body: LayoutBuilder(
        builder: (context, bodyBounds) => Row(
          children: [
            if (television)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: SizedBox(
                  width: 128,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _destinations.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              autofocus: i == _tab,
                              onPressed: () => _selectTab(i),
                              icon: Icon(_destinations[i].icon),
                              label: Text(_destinations[i].label),
                              style: ButtonStyle(
                                backgroundColor: WidgetStatePropertyAll(
                                  i == _tab
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerLow,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              )
            else if (wide)
              NavigationRail(
                selectedIndex: _tab,
                onDestinationSelected: _selectTab,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final destination in _destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: Text(destination.label),
                    ),
                ],
              ),
            Expanded(
              key: const ValueKey('home-pages'),
              child: _content(bodyBounds.maxHeight * .4),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _selectTab,
              destinations: [
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: destination.label,
                  ),
              ],
            ),
    );
  }

  void _selectTab(int value) {
    if (!mounted ||
        value == _tab ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    store.records.cancelUpdateChecks();
    setState(() {
      _cancelResume();
      _tab = value;
    });
  }

  Widget _content(double maxNoticeHeight) => Column(
    children: [
      ListenableBuilder(
        listenable: Listenable.merge([
          store,
          if (widget.startup != null) widget.startup!,
        ]),
        builder: (context, _) {
          final notices = <Widget>[
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
              const _Notice('当前离线 · 可以浏览缓存与观看已下载分集', Icons.wifi_off_rounded),
            if (store.persistenceError != null)
              _Notice(
                _savingRecords ? '正在保存记录…' : store.persistenceError!,
                Icons.warning_amber_rounded,
                retryLabel: '重试保存',
                onRetry: _savingRecords ? null : () => unawaited(_retrySave()),
              ),
            if (store.cachePersistenceError != null)
              _Notice(
                store.cachePersistenceError!,
                Icons.warning_amber_rounded,
              ),
          ];
          if (notices.isEmpty) return const SizedBox.shrink();
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxNoticeHeight),
            child: SingleChildScrollView(
              primary: false,
              child: Column(children: notices),
            ),
          );
        },
      ),
      Expanded(
        child: IndexedStack(
          index: _tab,
          children: [
            ExcludeFocus(
              excluding: _tab != 0 || !_routeActive,
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  store.catalog,
                  store,
                  if (widget.startup != null) widget.startup!,
                ]),
                builder: (context, _) => DiscoveryPage(
                  store: store,
                  source: store.catalog.source,
                  active: _tab == 0 && _routeActive,
                  ready: widget.startup == null || widget.startup!.coreReady,
                  autoLoad: widget.autoLoad || widget.startup != null,
                  onOpen: _open,
                  onSearch: _openSearch,
                  onLibrary: _openLibrary,
                  onMore: _openFeed,
                  continuation: ListenableBuilder(
                    listenable: Listenable.merge([
                      store.records,
                      store.records.progress,
                    ]),
                    builder: (context, _) {
                      final recent = store.records.continuable;
                      return recent.isEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: _continueCard(recent.first),
                            );
                    },
                  ),
                ),
              ),
            ),
            ExcludeFocus(
              excluding: _tab != 1 || !_routeActive,
              child: PersonalPage(
                store: store,
                downloads: widget.downloads,
                active: _tab == 1 && _routeActive,
              ),
            ),
            ExcludeFocus(
              excluding: _tab != 2 || !_routeActive,
              child: DownloadsPage(
                store: store,
                downloads: widget.downloads,
                onOpen: _open,
                active: _tab == 2,
              ),
            ),
          ],
        ),
      ),
    ],
  );

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

Future<void> _showSearch(
  BuildContext context,
  AppStore store,
  DownloadStore downloads,
) async {
  store.records.cancelUpdateChecks();
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (routeContext) => SearchPage(
        store: store,
        onOpen: (drama) => openDrama(routeContext, store, downloads, drama),
      ),
    ),
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
