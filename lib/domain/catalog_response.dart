import 'models.dart';

class SourceCategory {
  const SourceCategory(this.id, this.name);
  final String id, name;

  factory SourceCategory.fromJson(Map value) =>
      SourceCategory(value['id'] as String, value['name'] as String);
}

List<Drama> _dramas(Map value, DramaSource source) {
  final rows = List<Drama>.unmodifiable(
    (value['items'] as List? ?? []).map(
      (raw) => Drama.fromJson(Map<String, dynamic>.from(raw as Map)),
    ),
  );
  if (rows.any((row) => row.source != source)) {
    throw const FormatException('站源返回了不匹配的内容');
  }
  return rows;
}

class CatalogPage {
  const CatalogPage(this.items, {this.hasMore = false, this.warning = ''});
  final List<Drama> items;
  final bool hasMore;
  final String warning;

  factory CatalogPage.fromJson(Map value, DramaSource source) => CatalogPage(
    _dramas(value, source),
    hasMore: value['hasMore'] as bool? ?? false,
    warning: value['warning'] as String? ?? '',
  );
}

class CatalogSearchResult {
  const CatalogSearchResult(
    this.items, {
    this.warning = '',
    this.limited = false,
    this.hasMore = false,
    this.total = 0,
    this.fromCache = false,
    this.continuation = '',
    this.restartRequired = false,
  });
  final List<Drama> items;
  final String warning;
  final bool limited, hasMore, fromCache;
  final int total;
  final String continuation;
  final bool restartRequired;

  factory CatalogSearchResult.fromJson(Map value, DramaSource source) =>
      CatalogSearchResult(
        _dramas(value, source),
        warning: value['warning'] as String? ?? '',
        limited: value['limited'] as bool? ?? false,
        hasMore: value['hasMore'] as bool? ?? false,
        total: value['total'] as int? ?? 0,
        continuation: value['continuation'] as String? ?? '',
        restartRequired: value['restartRequired'] as bool? ?? false,
      );
}
