import 'dart:convert';

import '../domain/models.dart';

class CatalogSearchResult {
  const CatalogSearchResult(
    this.items, {
    this.warning = '',
    this.limited = false,
    this.hasMore = false,
    this.total = 0,
  });
  final List<Drama> items;
  final String warning;
  final bool limited, hasMore;
  final int total;
}

class CachedSearch {
  const CachedSearch(
    this.result,
    this.savedAt,
    this.bytes, {
    this.fresh = false,
  });
  final CatalogSearchResult result;
  final DateTime savedAt;
  final int bytes;
  final bool fresh;
  Map<String, dynamic> toJson() => {
    'savedAt': savedAt.toIso8601String(),
    'items': result.items.map((row) => row.toJson()).toList(),
    'warning': result.warning,
    'limited': result.limited,
    'hasMore': result.hasMore,
    'total': result.total,
  };
}

class SearchCache {
  static const ttl = Duration(minutes: 20);
  static const maxEntries = 24, maxBytes = 2 * 1024 * 1024;
  final _entries = <String, CachedSearch>{};
  CachedSearch? read(String key, DateTime now) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return CachedSearch(
      entry.result,
      entry.savedAt,
      entry.bytes,
      fresh:
          entry.result.warning.isEmpty &&
          now.difference(entry.savedAt) <= ttl &&
          !now.isBefore(entry.savedAt),
    );
  }

  void put(String key, CatalogSearchResult result, DateTime now) {
    if (result.items.length > 1000) return;
    final previous = _entries[key];
    if (previous != null &&
        previous.result.warning.isEmpty &&
        result.warning.isNotEmpty) {
      return;
    }
    final entry = CachedSearch(
      CatalogSearchResult(
        List.unmodifiable(result.items),
        warning: result.warning,
        limited: result.limited,
        hasMore: result.hasMore,
        total: result.total,
      ),
      now,
      0,
    );
    final size = utf8.encode(jsonEncode(entry.toJson())).length;
    if (size > 256 * 1024) return;
    _entries.remove(key);
    _entries[key] = CachedSearch(entry.result, now, size);
    while (_entries.length > maxEntries ||
        _entries.values.fold<int>(0, (sum, e) => sum + e.bytes) > maxBytes) {
      _entries.remove(_entries.keys.first);
    }
  }

  Map<String, dynamic> toJson() => {
    for (final entry in _entries.entries) entry.key: entry.value.toJson(),
  };
  void restore(Map value) {
    for (final entry in value.entries.take(maxEntries)) {
      try {
        final key = entry.key as String;
        final source = DramaSource.parse(key.split('|').first);
        final row = entry.value as Map;
        final items = (row['items'] as List)
            .map((v) => Drama.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList();
        if (items.any((d) => d.source != source)) continue;
        put(
          key,
          CatalogSearchResult(
            items,
            warning: row['warning'] as String? ?? '',
            limited: row['limited'] == true,
            hasMore: row['hasMore'] == true,
            total: row['total'] as int? ?? 0,
          ),
          DateTime.parse(row['savedAt'] as String),
        );
      } catch (_) {
        /* A disposable cache entry may become obsolete. */
      }
    }
  }

  List<Drama> get dramas =>
      _entries.values.expand((e) => e.result.items).toList();
}
