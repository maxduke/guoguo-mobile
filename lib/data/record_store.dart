import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/catalog_query.dart';
import '../domain/series_title.dart';
import '../platform/provider_client.dart';
import 'search_cache.dart';
import 'series_lookup.dart';
import 'store_persistence.dart';

class RecordStore extends ChangeNotifier {
  RecordStore({
    required StorePersistence persistence,
    required this.now,
    required this.isOffline,
    required Future<List<Episode>> Function(Drama, {bool refresh}) loadEpisodes,
    required List<Episode>? Function(Drama) cachedEpisodes,
    required SeriesLookup Function(Drama, {bool refresh}) lookupSeries,
  }) : _persistence = persistence,
       _loadEpisodes = loadEpisodes,
       _cachedEpisodes = cachedEpisodes,
       _lookupSeries = lookupSeries;
  final StorePersistence _persistence;
  final DateTime Function() now;
  final bool Function() isOffline;
  final Future<List<Episode>> Function(Drama, {bool refresh}) _loadEpisodes;
  final List<Episode>? Function(Drama) _cachedEpisodes;
  final SeriesLookup Function(Drama, {bool refresh}) _lookupSeries;
  final progress = ChangeNotifier();
  bool _closed = false;

  final Map<String, Set<String>> episodeSeenIds = {};

  bool checkingUpdates = false;

  int _updateGeneration = 0;

  SeriesLookup? _updateLookup;

  final Map<String, Drama> favorites = {};

  final Map<String, WatchRecord> history = {};

  final Map<String, SeasonReminder> seasonReminders = {};

  DateTime? _lastReminderEnabledAt;

  final _historyJson = <String, (WatchRecord, Map<String, dynamic>)>{};

  List<WatchRecord> get recent =>
      history.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<Map<String, dynamic>> _historyRows() {
    _historyJson.removeWhere((key, _) => !history.containsKey(key));
    return [
      for (final entry in history.entries)
        (_historyJson[entry.key] =
                identical(_historyJson[entry.key]?.$1, entry.value)
                ? _historyJson[entry.key]!
                : (entry.value, entry.value.toJson()))
            .$2,
    ];
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
      await _persistence.persist(cache: false);
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
      await _persistence.persist(cache: false);
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
      await _persistence.persist(cache: false);
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

  int newEpisodeCount(Drama drama) {
    final seen = episodeSeenIds[drama.key];
    if (seen == null) return 0;
    return (_cachedEpisodes(drama) ?? [])
        .where((e) => !seen.contains(e.id))
        .length;
  }

  Future<void> markEpisodesSeen(Drama drama, List<Episode> rows) async {
    episodeSeenIds[drama.key] = rows.map((e) => e.id).toSet();
    await _persistence.persist(cache: false);
    notifyListeners();
  }

  Future<bool> checkFavoriteUpdates() async {
    if (checkingUpdates) return false;
    if (isOffline()) throw const ProviderException('请联网后检查更新');
    checkingUpdates = true;
    final generation = ++_updateGeneration;
    notifyListeners();
    var failures = 0;
    try {
      for (final drama in favorites.values.toList()) {
        if (generation != _updateGeneration) break;
        try {
          await _loadEpisodes(drama, refresh: true);
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
            _updateLookup = _lookupSeries(reminder.anchor, refresh: true);
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
    await _persistence.persist(cache: false);
  }

  Future<void> saveWatch(WatchRecord record) async {
    final previous = history[record.drama.key];
    if (previous != null &&
        _persistence.persistenceError == null &&
        previous.episodeId == record.episodeId &&
        previous.episodeIndex == record.episodeIndex &&
        previous.positionMs == record.positionMs &&
        previous.durationMs == record.durationMs &&
        listEquals(previous.drama.tags, record.drama.tags) &&
        mapEquals(
          {...previous.drama.toJson(), 'tags': null},
          {...record.drama.toJson(), 'tags': null},
        )) {
      return;
    }
    history[record.drama.key] = record;
    progress.notifyListeners();
    await _persistence.persist(cache: false);
  }

  Future<void> removeHistory(String key) async {
    history.remove(key);
    notifyListeners();
    await _persistence.persist(cache: false);
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
    mergeBackup(backup);
    final installedReminders = Map<String, SeasonReminder>.of(seasonReminders);
    try {
      await _persistence.persist(cache: false);
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

  void mergeBackup(RecordBackup backup) {
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

  Map<String, dynamic> snapshot({bool reuseHistory = false}) => RecordBackup(
    favorites.values.toList(),
    history.values.toList(),
    seasonReminders: seasonReminders.values.toList(),
  ).toJson(historyRows: reuseHistory ? _historyRows() : null);

  void restore(RecordBackup backup, Map<String, Set<String>> seen) {
    episodeSeenIds.addAll(seen);
    mergeBackup(backup);
    notifyListeners();
  }

  void updateDrama(Drama updated) {
    final key = updated.key;
    var changed = false;
    if (favorites.containsKey(key)) {
      favorites[key] = updated;
      changed = true;
    }
    final record = history[key];
    if (record != null) {
      history[key] = WatchRecord(
        drama: updated,
        episodeId: record.episodeId,
        episodeIndex: record.episodeIndex,
        positionMs: record.positionMs,
        durationMs: record.durationMs,
        updatedAt: record.updatedAt,
      );
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void episodesUpdated(Drama drama, List<Episode> baseline) {
    episodeSeenIds.putIfAbsent(
      drama.key,
      () => baseline.map((e) => e.id).toSet(),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    cancelUpdateChecks();
    progress.dispose();
    super.dispose();
  }
}
