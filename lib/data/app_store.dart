import 'dart:convert';
import 'dart:async';

import 'search_cache.dart';
import 'series_lookup.dart';
export 'search_cache.dart' show CatalogSearchResult;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/catalog_query.dart';
import '../domain/series_title.dart';
import '../domain/playback_diagnostic.dart';
import '../platform/provider_client.dart';
import 'storage.dart';

class SourceCategory {
  const SourceCategory(this.id, this.name);
  final String id, name;
}

class _CatalogSlice {
  List<Drama> items = [];
  int page = 0;
  bool more = false, loading = false;
  String? error;
  Map<String, dynamic> toJson() => {
    'items': items.map((d) => d.toJson()).toList(),
    'page': page,
    'more': more,
  };
  static _CatalogSlice fromJson(Map value) => _CatalogSlice()
    ..items = (value['items'] as List)
        .map((d) => Drama.fromJson(Map<String, dynamic>.from(d as Map)))
        .toList()
    ..page = value['page'] as int
    ..more = value['more'] == true;
}

class AppStore extends ChangeNotifier {
  AppStore({
    required this.storage,
    required this.provider,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final DateTime Function() now;
  static const episodeFreshness = Duration(hours: 6);
  final Map<String, DateTime> episodeUpdatedAt = {};
  final Map<String, Set<String>> episodeSeenIds = {};
  final Map<String, Future<List<Episode>>> _episodeRequests = {};
  final Map<String, String> episodeErrors = {};
  bool checkingUpdates = false;
  int _updateGeneration = 0;
  SeriesLookup? _updateLookup;
  bool hideVip = true;
  final List<String> recentSearches = [];
  final Map<String, Future<Drama>> _detailRequests = {};
  final Map<String, DateTime> _detailChecked = {};
  final Map<String, Drama> details = {};
  final Map<String, String> detailErrors = {};
  final List<PlaybackDiagnostic> playbackDiagnostics = [];
  static const maxPlaybackDiagnostics = 30;
  final LocalStorage storage;
  final ProviderClient provider;
  final Map<DramaSource, List<Drama>> catalogs = {};
  final Map<String, List<Episode>> episodeCache = {};
  final Map<String, Drama> favorites = {};
  final Map<String, WatchRecord> history = {};
  final Map<String, SeasonReminder> seasonReminders = {};
  DateTime? _lastReminderEnabledAt;
  final Set<SeriesLookup> _seriesLookups = {};
  bool _closed = false;
  final libraryChanges = ChangeNotifier();
  final searchCache = SearchCache();
  final Map<String, Future<CatalogSearchResult>> _searchRequests = {};
  int _searchSerial = 0;
  final Map<DramaSource, String> sourceErrors = {};
  final Set<DramaSource> loadingSources = {};
  final Map<DramaSource, int> catalogPages = {};
  final Map<DramaSource, bool> hasMore = {};
  DramaSource source = DramaSource.hongguo;
  ThemeMode themeMode = ThemeMode.system;
  bool cellularDownloads = false, cellularPrefetch = false, prefetch = true;
  bool autoAdvance = true;
  bool progressivePreparation = false;
  double playbackSpeed = 1;
  bool offline = false;
  String? persistenceError;
  final Map<String, _CatalogSlice> _slices = {};
  final Map<DramaSource, String> selectedCategories = {};
  final Map<DramaSource, List<SourceCategory>> sourceCategories = {};
  final Map<DramaSource, String> categoryErrors = {};
  final Set<DramaSource> _loadingCategories = {};
  String get selectedCategory => selectedCategories[source] ?? '';
  String _sliceKey(DramaSource target, String category) =>
      '${target.name}|$category';
  _CatalogSlice? get _activeSlice =>
      _slices[_sliceKey(source, selectedCategory)];
  List<Drama> get library => source.remoteCategories
      ? _activeSlice?.items ?? []
      : catalogs[source] ?? [];
  bool get libraryLoading => source.remoteCategories
      ? _activeSlice?.loading == true
      : loadingSources.contains(source);
  bool get libraryHasMore => source.remoteCategories
      ? _activeSlice?.more == true
      : hasMore[source] == true;
  String? get libraryError =>
      source.remoteCategories ? _activeSlice?.error : sourceErrors[source];

  Future<void> loadCategories([DramaSource? selected]) async {
    final target = selected ?? source;
    if (!target.remoteCategories ||
        offline ||
        !_loadingCategories.add(target)) {
      return;
    }
    try {
      final result = await provider.call('categories', {'source': target.name});
      sourceCategories[target] = (result['items'] as List)
          .map((v) => SourceCategory(v['id'] as String, v['name'] as String))
          .toList();
      categoryErrors.remove(target);
      await persist();
    } catch (error) {
      categoryErrors[target] = '$error';
    } finally {
      _loadingCategories.remove(target);
      notifyListeners();
    }
  }

  Future<void> selectCategory(String category) async {
    final target = source;
    selectedCategories[target] = category;
    notifyListeners();
    if (!_slices.containsKey(_sliceKey(target, category))) {
      await _loadCategory(target, category, more: false);
    }
    await persist();
  }

  Future<void> _loadCategory(
    DramaSource target,
    String category, {
    required bool more,
  }) async {
    if (offline) return;
    final slice = _slices.putIfAbsent(
      _sliceKey(target, category),
      _CatalogSlice.new,
    );
    if (slice.loading || (more && !slice.more)) return;
    slice.loading = true;
    slice.error = null;
    notifyListeners();
    try {
      final page = more ? slice.page + 1 : 1;
      final result = await provider.call('catalog', {
        'source': target.name,
        'category': category,
        'page': page,
      });
      final rows = _parseRows(result, target);
      slice.items = {
        for (final row in [...(more ? slice.items : <Drama>[]), ...rows])
          row.key: row,
      }.values.toList();
      slice.page = page;
      slice.more = result['hasMore'] == true;
      final warning = result['warning'] as String? ?? '';
      slice.error = warning.isEmpty ? null : warning;
      _mergeCatalog(target, rows);
      await persist();
    } catch (error) {
      slice.error = '$error';
    } finally {
      slice.loading = false;
      notifyListeners();
    }
  }

  List<WatchRecord> get recent =>
      history.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  Future<void> load() async {
    final state = await storage.read();
    if (state != null) discardDeletedSources(state);
    if (state == null) return;
    searchCache.restore(state["searchCache"] as Map? ?? {});
    if (state['version'] != 1) throw const FormatException('本地数据版本不受支持，已保留原文件');
    // Parse the entire document before mutating state.
    final backup = RecordBackup.fromJson(
      Map<String, dynamic>.from(state['records'] as Map),
    );
    final loadedCatalogs = <DramaSource, List<Drama>>{};
    for (final entry in (state['catalogs'] as Map? ?? {}).entries) {
      loadedCatalogs[DramaSource.parse(entry.key)] = (entry.value as List)
          .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
    }
    final loadedEpisodes = <String, List<Episode>>{};
    for (final entry in (state['episodes'] as Map? ?? {}).entries) {
      final rows = entry.value as List;
      loadedEpisodes[entry.key as String] = [
        for (var i = 0; i < rows.length; i++)
          Episode.fromJson(Map<String, dynamic>.from(rows[i] as Map), i),
      ];
    }
    final loadedSlices = <String, _CatalogSlice>{
      for (final entry in (state['categorySlices'] as Map? ?? {}).entries)
        entry.key as String: _CatalogSlice.fromJson(entry.value as Map),
    };
    final loadedSelections = <DramaSource, String>{
      for (final entry in (state['selectedCategories'] as Map? ?? {}).entries)
        DramaSource.parse(entry.key): entry.value as String,
    };
    final loadedCategories = <DramaSource, List<SourceCategory>>{
      for (final entry in (state['sourceCategories'] as Map? ?? {}).entries)
        DramaSource.parse(entry.key): (entry.value as List)
            .map((v) => SourceCategory(v['id'] as String, v['name'] as String))
            .toList(),
    };
    sourceCategories.addAll(loadedCategories);
    _slices.addAll(loadedSlices);
    selectedCategories.addAll(loadedSelections);
    source = DramaSource.parse(state['source'] ?? 'hongguo');
    themeMode = ThemeMode.values.firstWhere(
      (v) => v.name == state['theme'],
      orElse: () => ThemeMode.system,
    );
    cellularDownloads = state['cellularDownloads'] == true;
    cellularPrefetch = state['cellularPrefetch'] == true;
    prefetch = state['prefetch'] != false;
    autoAdvance = state['autoAdvance'] != false;
    progressivePreparation = state['progressivePreparation'] == true;
    final speed = state['playbackSpeed'];
    if (speed is num && const [.75, 1, 1.25, 1.5, 2].contains(speed)) {
      playbackSpeed = speed.toDouble();
    }
    hideVip = state['hideVip'] != false;
    recentSearches.addAll(
      (state['recentSearches'] as List? ?? []).cast<String>().take(10),
    );
    catalogs.addAll(loadedCatalogs);
    for (final entry in (state['pages'] as Map? ?? {}).entries) {
      catalogPages[DramaSource.parse(entry.key)] = entry.value as int;
    }
    for (final entry in (state['hasMore'] as Map? ?? {}).entries) {
      hasMore[DramaSource.parse(entry.key)] = entry.value == true;
    }
    episodeCache.addAll(loadedEpisodes);
    for (final entry in (state['episodeUpdatedAt'] as Map? ?? {}).entries) {
      final date = DateTime.tryParse('${entry.value}');
      if (date != null) episodeUpdatedAt[entry.key as String] = date;
    }
    for (final entry in (state['episodeSeenIds'] as Map? ?? {}).entries) {
      episodeSeenIds[entry.key as String] = Set<String>.from(
        entry.value as List,
      );
    }
    for (final raw in (state['playbackDiagnostics'] as List? ?? []).take(
      maxPlaybackDiagnostics,
    )) {
      try {
        playbackDiagnostics.add(
          PlaybackDiagnostic.fromJson(Map<String, dynamic>.from(raw as Map)),
        );
      } catch (_) {
        /* Ignore obsolete diagnostic samples. */
      }
    }
    _merge(backup);
    notifyListeners();
  }

  Map<String, dynamic> snapshot() => {
    'sourceCategories': {
      for (final entry in sourceCategories.entries)
        entry.key.name: entry.value
            .map((v) => {'id': v.id, 'name': v.name})
            .toList(),
    },
    'categorySlices': {
      for (final entry in _slices.entries) entry.key: entry.value.toJson(),
    },
    'selectedCategories': {
      for (final entry in selectedCategories.entries)
        entry.key.name: entry.value,
    },
    'pages': {
      for (final entry in catalogPages.entries) entry.key.name: entry.value,
    },
    'hasMore': {
      for (final entry in hasMore.entries) entry.key.name: entry.value,
    },
    'version': 1,
    'playbackDiagnostics': playbackDiagnostics.map((d) => d.toJson()).toList(),
    'source': source.name,
    'theme': themeMode.name,
    'cellularDownloads': cellularDownloads,
    'cellularPrefetch': cellularPrefetch,
    'prefetch': prefetch,
    'autoAdvance': autoAdvance,
    'progressivePreparation': progressivePreparation,
    'playbackSpeed': playbackSpeed,
    'hideVip': hideVip,
    'recentSearches': List<String>.of(recentSearches),
    'records': RecordBackup(
      favorites.values.toList(),
      history.values.toList(),
      seasonReminders: seasonReminders.values.toList(),
    ).toJson(),
    'searchCache': searchCache.toJson(),
    'catalogs': {
      for (final entry in catalogs.entries)
        entry.key.name: entry.value.map((v) => v.toJson()).toList(),
    },
    'episodeUpdatedAt': {
      for (final entry in episodeUpdatedAt.entries)
        entry.key: entry.value.toIso8601String(),
    },
    'episodeSeenIds': {
      for (final entry in episodeSeenIds.entries)
        entry.key: entry.value.toList(),
    },
    'episodes': {
      for (final entry in episodeCache.entries)
        entry.key: entry.value.map((v) => v.raw).toList(),
    },
  };

  Future<void> persist() async {
    try {
      await storage.write(snapshot());
      persistenceError = null;
    } catch (_) {
      persistenceError = '记录暂未保存，请检查可用空间后重试';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> recordPlayback(PlaybackDiagnostic sample) async {
    playbackDiagnostics.insert(0, sample);
    if (playbackDiagnostics.length > maxPlaybackDiagnostics) {
      playbackDiagnostics.removeRange(
        maxPlaybackDiagnostics,
        playbackDiagnostics.length,
      );
    }
    await persist();
  }

  Future<void> clearPlaybackDiagnostics() async {
    playbackDiagnostics.clear();
    await persist();
    notifyListeners();
  }

  Future<void> selectSource(DramaSource next) async {
    source = next;
    notifyListeners();
    await persist();
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await persist();
  }

  Future<void> setNetwork({bool? downloads, bool? preload}) async {
    cellularDownloads = downloads ?? cellularDownloads;
    cellularPrefetch = preload ?? cellularPrefetch;
    notifyListeners();
    await persist();
  }

  Future<void> setPrefetch(bool enabled) async {
    prefetch = enabled;
    notifyListeners();
    await persist();
  }

  Future<void> setPlayback({
    bool? advance,
    double? speed,
    bool? progressive,
  }) async {
    if (speed != null && !const [.75, 1, 1.25, 1.5, 2].contains(speed)) {
      throw ArgumentError.value(speed, 'speed');
    }
    autoAdvance = advance ?? autoAdvance;
    progressivePreparation = progressive ?? progressivePreparation;
    playbackSpeed = speed ?? playbackSpeed;
    notifyListeners();
    await persist();
  }

  void setOffline(bool value) {
    if (offline != value) {
      offline = value;
      notifyListeners();
    }
  }

  Future<void> refresh([DramaSource? selected]) async {
    final target = selected ?? source;
    if (target.remoteCategories) {
      await Future.wait([
        loadCategories(target),
        _loadCategory(target, selectedCategories[target] ?? '', more: false),
      ]);
      return;
    }
    if (!loadingSources.add(target)) return;
    sourceErrors.remove(target);
    notifyListeners();
    try {
      final response = await provider.call('catalog', {'source': target.name});
      final incoming = _parseRows(response, target);
      _mergeCatalog(target, incoming);
      catalogPages[target] = 1;
      hasMore[target] = response['hasMore'] == true;
      final warning = response['warning'] as String? ?? '';
      if (warning.isNotEmpty) sourceErrors[target] = warning;
      await persist();
    } catch (error) {
      sourceErrors[target] = '$error';
    } finally {
      loadingSources.remove(target);
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    final target = source;
    if (target.remoteCategories) {
      await _loadCategory(target, selectedCategory, more: true);
      return;
    }
    if (offline || hasMore[target] != true) return;
    if (!loadingSources.add(target)) return;
    notifyListeners();
    try {
      final page = (catalogPages[target] ?? 1) + 1;
      final response = await provider.call('catalog', {
        'source': target.name,
        'page': page,
      });
      final rows = _parseRows(response, target);
      _mergeCatalog(target, rows);
      catalogPages[target] = page;
      hasMore[target] = response['hasMore'] == true;
      final warning = response['warning'] as String? ?? '';
      if (warning.isNotEmpty) {
        sourceErrors[target] = warning;
      } else {
        sourceErrors.remove(target);
      }
      await persist();
    } catch (error) {
      sourceErrors[target] = '$error';
    } finally {
      loadingSources.remove(target);
      notifyListeners();
    }
  }

  Future<List<Drama>> search(DramaSource target, String query) async =>
      (await searchCatalog(target, query)).items;

  Future<CatalogSearchResult> searchCatalog(
    DramaSource target,
    String query, {
    int page = 1,
    String? requestId,
    ValueChanged<CatalogSearchResult>? onPartial,
    bool rememberQuery = true,
    bool refresh = false,
    bool Function()? isActive,
  }) async {
    query = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) return CatalogSearchResult(catalogs[target] ?? []);
    final key = '${target.name}|$query|$page';
    final cached = searchCache.read(key, now());
    if (cached != null && !refresh) {
      onPartial?.call(cached.result);
      if (cached.fresh || offline) return cached.result;
    }
    if (offline) throw const ProviderException('当前离线，可继续搜索已缓存的短剧');
    // Independent owners with progress/cancellation must not share request IDs.
    final pending = _searchRequests[key];
    if (requestId == null &&
        onPartial == null &&
        rememberQuery &&
        !refresh &&
        pending != null) {
      return pending;
    }
    final id =
        requestId ?? 'store-${++_searchSerial}-${now().microsecondsSinceEpoch}';
    final operation = _searchCatalog(
      target,
      query,
      page,
      id,
      onPartial,
      rememberQuery,
      isActive,
    );
    if (requestId == null && onPartial == null && rememberQuery && !refresh) {
      _searchRequests[key] = operation;
    }
    try {
      return await operation;
    } finally {
      if (identical(_searchRequests[key], operation)) {
        _searchRequests.remove(key);
      }
    }
  }

  CatalogSearchResult _searchResult(
    Map<String, dynamic> response,
    DramaSource target,
  ) => CatalogSearchResult(
    _parseRows(response, target),
    warning: response['warning'] as String? ?? '',
    limited: response['limited'] == true,
    hasMore: response['hasMore'] == true,
    total: response['total'] as int? ?? 0,
  );

  Future<CatalogSearchResult> _searchCatalog(
    DramaSource target,
    String query,
    int page,
    String id,
    ValueChanged<CatalogSearchResult>? onPartial,
    bool rememberQuery,
    bool Function()? isActive,
  ) async {
    Timer? timer;
    bool polling = false, completed = false;
    final args = {
      'source': target.name,
      'query': query,
      'page': page,
      'requestId': id,
    };
    if (target == DramaSource.hongguo && onPartial != null) {
      timer = Timer.periodic(const Duration(milliseconds: 700), (_) async {
        if (isActive?.call() == false) {
          timer?.cancel();
          return;
        }
        if (polling || completed) return;
        polling = true;
        try {
          final response = await provider.call('searchProgress', args);
          if (!completed &&
              isActive?.call() != false &&
              response['source'] == target.name &&
              response['query'] == query) {
            final partial = _searchResult(response, target);
            if (partial.items.isNotEmpty) onPartial(partial);
          }
        } catch (_) {
          /* The final search call owns errors. */
        } finally {
          polling = false;
        }
      });
    }
    try {
      final response = await provider.call('search', args);
      completed = true;
      if (isActive?.call() == false) throw const SeriesLookupCancelled();
      final result = _searchResult(response, target);
      searchCache.put('${target.name}|$query|$page', result, now());
      if (rememberQuery) {
        recentSearches.remove(query);
        recentSearches.insert(0, query);
        if (recentSearches.length > 10) recentSearches.removeLast();
      }
      _mergeCatalog(target, result.items);
      await persist();
      if (isActive?.call() == false) throw const SeriesLookupCancelled();
      notifyListeners();
      return result;
    } finally {
      completed = true;
      timer?.cancel();
      unawaited(cancelSearch(target, query, id));
    }
  }

  Future<void> cancelSearch(DramaSource target, String query, String id) async {
    try {
      await provider.call('cancelSearch', {
        'source': target.name,
        'query': query.trim().replaceAll(RegExp(r'\s+'), ' '),
        'requestId': id,
      });
    } catch (_) {
      /* Cancellation is best effort on detached platforms. */
    }
  }

  Future<void> saveRecommendations(List<Drama> incoming) async {
    _mergeCatalog(DramaSource.hongguo, incoming);
    await persist();
    notifyListeners();
  }

  List<Drama> relatedTo(Drama anchor, {int limit = 200}) =>
      relatedSeries(anchor, [
        ...catalogs.values.expand((rows) => rows),
        ...searchCache.dramas,
        ...favorites.values,
        ...history.values.map((r) => r.drama),
        ...seasonReminders.values.expand(
          (r) => r.seasons.values.map((n) => n.drama),
        ),
      ], limit: limit);

  SeriesLookup lookupSeries(
    Drama anchor, {
    bool refresh = false,
    ValueChanged<CatalogSearchResult>? onPartial,
  }) {
    final info = SeriesTitle.parse(anchor.title);
    if (anchor.source != DramaSource.hongguo ||
        info == null ||
        info.baseTitle.runes.length > 80) {
      throw const ProviderException('这部剧暂不支持同系列联网补全');
    }
    var active = true;
    String? requestId;
    final cancelled = Completer<CatalogSearchResult>();
    Timer? timeout;
    void abort(Object error) {
      if (!active) return;
      active = false;
      timeout?.cancel();
      if (requestId != null) {
        unawaited(cancelSearch(anchor.source, info.baseTitle, requestId!));
      }
      cancelled.completeError(error);
    }

    final candidates = <String, Drama>{
      for (final d in relatedTo(anchor, limit: 201)) d.key: d,
    };
    CatalogSearchResult snapshot(CatalogSearchResult result) {
      final matches = relatedSeries(anchor, candidates.values, limit: 201);
      return CatalogSearchResult(
        matches.take(200).toList(),
        warning: result.warning,
        limited: result.limited || matches.length > 200,
        hasMore: result.hasMore,
        total: result.total,
      );
    }

    Future<CatalogSearchResult> run() async {
      if (offline) {
        return snapshot(
          const CatalogSearchResult(
            [],
            limited: true,
            warning: '当前离线，显示已有同系列作品',
          ),
        );
      }
      var result = const CatalogSearchResult(<Drama>[]);
      for (var page = 1; page <= 3; page++) {
        if (!active) throw const SeriesLookupCancelled();
        requestId = 'series-${++_searchSerial}-${now().microsecondsSinceEpoch}';
        result = await searchCatalog(
          anchor.source,
          info.baseTitle,
          page: page,
          requestId: requestId,
          rememberQuery: false,
          refresh: refresh,
          isActive: () => active && !_closed,
          onPartial: (partial) {
            if (!active) return;
            for (final d in partial.items) {
              candidates[d.key] = d;
            }
            onPartial?.call(snapshot(partial));
          },
        );
        if (!active) throw const SeriesLookupCancelled();
        for (final d in result.items) {
          candidates[d.key] = d;
        }
        onPartial?.call(snapshot(result));
        if (!result.hasMore || result.warning.isNotEmpty || result.limited) {
          break;
        }
      }
      return snapshot(result);
    }

    timeout = Timer(
      const Duration(seconds: 20),
      () => abort(const ProviderException('同系列搜索超时，请重试')),
    );
    late SeriesLookup lookup;
    final future = Future.any([run(), cancelled.future]).whenComplete(() {
      active = false;
      timeout?.cancel();
      _seriesLookups.remove(lookup);
    });
    lookup = SeriesLookup(future, () => abort(const SeriesLookupCancelled()));
    _seriesLookups.add(lookup);
    return lookup;
  }

  void cancelSeriesLookups() {
    for (final lookup in _seriesLookups.toList()) {
      lookup.cancel();
    }
  }

  Future<void> toggleSeasonReminder(Drama drama) async {
    final previous = seasonReminders[drama.key];
    if (previous != null) {
      seasonReminders.remove(drama.key);
    } else {
      if (drama.source != DramaSource.hongguo ||
          SeriesTitle.parse(drama.title) == null ||
          seasonReminders.length >= 1000) {
        throw const ProviderException('暂时无法添加新季提醒');
      }
      seasonReminders[drama.key] = SeasonReminder(
        anchor: drama,
        updatedAt: _newReminderTime(),
      );
    }
    final updated = seasonReminders[drama.key];
    try {
      await persist();
    } catch (_) {
      if (identical(seasonReminders[drama.key], updated)) {
        if (previous == null) {
          seasonReminders.remove(drama.key);
        } else {
          seasonReminders[drama.key] = previous;
        }
      }
      if (!_closed) notifyListeners();
      rethrow;
    }
    if (!_closed) notifyListeners();
  }

  DateTime _newReminderTime() {
    final date = now();
    final previous = _lastReminderEnabledAt;
    return _lastReminderEnabledAt = previous == null || date.isAfter(previous)
        ? date
        : previous.add(const Duration(microseconds: 1));
  }

  DateTime _reminderTime(SeasonReminder previous) {
    final date = now();
    return date.isAfter(previous.updatedAt)
        ? date
        : previous.updatedAt.add(const Duration(microseconds: 1));
  }

  Future<void> observeSeasons(
    Drama anchor,
    CatalogSearchResult result, {
    SeasonReminder? expected,
  }) async {
    final current = seasonReminders[anchor.key];
    if (current == null ||
        (expected != null && current.enabledAt != expected.enabledAt)) {
      return;
    }
    final complete =
        !result.limited && !result.hasMore && result.warning.isEmpty;
    if (!current.initialized && !complete) return;
    final info = SeriesTitle.parse(current.anchor.title)!;
    final seasons = Map<String, SeasonNotice>.of(current.seasons);
    for (final drama in relatedSeries(current.anchor, result.items)) {
      final season = SeriesTitle.parse(drama.title)!;
      if (season.season <= info.season ||
          (seasons.isNotEmpty &&
              SeriesTitle.parse(seasons.values.first.drama.title)!.unit !=
                  season.unit)) {
        continue;
      }
      if (!seasons.containsKey(drama.key) && seasons.length >= 200) continue;
      seasons[drama.key] = SeasonNotice(
        drama,
        read: seasons[drama.key]?.read ?? !current.initialized,
      );
    }
    final updated = SeasonReminder(
      anchor: current.anchor,
      updatedAt: _reminderTime(current),
      enabledAt: current.enabledAt,
      initialized: current.initialized || complete,
      seasons: seasons,
    );
    seasonReminders[anchor.key] = updated;
    try {
      await persist();
    } catch (_) {
      if (identical(seasonReminders[anchor.key], updated)) {
        seasonReminders[anchor.key] = current;
      }
      if (!_closed) notifyListeners();
      rethrow;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> markSeasonRead(String key) async {
    final old = <String, SeasonReminder>{};
    final changed = <String, SeasonReminder>{};
    for (final entry in seasonReminders.entries.toList()) {
      final notice = entry.value.seasons[key];
      if (notice == null || notice.read) continue;
      old[entry.key] = entry.value;
      changed[entry.key] = SeasonReminder(
        anchor: entry.value.anchor,
        initialized: entry.value.initialized,
        updatedAt: _reminderTime(entry.value),
        enabledAt: entry.value.enabledAt,
        seasons: {
          ...entry.value.seasons,
          key: SeasonNotice(notice.drama, read: true),
        },
      );
    }
    if (changed.isEmpty) return;
    seasonReminders.addAll(changed);
    try {
      await persist();
    } catch (_) {
      for (final entry in old.entries) {
        if (identical(seasonReminders[entry.key], changed[entry.key])) {
          seasonReminders[entry.key] = entry.value;
        }
      }
      if (!_closed) notifyListeners();
      rethrow;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> setHideVip(bool value) async {
    hideVip = value;
    notifyListeners();
    await persist();
  }

  Future<void> clearSearches() async {
    recentSearches.clear();
    notifyListeners();
    await persist();
  }

  Future<List<String>> suggestions(String query) async {
    if (offline || query.trim().isEmpty) return [];
    final result = await provider.call('suggestions', {
      'source': 'hongguo',
      'query': query.trim(),
    });
    return (result['items'] as List? ?? [])
        .map((row) => (row as Map)['name'] as String)
        .take(10)
        .toList();
  }

  Drama currentDrama(Drama drama) =>
      (catalogs[drama.source] ?? [])
          .where((d) => d.key == drama.key)
          .firstOrNull ??
      details[drama.key] ??
      favorites[drama.key] ??
      drama;

  Future<Drama> refreshDetail(Drama drama, {bool force = false}) async {
    final current = currentDrama(drama);
    if (offline) return current;
    final pending = _detailRequests[drama.key];
    if (pending != null) return pending;
    final checked = _detailChecked[drama.key];
    if (!force &&
        checked != null &&
        now().difference(checked) <
            (detailErrors.containsKey(drama.key)
                ? const Duration(seconds: 30)
                : const Duration(minutes: 5))) {
      return current;
    }
    final request = _fetchDetail(current);
    _detailRequests[drama.key] = request;
    try {
      return await request;
    } finally {
      _detailRequests.remove(drama.key);
    }
  }

  Future<Drama> _fetchDetail(Drama drama) async {
    try {
      final result = await provider.call('detail', {'id': drama.id});
      final patch = Drama.fromJson(
        Map<String, dynamic>.from(result['item'] as Map),
      );
      final replaceTags = drama.source == DramaSource.huangguo;
      final updated = currentDrama(
        drama,
      ).merge(patch, replaceTags: replaceTags);
      details[drama.key] = updated;
      _mergeCatalog(drama.source, [updated], replaceTags: replaceTags);
      if (favorites.containsKey(drama.key)) favorites[drama.key] = updated;
      final record = history[drama.key];
      if (record != null) {
        history[drama.key] = WatchRecord(
          drama: updated,
          episodeId: record.episodeId,
          episodeIndex: record.episodeIndex,
          positionMs: record.positionMs,
          durationMs: record.durationMs,
          updatedAt: record.updatedAt,
        );
      }
      _detailChecked[drama.key] = now();
      detailErrors.remove(drama.key);
      await persist();
      notifyListeners();
      return updated;
    } catch (error) {
      _detailChecked[drama.key] = now();
      detailErrors[drama.key] = '资料暂未更新，已保留现有内容';
      notifyListeners();
      return currentDrama(drama);
    }
  }

  List<Drama> _parseRows(Map<String, dynamic> result, DramaSource target) {
    final rows = (result['items'] as List? ?? [])
        .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (rows.any((v) => v.source != target)) {
      throw const FormatException('站源返回了不匹配的内容');
    }
    return rows;
  }

  void _mergeCatalog(
    DramaSource target,
    List<Drama> incoming, {
    bool replaceTags = false,
  }) {
    final merged = {
      for (final row in catalogs[target] ?? <Drama>[]) row.key: row,
    };
    for (final row in incoming) {
      merged[row.key] =
          merged[row.key]?.merge(row, replaceTags: replaceTags) ?? row;
    }
    catalogs[target] = merged.values.toList();
    for (final entry in _slices.entries) {
      if (entry.key.startsWith('${target.name}|')) {
        entry.value.items = entry.value.items
            .map((row) => merged[row.key] ?? row)
            .toList();
      }
    }
  }

  int newEpisodeCount(Drama drama) {
    final seen = episodeSeenIds[drama.key];
    if (seen == null) return 0;
    return (episodeCache[drama.key] ?? [])
        .where((e) => !seen.contains(e.id))
        .length;
  }

  Future<void> markEpisodesSeen(Drama drama, List<Episode> rows) async {
    episodeSeenIds[drama.key] = rows.map((e) => e.id).toSet();
    await persist();
    notifyListeners();
  }

  Future<List<Episode>> episodes(Drama drama, {bool refresh = false}) async {
    if (offline && refresh) throw const ProviderException('离线时无法刷新分集');
    final cached = episodeCache[drama.key];
    final updated = episodeUpdatedAt[drama.key];
    if (cached != null &&
        cached.isNotEmpty &&
        (offline ||
            (!refresh &&
                updated != null &&
                now().difference(updated) >= Duration.zero &&
                now().difference(updated) < episodeFreshness))) {
      return cached;
    }
    if (offline) throw const ProviderException('离线时没有可用的分集缓存');
    final request =
        _episodeRequests[drama.key] ?? _fetchEpisodes(drama, cached);
    _episodeRequests[drama.key] = request;
    try {
      return await request;
    } catch (_) {
      if (!refresh && cached != null && cached.isNotEmpty) return cached;
      rethrow;
    } finally {
      if (identical(_episodeRequests[drama.key], request)) {
        _episodeRequests.remove(drama.key);
      }
    }
  }

  Future<List<Episode>> _fetchEpisodes(
    Drama drama,
    List<Episode>? cached,
  ) async {
    try {
      final rows = await provider.chapters(drama);
      if (rows.isEmpty) throw const ProviderException('暂未找到可播放分集');
      final unique = {for (final row in rows) row.id: row}.values.toList();
      episodeSeenIds.putIfAbsent(
        drama.key,
        () => (cached ?? unique).map((e) => e.id).toSet(),
      );
      episodeCache[drama.key] = unique;
      episodeUpdatedAt[drama.key] = now();
      episodeErrors.remove(drama.key);
      await persist();
      notifyListeners();
      return unique;
    } catch (_) {
      episodeErrors[drama.key] = '分集更新失败，保留上次缓存';
      notifyListeners();
      rethrow;
    }
  }

  Future<bool> checkFavoriteUpdates() async {
    if (checkingUpdates) return false;
    if (offline) throw const ProviderException('请联网后检查更新');
    checkingUpdates = true;
    final generation = ++_updateGeneration;
    notifyListeners();
    var failures = 0;
    try {
      for (final drama in favorites.values.toList()) {
        if (generation != _updateGeneration) break;
        try {
          await episodes(drama, refresh: true);
        } catch (_) {
          failures++;
        }
      }
      final results = <String, CatalogSearchResult>{};
      for (final reminder in seasonReminders.values.toList()) {
        if (generation != _updateGeneration) break;
        if (seasonReminders[reminder.anchor.key]?.enabledAt !=
            reminder.enabledAt) {
          continue;
        }
        final info = SeriesTitle.parse(reminder.anchor.title)!;
        final query = '${info.key}|${info.unit ?? ''}';
        try {
          var result = results[query];
          if (result == null) {
            _updateLookup = lookupSeries(reminder.anchor, refresh: true);
            final found = await _updateLookup!.result;
            result = CatalogSearchResult(
              [reminder.anchor, ...found.items],
              warning: found.warning,
              limited: found.limited,
              hasMore: found.hasMore,
            );
            results[query] = result;
          }
          if (generation != _updateGeneration) break;
          await observeSeasons(reminder.anchor, result, expected: reminder);
          if (result.limited || result.hasMore || result.warning.isNotEmpty) {
            failures++;
          }
        } on SeriesLookupCancelled {
          break;
        } catch (_) {
          failures++;
        }
      }
    } finally {
      _updateLookup = null;
      checkingUpdates = false;
      if (!_closed) notifyListeners();
    }
    if (generation != _updateGeneration) return false;
    if (failures > 0) throw ProviderException('$failures 部剧更新失败，已保留原有记录');
    return true;
  }

  void cancelUpdateChecks() {
    _updateGeneration++;
    _updateLookup?.cancel();
  }

  Future<void> toggleFavorite(Drama drama) async {
    if (favorites.containsKey(drama.key)) {
      favorites.remove(drama.key);
    } else {
      favorites[drama.key] = drama;
    }
    notifyListeners();
    await persist();
  }

  Future<void> saveWatch(WatchRecord record) async {
    history[record.drama.key] = record;
    libraryChanges.notifyListeners();
    await persist();
  }

  Future<void> removeHistory(String key) async {
    history.remove(key);
    notifyListeners();
    await persist();
  }

  Future<Map<String, int>> importLibraryRows(List<Drama> rows) async {
    final previous = Map<DramaSource, List<Drama>>.of(catalogs);
    final installed = <DramaSource, List<Drama>>{};
    final previousSlices = <String, List<Drama>?>{};
    final grouped = <DramaSource, List<Drama>>{};
    var imported = 0, mergedCount = 0;
    for (final row in rows) {
      if (row.id.isEmpty || row.title.isEmpty) {
        throw const FormatException('剧库包含无效条目');
      }
      grouped.putIfAbsent(row.source, () => []).add(row);
    }
    for (final entry in grouped.entries) {
      final merged = {
        for (final row in catalogs[entry.key] ?? <Drama>[]) row.key: row,
      };
      for (var row in entry.value) {
        if (row.source == DramaSource.xingguo) {
          String baseId(Drama d) => d.id.split('@').first;
          final matches = merged.values
              .where((d) => baseId(d) == baseId(row))
              .toList();
          if (matches.length == 1) {
            row = Drama.fromJson({...row.toJson(), 'id': matches.single.id});
          }
        }
        final old = merged[row.key];
        if (old == null) {
          imported++;
        } else {
          mergedCount++;
        }
        merged[row.key] = old == null
            ? row
            : old.merge(
                Drama(
                  id: old.id,
                  source: old.source,
                  title: old.title == old.id ? row.title : '',
                  description: old.description.isEmpty ? row.description : '',
                  cover: old.cover.isEmpty ? row.cover : '',
                  category: old.category.isEmpty || old.category == '未分类'
                      ? row.category
                      : '',
                  episodes: old.episodes == 0 ? row.episodes : 0,
                  heat: old.heat.isEmpty ? row.heat : '',
                  date: old.date.isEmpty ? row.date : '',
                  status: old.status.isEmpty ? row.status : '',
                  vip: old.vip ?? row.vip,
                  tags: old.tags.isEmpty ? row.tags : const [],
                ),
              );
      }
      catalogs[entry.key] = merged.values.toList();
      installed[entry.key] = catalogs[entry.key]!;
      if (entry.key.remoteCategories) {
        final key = _sliceKey(entry.key, '');
        previousSlices[key] = _slices[key]?.items;
        final slice = _slices.putIfAbsent(key, _CatalogSlice.new);
        slice.items = catalogs[entry.key]!;
      }
    }
    try {
      await persist();
    } catch (_) {
      // Undo only this import. A refresh that completed while saving keeps its
      // own rows, including changes to sources outside the imported batch.
      for (final entry in installed.entries) {
        List<Drama> undo(List<Drama> current, List<Drama>? before) {
          final originals = {
            for (final row in before ?? <Drama>[]) row.key: row,
          };
          final additions = {for (final row in entry.value) row.key: row};
          return [
            for (final row in current)
              if (!identical(row, additions[row.key]))
                row
              else if (originals.containsKey(row.key))
                originals[row.key]!,
          ];
        }

        final current = catalogs[entry.key];
        if (current != null) {
          if (identical(current, entry.value) && previous[entry.key] == null) {
            catalogs.remove(entry.key);
          } else {
            catalogs[entry.key] = undo(current, previous[entry.key]);
          }
        }
        final key = _sliceKey(entry.key, '');
        final slice = _slices[key];
        if (previousSlices.containsKey(key) && slice != null) {
          if (identical(slice.items, entry.value) &&
              previousSlices[key] == null) {
            _slices.remove(key);
          } else {
            slice.items = undo(slice.items, previousSlices[key]);
          }
        }
      }
      rethrow;
    }
    notifyListeners();
    return {
      'imported': imported,
      'merged': mergedCount,
      'total': catalogs.values.fold<int>(0, (sum, rows) => sum + rows.length),
    };
  }

  @override
  void dispose() {
    _closed = true;
    cancelUpdateChecks();
    cancelSeriesLookups();
    libraryChanges.dispose();
    super.dispose();
  }

  String exportBackup() => const JsonEncoder.withIndent('  ').convert(
    RecordBackup(
      favorites.values.toList(),
      history.values.toList(),
      seasonReminders: seasonReminders.values.toList(),
    ).toJson(),
  );
  RecordBackup inspectBackup(String raw) {
    if (utf8.encode(raw).length > 20 * 1024 * 1024) {
      throw const FormatException('备份文件超过 20 MB');
    }
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      discardDeletedSources(decoded);
      return RecordBackup.fromJson(decoded);
    } catch (_) {
      throw const FormatException('备份损坏或格式不兼容，原记录未修改');
    }
  }

  Future<void> importBackup(RecordBackup backup) async {
    if ({
          ...seasonReminders.keys,
          ...backup.seasonReminders.map((r) => r.anchor.key),
        }.length >
        1000) {
      throw const FormatException('合并后的新季提醒超过上限，原记录未修改');
    }
    final oldFavorites = Map<String, Drama>.of(favorites);
    final oldHistory = Map<String, WatchRecord>.of(history);
    final oldReminders = Map<String, SeasonReminder>.of(seasonReminders);
    _merge(backup);
    final installedReminders = Map<String, SeasonReminder>.of(seasonReminders);
    try {
      await persist();
    } catch (_) {
      favorites
        ..clear()
        ..addAll(oldFavorites);
      history
        ..clear()
        ..addAll(oldHistory);
      for (final entry in installedReminders.entries) {
        if (!identical(seasonReminders[entry.key], entry.value)) continue;
        final previous = oldReminders[entry.key];
        if (previous == null) {
          seasonReminders.remove(entry.key);
        } else {
          seasonReminders[entry.key] = previous;
        }
      }
      if (!_closed) notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  void _merge(RecordBackup backup) {
    for (final drama in backup.favorites) {
      favorites.putIfAbsent(drama.key, () => drama);
    }
    for (final record in backup.history) {
      final existing = history[record.drama.key];
      if (existing == null || record.updatedAt.isAfter(existing.updatedAt)) {
        history[record.drama.key] = record;
      }
    }
    for (final reminder in backup.seasonReminders) {
      final existing = seasonReminders[reminder.anchor.key];
      if (existing == null || reminder.updatedAt.isAfter(existing.updatedAt)) {
        seasonReminders[reminder.anchor.key] = reminder;
        if (_lastReminderEnabledAt == null ||
            reminder.enabledAt.isAfter(_lastReminderEnabledAt!)) {
          _lastReminderEnabledAt = reminder.enabledAt;
        }
      }
    }
  }
}

bool isDeletedDramaSource(Object? source) =>
    source == 'wangguo' || source == 'faguo';

// Dropped sources are deliberately discarded; no historical identity migration.
void discardDeletedSources(Map<String, dynamic> state) {
  bool removed(Object? source) => isDeletedDramaSource(source);
  final records = state['records'] as Map? ?? state;
  for (final name in ['favorites', 'history']) {
    final list = records[name];
    if (list is List) {
      list.removeWhere(
        (row) =>
            removed(name == 'history' ? row['drama']['source'] : row['source']),
      );
    }
  }
  for (final name in [
    'catalogs',
    'selectedCategories',
    'sourceCategories',
    'pages',
    'hasMore',
  ]) {
    final values = state[name];
    if (values is Map) values.removeWhere((key, _) => removed(key));
  }
  for (final name in [
    'categorySlices',
    'episodes',
    'episodeUpdatedAt',
    'episodeSeenIds',
  ]) {
    final values = state[name];
    if (values is Map) {
      values.removeWhere(
        (key, _) => removed('$key'.split(RegExp(r'[:|]')).first),
      );
    }
  }
  if (removed(state['source'])) state['source'] = 'hongguo';
}
