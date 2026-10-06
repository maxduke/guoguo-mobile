import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/playback_diagnostic.dart';
import '../platform/provider_client.dart';
import 'catalog_store.dart';
import 'preferences_store.dart';
import 'record_store.dart';
import 'storage.dart';
import 'store_persistence.dart';
export 'catalog_store.dart' show CatalogStore, SourceCategory;
export 'search_cache.dart' show CatalogSearchResult;

class AppStore extends ChangeNotifier implements StorePersistence {
  AppStore({
    required this.storage,
    required this.provider,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    preferences = PreferencesStore(save: () => persist(cache: false));
    records = RecordStore(
      persistence: this,
      now: this.now,
      isOffline: () => offline,
      loadEpisodes: (drama, {refresh = false}) =>
          catalog.episodes(drama, refresh: refresh),
      cachedEpisodes: (drama) => catalog.episodeCache[drama.key],
      lookupSeries: (drama, {refresh = false}) =>
          catalog.lookupSeries(drama, refresh: refresh),
    );
    catalog = CatalogStore(
      persistence: this,
      provider: provider,
      records: records,
      now: this.now,
      isOffline: () => offline,
    );
  }
  final LocalStorage storage;
  final ProviderClient provider;
  final DateTime Function() now;
  late final PreferencesStore preferences;
  late final RecordStore records;
  late final CatalogStore catalog;
  bool offline = false;
  @override
  String? persistenceError;
  String? cachePersistenceError;
  bool _hasRecordState = false, _closed = false;
  final List<PlaybackDiagnostic> playbackDiagnostics = [];
  static const maxPlaybackDiagnostics = 30;

  Future<void> load() async {
    final state = await storage.read();
    if (state == null) return;
    if (state['version'] != 1) throw const FormatException('本地数据版本不受支持，已保留原文件');
    final backup = RecordBackup.fromJson(
      Map<String, dynamic>.from(state['records'] as Map),
    );
    final selections = <DramaSource, String>{
      for (final entry in (state['selectedCategories'] as Map? ?? {}).entries)
        DramaSource.parse(entry.key): entry.value as String,
    };
    final source = DramaSource.parse(state['source'] ?? 'hongguo');
    final searches = (state['recentSearches'] as List? ?? [])
        .cast<String>()
        .take(10)
        .toList();
    final seen = <String, Set<String>>{
      for (final entry in (state['episodeSeenIds'] as Map? ?? {}).entries)
        entry.key as String: Set<String>.from(entry.value as List),
    };
    preferences.restore(state);
    for (final raw in (state['playbackDiagnostics'] as List? ?? []).take(
      maxPlaybackDiagnostics,
    )) {
      try {
        playbackDiagnostics.add(
          PlaybackDiagnostic.fromJson(Map<String, dynamic>.from(raw as Map)),
        );
      } catch (_) {
        // Damaged diagnostic samples do not block records.
      }
    }
    cachePersistenceError = storage is PartitionedStorage
        ? (storage as PartitionedStorage).cacheReadError
        : null;
    cachePersistenceError =
        catalog.restoreCache(state) ?? cachePersistenceError;
    catalog.restoreSettings(
      selected: source,
      categories: selections,
      hideVip: state['hideVip'] != false,
      searches: searches,
    );
    records.restore(backup, seen);
    _hasRecordState = true;
    notifyListeners();
  }

  Map<String, dynamic> _recordSnapshot({bool reuseHistory = true}) => {
    'version': 1,
    ...preferences.toJson(),
    ...catalog.settingsSnapshot(),
    'playbackDiagnostics': playbackDiagnostics.map((d) => d.toJson()).toList(),
    'records': records.snapshot(reuseHistory: reuseHistory),
    'episodeSeenIds': {
      for (final entry in records.episodeSeenIds.entries)
        entry.key: entry.value.toList(),
    },
  };

  Map<String, dynamic> snapshot() => {
    ..._recordSnapshot(reuseHistory: false),
    ...catalog.cacheSnapshot(),
  };

  @override
  Future<void> persist({bool records = true, bool cache = true}) async {
    Future<void> saveRecords(Future<void> operation) async {
      try {
        await operation;
        final recovered = persistenceError != null;
        persistenceError = null;
        if (recovered && !_closed) notifyListeners();
        _hasRecordState = true;
      } catch (_) {
        persistenceError = '记录暂未保存，请检查可用空间后重试';
        if (!_closed) notifyListeners();
        rethrow;
      }
    }

    Future<void> saveCache(Future<void> operation) async {
      try {
        await operation;
        final recovered = cachePersistenceError != null;
        cachePersistenceError = null;
        if (recovered && !_closed) notifyListeners();
      } catch (_) {
        cachePersistenceError = '目录缓存暂未保存，请检查可用空间后重试';
        if (!_closed) notifyListeners();
        // Mixed operations may already have committed their durable state.
        // A cache failure must not roll back a successfully saved reminder.
        if (!records) rethrow;
      }
    }

    final target = storage;
    if (target is PartitionedStorage) {
      // Queue both snapshots at invocation so overlapping operations preserve
      // order within each file. Neither queue blocks the other file.
      await Future.wait([
        if (records || !_hasRecordState)
          saveRecords(target.writeRecords(_recordSnapshot())),
        if (cache) saveCache(target.writeCache(catalog.cacheSnapshot())),
      ]);
    } else {
      await saveRecords(target.write(snapshot()));
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
    await persist(cache: false);
  }

  Future<void> clearPlaybackDiagnostics() async {
    playbackDiagnostics.clear();
    await persist(cache: false);
    notifyListeners();
  }

  void setOffline(bool value) {
    if (offline != value) {
      offline = value;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    records.dispose();
    catalog.dispose();
    preferences.dispose();
    super.dispose();
  }
}
