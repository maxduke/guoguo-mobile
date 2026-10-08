import 'dart:convert';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/user_input_exception.dart';
import '../domain/watch_resume.dart';
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
  bool _closed = false, _started = false;
  late final Map<String, Drama> favorites = UnmodifiableMapView(_favorites);
  late final Map<String, WatchRecord> history = UnmodifiableMapView(_history);
  late final Map<String, SeasonReminder> seasonReminders = UnmodifiableMapView(
    _seasonReminders,
  );
  late final Map<String, Set<String>> episodeSeenIds = UnmodifiableMapView(
    _episodeSeenIds,
  );

  Future<void> _change(Future<void> Function(SaveRecords save) operation) {
    if (_closed) return Future.error(StateError('记录存储已关闭'));
    _started = true;
    return _persistence.updateRecords(operation);
  }

  @override
  void notifyListeners() {
    if (!_closed) super.notifyListeners();
  }

  final Map<String, Set<String>> _episodeSeenIds = {};

  bool checkingUpdates = false;

  int _updateGeneration = 0;

  SeriesLookup? _updateLookup;

  final Map<String, Drama> _favorites = {};

  final Map<String, WatchRecord> _history = {};

  final Map<String, SeasonReminder> _seasonReminders = {};

  DateTime? _lastReminderEnabledAt;

  final _historyJson = <String, (WatchRecord, Map<String, dynamic>)>{};

  List<WatchRecord> get recent =>
      _history.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  int? episodeNumberFor(WatchRecord record) =>
      _cachedEpisodes(record.drama)
          ?.where((episode) => episode.id == record.episodeId)
          .firstOrNull
          ?.number ??
      record.episodeNumber;

  WatchResume resumeFor(WatchRecord record) =>
      WatchResume(record, _cachedEpisodes(record.drama));

  List<WatchRecord> get continuable =>
      recent.where((record) => resumeFor(record).canContinue).toList();

  List<Map<String, dynamic>> _historyRows() {
    _historyJson.removeWhere((key, _) => !_history.containsKey(key));
    return [
      for (final entry in _history.entries)
        (_historyJson[entry.key] =
                identical(_historyJson[entry.key]?.$1, entry.value)
                ? _historyJson[entry.key]!
                : (entry.value, entry.value.toJson()))
            .$2,
    ];
  }

  Future<void> toggleSeasonReminder(Drama drama) => _change((save) async {
    final previous = _seasonReminders[drama.key];
    if (previous != null) {
      _seasonReminders.remove(drama.key);
    } else {
      if (drama.source != DramaSource.hongguo ||
          SeriesTitle.parse(drama.title) == null ||
          _seasonReminders.length >= RecordBackup.maxSeasonReminders) {
        throw const ProviderException('暂时无法添加新季提醒');
      }
      _seasonReminders[drama.key] = SeasonReminder(
        anchor: drama,
        updatedAt: _newReminderTime(),
      );
    }
    try {
      await save();
    } catch (_) {
      if (previous == null) {
        _seasonReminders.remove(drama.key);
      } else {
        _seasonReminders[drama.key] = previous;
      }
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  });

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
  }) => _change((save) async {
    final current = _seasonReminders[anchor.key];
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
    _seasonReminders[anchor.key] = updated;
    try {
      await save();
    } catch (_) {
      _seasonReminders[anchor.key] = current;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  });

  Future<void> markSeasonRead(String key) => _change((save) async {
    final old = <String, SeasonReminder>{};
    final changed = <String, SeasonReminder>{};
    for (final entry in _seasonReminders.entries.toList()) {
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
    _seasonReminders.addAll(changed);
    try {
      await save();
    } catch (_) {
      _seasonReminders.addAll(old);
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  });

  int newEpisodeCount(Drama drama) {
    final seen = _episodeSeenIds[drama.key];
    if (seen == null) return 0;
    return (_cachedEpisodes(drama) ?? [])
        .where((e) => !seen.contains(e.id))
        .length;
  }

  Future<void> markEpisodesSeen(Drama drama, List<Episode> rows) =>
      _change((save) async {
        final ids = Set<String>.unmodifiable(rows.map((e) => e.id));
        if (setEquals(_episodeSeenIds[drama.key], ids) &&
            _persistence.persistenceError == null) {
          return;
        }
        _episodeSeenIds[drama.key] = ids;
        await save();
        notifyListeners();
      });

  Future<bool> checkFavoriteUpdates() async {
    if (checkingUpdates) return false;
    if (isOffline()) throw const ProviderException('请联网后检查更新');
    checkingUpdates = true;
    final generation = ++_updateGeneration;
    notifyListeners();
    var failures = 0;
    try {
      for (final drama in _favorites.values.toList()) {
        if (generation != _updateGeneration) break;
        try {
          await _loadEpisodes(drama, refresh: true);
        } catch (_) {
          failures++;
        }
      }
      final results = <String, CatalogSearchResult>{};
      for (final reminder in _seasonReminders.values.toList()) {
        if (generation != _updateGeneration) break;
        if (_seasonReminders[reminder.anchor.key]?.enabledAt !=
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
      notifyListeners();
    }
    if (generation != _updateGeneration) return false;
    if (failures > 0) throw ProviderException('$failures 部剧更新失败，已保留原有记录');
    return true;
  }

  void cancelUpdateChecks() {
    _updateGeneration++;
    _updateLookup?.cancel();
  }

  Future<void> toggleFavorite(Drama drama) => _change((save) async {
    if (_favorites.containsKey(drama.key)) {
      _favorites.remove(drama.key);
    } else {
      _favorites[drama.key] = drama;
    }
    notifyListeners();
    await save();
  });

  Future<void> saveWatch(WatchRecord record) => _change((save) async {
    final previous = _history[record.drama.key];
    if (previous != null &&
        _persistence.persistenceError == null &&
        previous.episodeId == record.episodeId &&
        previous.episodeIndex == record.episodeIndex &&
        previous.episodeNumber == record.episodeNumber &&
        previous.episodeCompleted == record.episodeCompleted &&
        previous.positionMs == record.positionMs &&
        previous.durationMs == record.durationMs &&
        previous.drama.hasSameMetadata(record.drama)) {
      return;
    }
    _history[record.drama.key] = record;
    if (!_closed) progress.notifyListeners();
    await save();
  });

  Future<void> removeHistory(String key) => _change((save) async {
    _history.remove(key);
    notifyListeners();
    await save();
  });

  String exportBackup() => const JsonEncoder.withIndent('  ').convert(
    RecordBackup(
      _favorites.values.toList(),
      _history.values.toList(),
      seasonReminders: _seasonReminders.values.toList(),
    ).toJson(),
  );

  RecordBackup inspectBackup(String raw) {
    if (utf8.encode(raw).length > 20 * 1024 * 1024) {
      throw const UserInputException('备份文件超过 20 MB');
    }
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return RecordBackup.fromJson(decoded);
    } catch (_) {
      throw const UserInputException('备份损坏或格式不兼容，原记录未修改');
    }
  }

  Future<void> importBackup(RecordBackup backup) async {
    // Detach and validate the caller's collections before waiting in the queue.
    final incoming = RecordBackup.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(backup.toJson())) as Map),
    );
    await _change((save) async {
      final candidate = _mergedBackup(incoming);
      if (candidate.favorites.length > RecordBackup.maxRecords ||
          candidate.history.length > RecordBackup.maxRecords ||
          candidate.seasonReminders.length > RecordBackup.maxSeasonReminders) {
        throw const UserInputException('合并后的记录超过上限，原记录未修改');
      }
      await save(candidate: candidate);
      _installBackup(candidate);
      notifyListeners();
    });
  }

  RecordBackup _mergedBackup(RecordBackup backup) {
    final favorites = Map<String, Drama>.of(_favorites);
    final history = Map<String, WatchRecord>.of(_history);
    final reminders = Map<String, SeasonReminder>.of(_seasonReminders);
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
      final existing = reminders[reminder.anchor.key];
      if (existing == null || reminder.updatedAt.isAfter(existing.updatedAt)) {
        reminders[reminder.anchor.key] = reminder;
      }
    }
    return RecordBackup(
      favorites.values.toList(),
      history.values.toList(),
      seasonReminders: reminders.values.toList(),
    );
  }

  void _installBackup(RecordBackup backup) {
    _favorites
      ..clear()
      ..addEntries(backup.favorites.map((d) => MapEntry(d.key, d)));
    _history
      ..clear()
      ..addEntries(backup.history.map((r) => MapEntry(r.drama.key, r)));
    _seasonReminders
      ..clear()
      ..addEntries(
        backup.seasonReminders.map((r) => MapEntry(r.anchor.key, r)),
      );
    for (final reminder in backup.seasonReminders) {
      if (_lastReminderEnabledAt == null ||
          reminder.enabledAt.isAfter(_lastReminderEnabledAt!)) {
        _lastReminderEnabledAt = reminder.enabledAt;
      }
    }
  }

  Map<String, dynamic> snapshot({bool reuseHistory = false}) => RecordBackup(
    _favorites.values.toList(),
    _history.values.toList(),
    seasonReminders: _seasonReminders.values.toList(),
  ).toJson(historyRows: reuseHistory ? _historyRows() : null);

  void restore(RecordBackup backup, Map<String, Set<String>> seen) {
    if (_started || _closed) throw StateError('只能在记录初始化时恢复快照');
    _episodeSeenIds.addAll({
      for (final entry in seen.entries)
        entry.key: Set.unmodifiable(entry.value),
    });
    _installBackup(_mergedBackup(backup));
    notifyListeners();
  }

  Future<void> updateDrama(Drama updated) => _change((save) async {
    final key = updated.key;
    final favorite = _favorites[key];
    final record = _history[key];
    if (favorite == null && record == null) return;
    var changed = false;
    if (favorite != null && !favorite.hasSameMetadata(updated)) {
      _favorites[key] = updated;
      changed = true;
    }
    if (record != null && !record.drama.hasSameMetadata(updated)) {
      _history[key] = record.withDrama(updated);
      changed = true;
    }
    if (!changed && _persistence.persistenceError == null) return;
    await save();
    // A retry commits the in-memory metadata left by the failed write.
    notifyListeners();
  });

  Future<void> episodesUpdated(Drama drama, List<Episode> baseline) =>
      _change((save) async {
        final changed = !_episodeSeenIds.containsKey(drama.key);
        _episodeSeenIds.putIfAbsent(
          drama.key,
          () => Set.unmodifiable(baseline.map((e) => e.id)),
        );
        if (changed) await save();
        notifyListeners();
      });

  @override
  void dispose() {
    _closed = true;
    cancelUpdateChecks();
    progress.dispose();
    super.dispose();
  }
}
