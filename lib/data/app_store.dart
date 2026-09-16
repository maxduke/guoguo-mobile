import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/playback_diagnostic.dart';
import '../platform/provider_client.dart';
import 'storage.dart';

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
  final List<PlaybackDiagnostic> playbackDiagnostics = [];
  static const maxPlaybackDiagnostics = 30;
  final LocalStorage storage;
  final ProviderClient provider;
  final Map<DramaSource, List<Drama>> catalogs = {};
  final Map<String, List<Episode>> episodeCache = {};
  final Map<String, Drama> favorites = {};
  final Map<String, WatchRecord> history = {};
  final Map<DramaSource, String> sourceErrors = {};
  final Set<DramaSource> loadingSources = {};
  final Map<DramaSource, int> catalogPages = {};
  final Map<DramaSource, bool> hasMore = {};
  DramaSource source = DramaSource.hongguo;
  ThemeMode themeMode = ThemeMode.system;
  bool cellularDownloads = false, cellularPrefetch = false, prefetch = true;
  bool offline = false;
  String? persistenceError;
  List<Drama> get library => catalogs[source] ?? [];
  List<WatchRecord> get recent =>
      history.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  Future<void> load() async {
    final state = await storage.read();
    if (state == null) return;
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
    source = DramaSource.parse(state['source'] ?? 'hongguo');
    themeMode = ThemeMode.values.firstWhere(
      (v) => v.name == state['theme'],
      orElse: () => ThemeMode.system,
    );
    cellularDownloads = state['cellularDownloads'] == true;
    cellularPrefetch = state['cellularPrefetch'] == true;
    prefetch = state['prefetch'] != false;
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
    'records': RecordBackup(
      favorites.values.toList(),
      history.values.toList(),
    ).toJson(),
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

  void setOffline(bool value) {
    if (offline != value) {
      offline = value;
      notifyListeners();
    }
  }

  Future<void> refresh([DramaSource? selected]) async {
    final target = selected ?? source;
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

  Future<List<Drama>> search(DramaSource target, String query) async {
    if (query.trim().isEmpty) return catalogs[target] ?? [];
    final response = await provider.call('search', {
      'source': target.name,
      'query': query.trim(),
    });
    final incoming = _parseRows(response, target);
    _mergeCatalog(target, incoming);
    await persist();
    notifyListeners();
    return incoming;
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

  void _mergeCatalog(DramaSource target, List<Drama> incoming) {
    final merged = {
      for (final row in catalogs[target] ?? <Drama>[]) row.key: row,
    };
    for (final row in incoming) {
      merged[row.key] = row;
    }
    catalogs[target] = merged.values.toList();
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

  Future<void> checkFavoriteUpdates() async {
    if (checkingUpdates) return;
    if (offline) throw const ProviderException('请联网后检查更新');
    checkingUpdates = true;
    notifyListeners();
    var failures = 0;
    try {
      for (final drama in favorites.values.toList()) {
        try {
          await episodes(drama, refresh: true);
        } catch (_) {
          failures++;
        }
      }
    } finally {
      checkingUpdates = false;
      notifyListeners();
    }
    if (failures > 0) throw ProviderException('$failures 部剧更新失败，已保留原有分集');
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
    notifyListeners();
    await persist();
  }

  Future<void> removeHistory(String key) async {
    history.remove(key);
    notifyListeners();
    await persist();
  }

  String exportBackup() => const JsonEncoder.withIndent('  ').convert(
    RecordBackup(favorites.values.toList(), history.values.toList()).toJson(),
  );
  RecordBackup inspectBackup(String raw) {
    if (utf8.encode(raw).length > 20 * 1024 * 1024) {
      throw const FormatException('备份文件超过 20 MB');
    }
    try {
      return RecordBackup.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      throw const FormatException('备份损坏或格式不兼容，原记录未修改');
    }
  }

  Future<void> importBackup(RecordBackup backup) async {
    final oldFavorites = Map<String, Drama>.of(favorites);
    final oldHistory = Map<String, WatchRecord>.of(history);
    _merge(backup);
    try {
      await persist();
    } catch (_) {
      favorites
        ..clear()
        ..addAll(oldFavorites);
      history
        ..clear()
        ..addAll(oldHistory);
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
  }
}
