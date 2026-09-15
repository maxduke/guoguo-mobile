import 'dart:convert';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../platform/provider_client.dart';
import 'storage.dart';

class AppStore extends ChangeNotifier {
  AppStore({required this.storage, required this.provider});
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
      sourceErrors.remove(target);
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

  Future<List<Episode>> episodes(Drama drama, {bool refresh = false}) async {
    if (!refresh && episodeCache.containsKey(drama.key)) {
      return episodeCache[drama.key]!;
    }
    final rows = await provider.chapters(drama);
    if (rows.isEmpty) throw const ProviderException('暂未找到可播放分集');
    episodeCache[drama.key] = rows;
    await persist();
    return rows;
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
