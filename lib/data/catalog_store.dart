import 'dart:async';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/discovery.dart';
import '../domain/catalog_response.dart';
import '../domain/user_input_exception.dart';
import '../domain/series_title.dart';
import '../domain/catalog_query.dart';
import '../platform/provider_client.dart';
import 'record_store.dart';
import 'search_cache.dart';
import 'discovery_cache.dart';
import 'series_lookup.dart';
import 'store_persistence.dart';
import 'source_diagnostics.dart';

class _LibraryPrefetch {
  _LibraryPrefetch(this.source, this.category, this.page, this.id);
  final DramaSource source;
  final String category, id;
  final int page;
  final cancelled = Completer<void>();
}

class _LibraryPrefetchCancelled implements Exception {}

class _CatalogSlice {
  List<Drama> items = [];
  int page = 0;
  bool more = false, loading = false;
  String? error;
  bool? retryMore;
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
    required this.onSourceSelected,
    this.diagnostics,
  }) : _persistence = persistence;
  final StorePersistence _persistence;
  final ProviderClient provider;
  final SourceDiagnostics? diagnostics;
  final RecordStore records;
  final DateTime Function() now;
  final bool Function() isOffline;
  final void Function(DramaSource) onSourceSelected;
  bool _closed = false;
  _LibraryPrefetch? _libraryPrefetch;
  int _prefetchSerial = 0;
  DateTime _prefetchRetryAt = DateTime(2000);
  bool get libraryPrefetching => _libraryPrefetch != null;

  void cancelLibraryPrefetch() {
    final read = _libraryPrefetch;
    if (read == null) return;
    _libraryPrefetch = null;
    read.cancelled.complete();
    unawaited(
      provider
          .cancelCatalog(
            read.source,
            read.id,
            page: read.page,
            category: read.category,
          )
          .catchError((Object _) {}),
    );
  }

  Future<bool> prefetchLibrary({required bool Function() isActive}) async {
    if (_closed ||
        !source.remoteCategories ||
        isOffline() ||
        !isActive() ||
        _libraryPrefetch != null ||
        !libraryHasMore ||
        libraryLoading ||
        libraryCanRetry ||
        now().isBefore(_prefetchRetryAt)) {
      return false;
    }
    final target = source;
    final category = selectedCategory;
    final key = _sliceKey(target, category);
    final slice = _slices[key]!;
    final previousPage = slice.page;
    final read = _LibraryPrefetch(
      target,
      category,
      previousPage + 1,
      'catalog-${now().microsecondsSinceEpoch}-${++_prefetchSerial}',
    );
    _libraryPrefetch = read;
    bool current() =>
        !_closed &&
        identical(_libraryPrefetch, read) &&
        !isOffline() &&
        isActive() &&
        source == target &&
        selectedCategory == category &&
        identical(_slices[key], slice) &&
        slice.page == previousPage &&
        !libraryLoading &&
        !libraryCanRetry;
    try {
      final result = await Future.any([
        provider.catalogPage(
          target,
          category: category,
          page: read.page,
          requestId: read.id,
          background: true,
        ),
        read.cancelled.future.then<CatalogPage>(
          (_) => throw _LibraryPrefetchCancelled(),
        ),
      ]);
      if (!current()) return false;
      if (result.warning.isNotEmpty) {
        _prefetchRetryAt = now().add(const Duration(seconds: 30));
        return false;
      }
      slice.items = {
        for (final row in [...slice.items, ...result.items]) row.key: row,
      }.values.toList();
      slice.page = read.page;
      slice.more = result.hasMore;
      _mergeCatalog(target, result.items);
      await _saveCache();
      if (_closed) return false;
      notifyListeners();
      return true;
    } on _LibraryPrefetchCancelled {
      return false;
    } catch (_) {
      if (current()) _prefetchRetryAt = now().add(const Duration(seconds: 30));
      return false;
    } finally {
      if (identical(_libraryPrefetch, read)) _libraryPrefetch = null;
    }
  }

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
  late final discoveryCache = DiscoveryCache(
    now: now,
    onRead: (source, method) => diagnostics?.cached(source, method),
  );

  final Map<String, Future<CatalogSearchResult>> _searchRequests = {};

  int _searchSerial = 0;

  final Map<DramaSource, String> sourceErrors = {};
  final Map<DramaSource, bool> _retryCatalogMore = {};

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
      _slices[_sliceKey(
        source,
        source.remoteCategories ? selectedCategory : '',
      )];

  List<Drama> get library =>
      _activeSlice?.items ??
      (source.remoteCategories ? const [] : catalogs[source] ?? []);

  bool get libraryLoaded => (_activeSlice?.page ?? 0) > 0;

  bool get libraryLoading => source.remoteCategories
      ? _activeSlice?.loading == true
      : loadingSources.contains(source);

  bool get libraryHasMore => libraryLoaded && _activeSlice?.more == true;

  String? get libraryError =>
      source.remoteCategories ? _activeSlice?.error : sourceErrors[source];

  String? directoryNotice(DramaSource target) =>
      (target.remoteCategories
          ? _slices[_sliceKey(target, selectedCategories[target] ?? '')]?.error
          : sourceErrors[target]) ??
      categoryErrors[target];

  bool get libraryCanRetry => source.remoteCategories
      ? _activeSlice?.retryMore != null
      : _retryCatalogMore.containsKey(source);

  bool get categoriesLoading => _loadingCategories.contains(source);

  Future<void> retryLibrary() async {
    final target = source;
    if (target.remoteCategories) {
      final category = selectedCategory;
      final more = _activeSlice?.retryMore;
      if (more != null) await _loadCategory(target, category, more: more);
    } else {
      final more = _retryCatalogMore[target];
      if (more != null) await _loadCatalog(target, more: more);
    }
  }

  Future<void> loadCategories([DramaSource? selected]) async {
    final target = selected ?? source;
    if (_closed ||
        !target.remoteCategories ||
        isOffline() ||
        !_loadingCategories.add(target)) {
      return;
    }
    notifyListeners();
    try {
      final result = await provider.categories(target);
      if (_closed) return;
      sourceCategories[target] = result;
      categoryErrors.remove(target);
      await _saveCache();
    } catch (_) {
      if (!_closed) categoryErrors[target] = '分类暂时无法加载，请重试';
    } finally {
      _loadingCategories.remove(target);
      notifyListeners();
    }
  }

  Future<void> selectCategory(String category) async {
    cancelLibraryPrefetch();
    _prefetchRetryAt = DateTime(2000);
    final target = source;
    selectedCategories[target] = category;
    notifyListeners();
    final slice = _slices[_sliceKey(target, category)];
    if (slice == null || (slice.page == 0 && slice.retryMore == null)) {
      await _loadCategory(target, category, more: false);
    }
    await _persistence.persist(cache: false);
  }

  Future<void> _loadCategory(
    DramaSource target,
    String category, {
    required bool more,
  }) async {
    if (_closed || isOffline()) return;
    final slice = _slices.putIfAbsent(
      _sliceKey(target, category),
      _CatalogSlice.new,
    );
    if (slice.loading || (more && !slice.more)) return;
    slice.loading = true;
    slice.error = null;
    slice.retryMore = null;
    notifyListeners();
    try {
      final page = more ? slice.page + 1 : 1;
      final result = await provider.catalogPage(
        target,
        category: category,
        page: page,
      );
      if (_closed) return;
      final rows = result.items;
      slice.items = {
        for (final row in [...(more ? slice.items : <Drama>[]), ...rows])
          row.key: row,
      }.values.toList();
      slice.page = page;
      slice.more = result.hasMore;
      slice.error = result.warning.isEmpty ? null : result.warning;
      _mergeCatalog(target, rows);
      await _saveCache();
    } catch (_) {
      if (!_closed) {
        slice.retryMore = more;
        slice.error = more
            ? '更多短剧加载失败，请重试'
            : slice.items.isEmpty
            ? '剧库暂时无法加载，请稍后重试'
            : '剧库更新失败，已保留现有内容';
      }
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
              .map((v) => SourceCategory.fromJson(v as Map))
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
      discoveryCache.restore(state['discoveryCache']);
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
    'discoveryCache': discoveryCache.toJson(),
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
    if (_closed) return;
    cancelLibraryPrefetch();
    _prefetchRetryAt = DateTime(2000);
    source = next;
    onSourceSelected(next);
    notifyListeners();
    await _persistence.persist(cache: false);
  }

  Future<void> refresh([DramaSource? selected]) async {
    cancelLibraryPrefetch();
    final target = selected ?? source;
    if (target.remoteCategories) {
      await Future.wait([
        loadCategories(target),
        _loadCategory(target, selectedCategories[target] ?? '', more: false),
      ]);
      return;
    }
    await _loadCatalog(target, more: false);
  }

  Future<void> loadMore() async {
    cancelLibraryPrefetch();
    final target = source;
    if (target.remoteCategories) {
      await _loadCategory(target, selectedCategory, more: true);
      return;
    }
    await _loadCatalog(target, more: true);
  }

  Future<void> _loadCatalog(DramaSource target, {required bool more}) async {
    final key = _sliceKey(target, '');
    if (_closed ||
        isOffline() ||
        (more && ((_slices[key]?.page ?? 0) == 0 || hasMore[target] != true))) {
      return;
    }
    if (!loadingSources.add(target)) return;
    sourceErrors.remove(target);
    _retryCatalogMore.remove(target);
    notifyListeners();
    try {
      final page = more ? (catalogPages[target] ?? 1) + 1 : 1;
      final response = await provider.catalogPage(
        target,
        page: more ? page : null,
      );
      if (_closed) return;
      final rows = response.items;
      final slice = _slices.putIfAbsent(key, _CatalogSlice.new);
      slice.items = {
        if (more)
          for (final row in slice.items) row.key: row,
        for (final row in rows) row.key: row,
      }.values.toList();
      slice.page = page;
      slice.more = response.hasMore;
      _mergeCatalog(target, rows);
      catalogPages[target] = page;
      hasMore[target] = response.hasMore;
      if (response.warning.isNotEmpty) sourceErrors[target] = response.warning;
      await _saveCache();
    } catch (_) {
      if (!_closed) {
        _retryCatalogMore[target] = more;
        sourceErrors[target] = more
            ? '更多短剧加载失败，请重试'
            : (catalogs[target] ?? []).isEmpty
            ? '剧库暂时无法加载，请稍后重试'
            : '剧库更新失败，已保留现有内容';
      }
    } finally {
      loadingSources.remove(target);
      notifyListeners();
    }
  }

  Future<void> _saveCache() async {
    if (_closed) return;
    try {
      await _persistence.persist(records: false);
    } catch (_) {
      // AppStore reports storage failures separately. A successful response
      // has already advanced the cursor and must not become a request retry.
    }
  }

  Future<List<Drama>> search(DramaSource target, String query) async =>
      (await searchCatalog(target, query)).items;

  Future<CatalogSearchResult> searchCatalog(
    DramaSource target,
    String query, {
    int page = 1,
    String? continuation,
    String? requestId,
    ValueChanged<CatalogSearchResult>? onPartial,
    bool rememberQuery = true,
    bool refresh = false,
    bool Function()? isActive,
  }) async {
    query = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) return CatalogSearchResult(catalogs[target] ?? []);
    final key = '${target.name}|$query|$page|${continuation ?? ''}';
    final cached = continuation == null || continuation.isEmpty
        ? searchCache.read('${target.name}|$query|$page', now())
        : null;
    if (cached != null && !refresh) {
      onPartial?.call(cached.cachedResult);
      if (cached.fresh || isOffline()) {
        diagnostics?.cached(target, 'search', page: page);
        if (rememberQuery) await rememberSearch(query);
        return cached.cachedResult;
      }
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
      continuation,
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

  Future<CatalogSearchResult> _searchCatalog(
    DramaSource target,
    String query,
    int page,
    String? continuation,
    String id,
    ValueChanged<CatalogSearchResult>? onPartial,
    bool rememberQuery,
    bool Function()? isActive,
  ) async {
    Timer? timer;
    bool polling = false, completed = false;
    if (target == DramaSource.hongguo && onPartial != null) {
      timer = Timer.periodic(const Duration(milliseconds: 700), (_) async {
        if (isActive?.call() == false) {
          timer?.cancel();
          return;
        }
        if (polling || completed) return;
        polling = true;
        try {
          final partial = await provider.searchProgress(
            target,
            query,
            page: page,
            requestId: id,
          );
          if (!completed && isActive?.call() != false && partial != null) {
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
      final result = await provider.searchPage(
        target,
        query,
        page: page,
        requestId: id,
        continuation: continuation,
      );
      completed = true;
      if (isActive?.call() == false) throw const SeriesLookupCancelled();
      if ((continuation == null || continuation.isEmpty) &&
          !result.restartRequired) {
        searchCache.put('${target.name}|$query|$page', result, now());
      }
      if (rememberQuery) {
        recentSearches.remove(query);
        recentSearches.insert(0, query);
        if (recentSearches.length > 10) recentSearches.removeLast();
      }
      _mergeCatalog(target, result.items);
      try {
        await _persistence.persist();
      } catch (_) {
        // AppStore reports saving failures independently of valid results.
      }
      if (isActive?.call() == false) throw const SeriesLookupCancelled();
      if (_closed) return result;
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
      await provider.cancelSearch(
        target,
        query.trim().replaceAll(RegExp(r'\s+'), ' '),
        id,
      );
    } catch (_) {
      /* Cancellation is best effort on detached platforms. */
    }
  }

  Future<void> saveRecommendations(List<Drama> incoming) async {
    if (_closed) return;
    _mergeCatalog(DramaSource.hongguo, incoming);
    await _saveCache();
    if (!_closed) notifyListeners();
  }

  Future<void> saveRecommendationColumn(
    RecommendationGenre genre,
    List<Drama> rows,
    DateTime savedAt,
  ) async {
    if (_closed) return;
    discoveryCache.putRecommendations(genre, rows, savedAt);
    await saveRecommendations(rows);
  }

  Future<void> saveRankingColumn(
    DramaSource source,
    String board,
    CachedDiscoveryColumn column,
  ) async {
    if (_closed) return;
    discoveryCache.putRanking(source, board, column);
    await _saveCache();
  }

  Future<void> saveDiscoveryBoards(
    DramaSource source,
    List<DiscoveryBoard> boards,
  ) async {
    if (_closed) return;
    discoveryCache.putBoards(source, boards, now());
    await _saveCache();
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
      String? continuation;
      for (var page = 1; page <= 3; page++) {
        if (!active) throw const SeriesLookupCancelled();
        requestId = 'series-${++_searchSerial}-${now().microsecondsSinceEpoch}';
        result = await searchCatalog(
          anchor.source,
          info.baseTitle,
          page: page,
          continuation: continuation,
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
        continuation = result.continuation;
        if (!result.hasMore ||
            result.warning.isNotEmpty ||
            (result.limited && continuation.isEmpty)) {
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

  Future<void> rememberSearch(String query) async {
    query = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (_closed || query.isEmpty) return;
    recentSearches.remove(query);
    recentSearches.insert(0, query);
    if (recentSearches.length > 10) recentSearches.removeLast();
    notifyListeners();
    try {
      await _persistence.persist(cache: false);
    } catch (_) {
      // Saving a recent query cannot make available search results unusable.
    }
  }

  List<Drama> cachedDramas(DramaSource target) {
    final rows = <String, Drama>{};
    for (final drama in [
      ...catalogs[target] ?? [],
      ...searchCache.dramas,
      ...discoveryCache.dramas,
      ...records.favorites.values,
      ...records.history.values.map((record) => record.drama),
      ...records.seasonReminders.values.expand(
        (reminder) => [
          reminder.anchor,
          ...reminder.seasons.values.map((notice) => notice.drama),
        ],
      ),
    ]) {
      if (drama.source == target) rows.putIfAbsent(drama.key, () => drama);
    }
    return List.unmodifiable(rows.values);
  }

  Future<List<String>> suggestions(String query) async {
    if (isOffline() || query.trim().isEmpty) return [];
    return (await provider.suggestions(query.trim())).take(10).toList();
  }

  Drama currentDrama(Drama drama) =>
      (catalogs[drama.source] ?? [])
          .where((d) => d.source == drama.source && d.id == drama.id)
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
      final patch = await provider.dramaDetail(drama);
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
      diagnostics?.cached(drama.source, 'chapters');
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
    final installedSlices = <String, List<Drama>>{};
    final grouped = <DramaSource, List<Drama>>{};
    var imported = 0, mergedCount = 0;
    for (final row in rows) {
      if (row.id.isEmpty || row.title.isEmpty) {
        throw const UserInputException('剧库包含无效条目');
      }
      grouped.putIfAbsent(row.source, () => []).add(row);
    }
    for (final entry in grouped.entries) {
      final importedKeys = <String>{};
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
        importedKeys.add(row.key);
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
      final key = _sliceKey(entry.key, '');
      previousSlices[key] = _slices[key]?.items;
      final slice = _slices.putIfAbsent(key, _CatalogSlice.new);
      slice.items = {
        for (final row in slice.items) row.key: merged[row.key] ?? row,
        for (final key in importedKeys) key: merged[key]!,
      }.values.toList();
      installedSlices[key] = slice.items;
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
          if (identical(slice.items, installedSlices[key]) &&
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
    cancelLibraryPrefetch();
    cancelSeriesLookups();
    super.dispose();
  }
}
