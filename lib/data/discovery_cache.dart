import 'dart:convert';

import '../domain/discovery.dart';
import '../domain/models.dart';

class CachedDiscoveryColumn {
  CachedDiscoveryColumn(
    Iterable<DiscoveryRow> rows, {
    required this.savedAt,
    required this.kind,
    this.description = '',
    this.warning,
  }) : rows = List.unmodifiable(rows);
  final List<DiscoveryRow> rows;
  final DateTime savedAt;
  final DiscoveryKind kind;
  final String description;
  final String? warning;

  Map<String, dynamic> toJson() => {
    'savedAt': savedAt.toIso8601String(),
    'kind': kind.name,
    'description': description,
    'warning': warning,
    'rows': rows.map((row) => row.toJson()).toList(),
  };
}

class CachedDiscoveryBoards {
  CachedDiscoveryBoards(Iterable<DiscoveryBoard> boards, this.savedAt)
    : boards = List.unmodifiable(boards);
  final List<DiscoveryBoard> boards;
  final DateTime savedAt;
  Map<String, dynamic> toJson() => {
    'savedAt': savedAt.toIso8601String(),
    'boards': boards.map((board) => board.toJson()).toList(),
  };
}

/// Ordered, disposable prefixes. Transport cursors and sessions stay in pages.
class DiscoveryCache {
  DiscoveryCache({required this.now, this.onRead});
  final DateTime Function() now;
  final void Function(DramaSource source, String method)? onRead;
  static const retention = Duration(days: 7);
  static const maxRows = 60, maxColumns = 24, maxColumnBytes = 64 * 1024;
  static const maxBoards = 100, maxBoardBytes = 16 * 1024;
  final _columns = <String, CachedDiscoveryColumn>{};
  final _boards = <DramaSource, CachedDiscoveryBoards>{};

  Iterable<Drama> get dramas => _columns.values
      .where((entry) => _validDate(entry.savedAt))
      .expand((entry) => entry.rows.map((row) => row.drama));

  String _recommendationKey(RecommendationGenre genre) =>
      'recommendations|${genre.id}';
  String _rankingKey(DramaSource source, String board) =>
      'rankings|${source.name}|$board';

  bool _validDate(DateTime date) {
    final clock = now();
    return !clock.isBefore(date) && clock.difference(date) <= retention;
  }

  CachedDiscoveryColumn? _read(String key, DramaSource source, String method) {
    final column = _columns.remove(key);
    if (column == null || !_validDate(column.savedAt)) return null;
    _columns[key] = column;
    onRead?.call(source, method);
    return column;
  }

  CachedDiscoveryColumn? recommendations(RecommendationGenre genre) =>
      _read(_recommendationKey(genre), DramaSource.hongguo, 'recommendations');
  CachedDiscoveryColumn? ranking(DramaSource source, String board) =>
      _read(_rankingKey(source, board), source, 'ranking');

  DateTime? lastContentRetrieval(DramaSource source) {
    DateTime? latest;
    for (final entry in _columns.entries) {
      if (!entry.key.startsWith('rankings|${source.name}|') &&
          !(source == DramaSource.hongguo &&
              entry.key.startsWith('recommendations|'))) {
        continue;
      }
      final savedAt = entry.value.savedAt;
      if (_validDate(savedAt) && (latest == null || savedAt.isAfter(latest))) {
        latest = savedAt;
      }
    }
    return latest;
  }

  CachedDiscoveryBoards? boards(DramaSource source) {
    final entry = _boards[source];
    if (entry != null && !_validDate(entry.savedAt)) {
      _boards.remove(source);
      return null;
    }
    if (entry != null) onRead?.call(source, 'boards');
    return entry;
  }

  void putRecommendations(
    RecommendationGenre genre,
    Iterable<Drama> dramas,
    DateTime savedAt,
  ) => _put(
    _recommendationKey(genre),
    DramaSource.hongguo,
    CachedDiscoveryColumn(
      dramas.take(maxRows).map((drama) => DiscoveryRow(drama)),
      savedAt: savedAt,
      kind: DiscoveryKind.recommendation,
    ),
  );

  void putRanking(
    DramaSource source,
    String board,
    CachedDiscoveryColumn column,
  ) {
    if (board.isEmpty || board.contains('|')) {
      throw const FormatException('栏目身份不正确');
    }
    _put(_rankingKey(source, board), source, column);
  }

