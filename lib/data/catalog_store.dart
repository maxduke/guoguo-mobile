import 'dart:async';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/series_title.dart';
import '../domain/catalog_query.dart';
import '../platform/provider_client.dart';
import 'record_store.dart';
import 'search_cache.dart';
import 'series_lookup.dart';
import 'store_persistence.dart';

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

class CatalogStore extends ChangeNotifier {
  CatalogStore({
    required StorePersistence persistence,
    required this.provider,
    required this.records,
    required this.now,
    required this.isOffline,
  }) : _persistence = persistence;
  final StorePersistence _persistence;
  final ProviderClient provider;
  final RecordStore records;
  final DateTime Function() now;
  final bool Function() isOffline;
  bool _closed = false;

  static const episodeFreshness = Duration(hours: 6);

  final Map<String, DateTime> episodeUpdatedAt = {};

  final Map<String, Future<List<Episode>>> _episodeRequests = {};

  final Map<String, String> episodeErrors = {};

  bool hideVip = true;

  final List<String> recentSearches = [];

  final Map<String, Future<Drama>> _detailRequests = {};

  final Map<String, DateTime> _detailChecked = {};

  final Map<String, Drama> details = {};

  final Map<String, String> detailErrors = {};

  final Map<DramaSource, List<Drama>> catalogs = {};

  final Map<String, List<Episode>> episodeCache = {};

  final Set<SeriesLookup> _seriesLookups = {};

  final searchCache = SearchCache();

  final Map<String, Future<CatalogSearchResult>> _searchRequests = {};

  int _searchSerial = 0;

  final Map<DramaSource, String> sourceErrors = {};

  final Set<DramaSource> loadingSources = {};

  final Map<DramaSource, int> catalogPages = {};

  final Map<DramaSource, bool> hasMore = {};

