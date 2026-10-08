import 'models.dart';

enum RecommendationGenre {
  shortPlay('short_play', '真人剧'),
  comicSeries('comic_series', '漫剧'),
  aiSeries('ai_series', 'AI 剧');

  const RecommendationGenre(this.id, this.label);
  final String id, label;
  static RecommendationGenre parse(String id) =>
      values.firstWhere((genre) => genre.id == id);
}

enum DiscoveryKind {
  ranking,
  recommendation,
  catalog;

  static DiscoveryKind parse(Object? value) => values.firstWhere(
    (kind) => kind.name == (value ?? 'ranking'),
    orElse: () => throw const FormatException('未知栏目类型'),
  );
}

class DiscoveryBoard {
  const DiscoveryBoard(
    this.id,
    this.name, {
    this.kind = DiscoveryKind.ranking,
    this.description = '',
  });
  final String id, name;
  final DiscoveryKind kind;
  final String description;

  factory DiscoveryBoard.fromJson(Map value, DramaSource source) {
    final id = value['id'] as String;
    final name = value['name'] as String;
    if (id.isEmpty ||
        name.isEmpty ||
        (value['source'] != null && value['source'] != source.name)) {
      throw const FormatException('栏目资料不匹配');
    }
    return DiscoveryBoard(
      id,
      name,
      kind: DiscoveryKind.parse(value['kind']),
      description: value['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'description': description,
  };
}

class DiscoveryRow {
  const DiscoveryRow(this.drama, {this.rank = 0});
  final Drama drama;
  final int rank;

  factory DiscoveryRow.fromJson(Map value) {
    final rank = value['rank'] as int? ?? 0;
    if (rank < 0) throw const FormatException('栏目排名不正确');
    return DiscoveryRow(
      Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
      rank: rank,
    );
  }

  Map<String, dynamic> toJson() => {'drama': drama.toJson(), 'rank': rank};
}

class RecommendationBatch {
  const RecommendationBatch(
    this.items, {
    required this.nextOffset,
    required this.sessionId,
    required this.hasMore,
  });
  final List<Drama> items;
  final int nextOffset;
  final String sessionId;
  final bool hasMore;

  factory RecommendationBatch.fromJson(Map<String, dynamic> value) {
    final rows = List<Drama>.unmodifiable(
      (value['items'] as List).map(
        (raw) => Drama.fromJson(Map<String, dynamic>.from(raw as Map)),
      ),
    );
    final offset = value['nextOffset'] as int;
    if (offset < 0 || rows.any((row) => row.source != DramaSource.hongguo)) {
      throw const FormatException('推荐资料不匹配');
    }
    return RecommendationBatch(
      rows,
      nextOffset: offset,
      sessionId: value['sessionId'] as String? ?? '',
      hasMore: value['hasMore'] as bool? ?? false,
    );
  }
}

class DiscoveryColumnResult {
  const DiscoveryColumnResult(
    this.rows, {
    required this.kind,
    required this.description,
    required this.hasMore,
    this.warning,
  });
  final List<DiscoveryRow> rows;
  final DiscoveryKind kind;
  final String description;
  final String? warning;
  final bool hasMore;

  factory DiscoveryColumnResult.fromJson(
    Map<String, dynamic> value,
    DramaSource source, {
    required String board,
    required int page,
  }) {
    final rows = List<DiscoveryRow>.unmodifiable(
      (value['items'] as List).map((raw) => DiscoveryRow.fromJson(raw as Map)),
    );
    if ((value['boardId'] != null && value['boardId'] != board) ||
        (value['page'] != null && value['page'] != page) ||
        rows.any((row) => row.drama.source != source)) {
      throw const FormatException('栏目资料不匹配');
    }
    return DiscoveryColumnResult(
      rows,
      kind: DiscoveryKind.parse(value['kind']),
      description: value['description'] as String? ?? '',
      warning: value['warning'] as String?,
      hasMore: value['hasMore'] as bool? ?? false,
    );
  }
}