  void _put(String key, DramaSource source, CachedDiscoveryColumn column) {
    if (!_validDate(column.savedAt)) return;
    final rows = column.rows.take(maxRows).toList();
    if (rows.any((row) => row.drama.source != source || row.rank < 0)) {
      throw const FormatException('栏目站源不匹配');
    }
    // Count each row once and retain a prefix that fits with its key/metadata.
    final boundedRows = <DiscoveryRow>[];
    final header = CachedDiscoveryColumn(
      const [],
      savedAt: column.savedAt,
      kind: column.kind,
      description: column.description,
      warning: column.warning,
    );
    var bytes = utf8.encode(jsonEncode({key: header.toJson()})).length;
    if (bytes > maxColumnBytes) return;
    for (final row in rows) {
      final extra =
          utf8.encode(jsonEncode(row.toJson())).length +
          (boundedRows.isEmpty ? 0 : 1);
      if (bytes + extra > maxColumnBytes) break;
      boundedRows.add(row);
      bytes += extra;
    }
    if (column.rows.isNotEmpty && boundedRows.isEmpty) return;
    _columns.removeWhere((_, entry) => !_validDate(entry.savedAt));
    _columns.remove(key);
    _columns[key] = CachedDiscoveryColumn(
      boundedRows,
      savedAt: column.savedAt,
      kind: column.kind,
      description: column.description,
      warning: column.warning,
    );
    while (_columns.length > maxColumns) {
      _columns.remove(_columns.keys.first);
    }
  }

  void putBoards(
    DramaSource source,
    Iterable<DiscoveryBoard> boards,
    DateTime savedAt,
  ) {
    if (!_validDate(savedAt)) return;
    final entry = CachedDiscoveryBoards(boards.take(maxBoards), savedAt);
    if (utf8.encode(jsonEncode(entry.toJson())).length > maxBoardBytes) return;
    _boards[source] = entry;
  }

  Map<String, dynamic> toJson() {
    _columns.removeWhere((_, entry) => !_validDate(entry.savedAt));
    _boards.removeWhere((_, entry) => !_validDate(entry.savedAt));
    return {
      'columns': {
        for (final entry in _columns.entries) entry.key: entry.value.toJson(),
      },
      'boards': {
        for (final entry in _boards.entries)
          entry.key.name: entry.value.toJson(),
      },
    };
  }

  void restore(Object? value) {
    if (value is! Map) return;
    final columns = value['columns'];
    if (columns is Map) {
      for (final entry in columns.entries.take(maxColumns)) {
        try {
          final parts = (entry.key as String).split('|');
          final row = entry.value as Map;
          final rawRows = row['rows'] as List;
          if (rawRows.length > maxRows) continue;
          final column = CachedDiscoveryColumn(
            rawRows.map((raw) => DiscoveryRow.fromJson(raw as Map)),
            savedAt: DateTime.parse(row['savedAt'] as String),
            kind: DiscoveryKind.parse(row['kind']),
            description: row['description'] as String? ?? '',
            warning: row['warning'] as String?,
          );
          if (parts.length == 2 && parts.first == 'recommendations') {
            final genre = RecommendationGenre.parse(parts[1]);
            if (column.kind != DiscoveryKind.recommendation) continue;
            _put(_recommendationKey(genre), DramaSource.hongguo, column);
          } else if (parts.length == 3 && parts.first == 'rankings') {
            putRanking(DramaSource.parse(parts[1]), parts[2], column);
          }
        } catch (_) {
          // A damaged column does not discard other columns or durable records.
        }
      }
    }
    final boards = value['boards'];
    if (boards is Map) {
      for (final entry in boards.entries.take(DramaSource.values.length)) {
        try {
          final source = DramaSource.parse(entry.key);
          final row = entry.value as Map;
          final rawBoards = row['boards'] as List;
          if (rawBoards.length > maxBoards) continue;
          putBoards(
            source,
            rawBoards.map((raw) => DiscoveryBoard.fromJson(raw as Map, source)),
            DateTime.parse(row['savedAt'] as String),
          );
        } catch (_) {
          // Board metadata is disposable too.
        }
      }
    }
  }
}