  DramaSource source = DramaSource.hongguo;

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
        isOffline() ||
        !_loadingCategories.add(target)) {
      return;
    }
    try {
      final result = await provider.call('categories', {'source': target.name});
      if (_closed) return;
      sourceCategories[target] = (result['items'] as List)
          .map((v) => SourceCategory(v['id'] as String, v['name'] as String))
          .toList();
      categoryErrors.remove(target);
      await _persistence.persist(records: false);
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
    await _persistence.persist(cache: false);
  }

  Future<void> _loadCategory(
    DramaSource target,
    String category, {
    required bool more,
  }) async {
    if (isOffline()) return;
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
      if (_closed) return;
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
      await _persistence.persist(records: false);
    } catch (error) {
      slice.error = '$error';
    } finally {
      slice.loading = false;
      notifyListeners();
    }
  }

  String? restoreCache(Map<String, dynamic> state) {
    try {
      // Validate all reconstructible data before installing it. Damaged cache
      // must not stop the app from opening its durable records and settings.
      final loadedCatalogs = <DramaSource, List<Drama>>{
        for (final entry in (state['catalogs'] as Map? ?? {}).entries)
          DramaSource.parse(entry.key): (entry.value as List)
              .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
              .toList(),
      };
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
      final loadedCategories = <DramaSource, List<SourceCategory>>{
        for (final entry in (state['sourceCategories'] as Map? ?? {}).entries)
          DramaSource.parse(entry.key): (entry.value as List)
              .map(
                (v) => SourceCategory(v['id'] as String, v['name'] as String),
              )
              .toList(),
      };
      final loadedPages = <DramaSource, int>{
        for (final entry in (state['pages'] as Map? ?? {}).entries)
          DramaSource.parse(entry.key): entry.value as int,
      };
      final loadedMore = <DramaSource, bool>{
        for (final entry in (state['hasMore'] as Map? ?? {}).entries)
          DramaSource.parse(entry.key): entry.value == true,
      };
      final loadedTimes = <String, DateTime>{};
      for (final entry in (state['episodeUpdatedAt'] as Map? ?? {}).entries) {
        final date = DateTime.tryParse('${entry.value}');
        if (date != null) loadedTimes[entry.key as String] = date;
      }
      final searches = state['searchCache'] as Map? ?? {};
      catalogs.addAll(loadedCatalogs);
      episodeCache.addAll(loadedEpisodes);
      _slices.addAll(loadedSlices);
      sourceCategories.addAll(loadedCategories);
      catalogPages.addAll(loadedPages);
      hasMore.addAll(loadedMore);
      episodeUpdatedAt.addAll(loadedTimes);
      searchCache.restore(searches);
    } catch (_) {
      return '目录缓存无法读取，可联网重新加载';
    }
    return null;
  }

  Map<String, dynamic> cacheSnapshot() => {
    'sourceCategories': {
      for (final entry in sourceCategories.entries)
        entry.key.name: entry.value
            .map((v) => {'id': v.id, 'name': v.name})
            .toList(),
    },
    'categorySlices': {
      for (final entry in _slices.entries) entry.key: entry.value.toJson(),
    },
    'pages': {
      for (final entry in catalogPages.entries) entry.key.name: entry.value,
    },
    'hasMore': {
      for (final entry in hasMore.entries) entry.key.name: entry.value,
    },
    'searchCache': searchCache.toJson(),
    'catalogs': {
      for (final entry in catalogs.entries)
        entry.key.name: entry.value.map((v) => v.toJson()).toList(),
    },
    'episodeUpdatedAt': {
      for (final entry in episodeUpdatedAt.entries)
        entry.key: entry.value.toIso8601String(),
    },
    'episodes': {
      for (final entry in episodeCache.entries)
        entry.key: entry.value.map((v) => v.raw).toList(),
    },
  };

  Future<void> selectSource(DramaSource next) async {
    source = next;
    notifyListeners();
    await _persistence.persist(cache: false);
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
      if (_closed) return;
      final incoming = _parseRows(response, target);
      _mergeCatalog(target, incoming);
      catalogPages[target] = 1;
      hasMore[target] = response['hasMore'] == true;
      final warning = response['warning'] as String? ?? '';
      if (warning.isNotEmpty) sourceErrors[target] = warning;
      await _persistence.persist(records: false);
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
    if (isOffline() || hasMore[target] != true) return;
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
      await _persistence.persist(records: false);
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
      if (cached.fresh || isOffline()) return cached.result;
    }
    if (isOffline()) throw const ProviderException('当前离线，可继续搜索已缓存的短剧');
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
      await _persistence.persist();
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
    await _persistence.persist(records: false);
    notifyListeners();
  }

  List<Drama> relatedTo(Drama anchor, {int limit = 200}) =>
      relatedSeries(anchor, [
        ...catalogs.values.expand((rows) => rows),
        ...searchCache.dramas,
        ...records.favorites.values,
        ...records.history.values.map((r) => r.drama),
        ...records.seasonReminders.values.expand(
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
      if (isOffline()) {
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

  Future<void> setHideVip(bool value) async {
    hideVip = value;
    notifyListeners();
    await _persistence.persist(cache: false);
  }

  Future<void> clearSearches() async {
    recentSearches.clear();
    notifyListeners();
    await _persistence.persist(cache: false);
  }

  Future<List<String>> suggestions(String query) async {
    if (isOffline() || query.trim().isEmpty) return [];
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
      records.favorites[drama.key] ??
      drama;

  Future<Drama> refreshDetail(Drama drama, {bool force = false}) async {
    final current = currentDrama(drama);
    if (isOffline()) return current;
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
      await records.updateDrama(updated);
      _detailChecked[drama.key] = now();
      detailErrors.remove(drama.key);
      await _persistence.persist(records: false);
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

  Future<List<Episode>> episodes(Drama drama, {bool refresh = false}) async {
    if (isOffline() && refresh) throw const ProviderException('离线时无法刷新分集');
    final cached = episodeCache[drama.key];
    final updated = episodeUpdatedAt[drama.key];
    if (cached != null &&
        cached.isNotEmpty &&
        (isOffline() ||
            (!refresh &&
                updated != null &&
                now().difference(updated) >= Duration.zero &&
                now().difference(updated) < episodeFreshness))) {
      return cached;
    }
    if (isOffline()) throw const ProviderException('离线时没有可用的分集缓存');
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
      episodeCache[drama.key] = unique;
      episodeUpdatedAt[drama.key] = now();
      episodeErrors.remove(drama.key);
      await records.episodesUpdated(drama, cached ?? unique);
      await _persistence.persist(records: false);
      notifyListeners();
      return unique;
    } catch (_) {
      episodeErrors[drama.key] = '分集更新失败，保留上次缓存';
      notifyListeners();
      rethrow;
    }
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
      await _persistence.persist(records: false);
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

  Map<String, dynamic> settingsSnapshot() => {
    'source': source.name,
    'hideVip': hideVip,
    'recentSearches': List<String>.of(recentSearches),
    'selectedCategories': {
      for (final entry in selectedCategories.entries)
        entry.key.name: entry.value,
    },
  };

  void restoreSettings({
    required DramaSource selected,
    required Map<DramaSource, String> categories,
    required bool hideVip,
    required List<String> searches,
  }) {
    source = selected;
    selectedCategories.addAll(categories);
    this.hideVip = hideVip;
    recentSearches.addAll(searches);
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_closed) super.notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    cancelSeriesLookups();
    super.dispose();
  }
}
