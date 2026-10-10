import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/playback_diagnostic.dart';
import '../platform/provider_client.dart';
import '../platform/observed_provider_client.dart';
import 'source_diagnostics.dart';
import 'catalog_store.dart';
import 'preferences_store.dart';
import 'record_store.dart';
import 'storage.dart';
import 'store_persistence.dart';
export 'catalog_store.dart' show CatalogStore;
export '../domain/catalog_response.dart'
    show CatalogSearchResult, SourceCategory;

class AppStore extends ChangeNotifier implements StorePersistence {
  AppStore({
    required this.storage,
    required ProviderClient provider,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    sourceDiagnostics = SourceDiagnostics(now: this.now);
    this.provider = ObservedProviderClient(provider, sourceDiagnostics);
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
      provider: this.provider,
      diagnostics: sourceDiagnostics,
      records: records,
      now: this.now,
      isOffline: () => offline,
      onSourceSelected: preferences.rememberSource,
    );
  }
  final LocalStorage storage;
  late final ProviderClient provider;
  late final SourceDiagnostics sourceDiagnostics;
  final DateTime Function() now;
  late final PreferencesStore preferences;
  late final RecordStore records;
  late final CatalogStore catalog;
  bool offline = false;
  bool wifi = false;
  @override
  String? persistenceError;
  String? cachePersistenceError;
  bool _hasRecordState = false, _closed = false;
  Future<void> _recordQueue = Future.value();
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

  Map<String, dynamic> _recordSnapshot({
    bool reuseHistory = true,
    RecordBackup? candidate,
  }) => {
    'version': 1,
    ...preferences.toJson(),
    ...catalog.settingsSnapshot(),
    'playbackDiagnostics': playbackDiagnostics.map((d) => d.toJson()).toList(),
    'records':
        candidate?.toJson() ?? records.snapshot(reuseHistory: reuseHistory),
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
  Future<T> updateRecords<T>(Future<T> Function(SaveRecords save) operation) {
    if (_closed) return Future.error(StateError('记录存储已关闭'));
    final next = _recordQueue.then((_) => operation(_writeRecords));
    _recordQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _writeRecords({RecordBackup? candidate}) async {
    try {
      final snapshot = _recordSnapshot(candidate: candidate);
      final target = storage;
      if (target is PartitionedStorage) {
        await target.writeRecords(snapshot);
      } else {
        await target.write({...snapshot, ...catalog.cacheSnapshot()});
      }
      final recovered = persistenceError != null;
      persistenceError = null;
      _hasRecordState = true;
      if (recovered && !_closed) notifyListeners();
    } catch (_) {
      persistenceError = '记录暂未保存，请检查可用空间后重试';
      if (!_closed) notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> persist({bool records = true, bool cache = true}) async {
    if (_closed) throw StateError('记录存储已关闭');
    Future<void> saveCache(Future<void> operation) async {
      try {
        await operation;
        final recovered = cachePersistenceError != null;
        cachePersistenceError = null;
        if (recovered && !_closed) notifyListeners();
      } catch (_) {
        cachePersistenceError = '目录缓存暂未保存，请检查可用空间后重试';
        if (!_closed) notifyListeners();
        // Cache failure cannot undo already committed durable records.
        if (!records) rethrow;
      }
    }

    final target = storage;
    if (target is PartitionedStorage) {
      await Future.wait([
        if (records || !_hasRecordState)
          updateRecords((save) async {
            // Snapshot only after the preceding record transaction finishes.
            if (records || !_hasRecordState) await save();
          }),
        if (cache)
          saveCache(
            target is AppFileStorage
                ? target.writeCacheSnapshot(catalog.cacheSnapshot)
                : target.writeCache(catalog.cacheSnapshot()),
          ),
      ]);
    } else {
      await updateRecords((save) => save());
    }
  }

  Future<void> clearCatalogCache() async {
    if (_closed) throw StateError('记录存储已关闭');
    final target = storage;
    if (target is! AppFileStorage) throw StateError('目录缓存清理不可用');
    await target.clearCatalogCache();
    cachePersistenceError = null;
    if (!_closed) notifyListeners();
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
      if (value) wifi = false;
      notifyListeners();
    }
  }

  void setWifi(bool value) {
    if (wifi == value) return;
    wifi = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    records.dispose();
    catalog.dispose();
    preferences.dispose();
    sourceDiagnostics.dispose();
    super.dispose();
  }
}
