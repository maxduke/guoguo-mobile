import 'catalog_response.dart';
import 'models.dart';

String _topicKey(String text) => text.trim().toLowerCase();

bool _meaningful(String text) =>
    text.trim().isNotEmpty && !const {'全部', '未分类', '未知'}.contains(text.trim());

/// A real source category can be paged; other topics match saved metadata only.
class CatalogTopic {
  const CatalogTopic(this.name, {this.categoryId});
  final String name;
  final String? categoryId;
  bool get remote => categoryId != null;

  bool matches(Drama drama) => [
    drama.category,
    ...drama.tags,
  ].any((value) => _topicKey(value) == _topicKey(name));
}

List<CatalogTopic> catalogTopics(
  DramaSource source,
  Iterable<Drama> dramas, {
  Iterable<SourceCategory> categories = const [],
}) {
  final topics = <String, CatalogTopic>{};
  if (source.topicCategories) {
    for (final category in categories) {
      if (category.id.isNotEmpty && _meaningful(category.name)) {
        topics.putIfAbsent(
          _topicKey(category.name),
          () => CatalogTopic(category.name.trim(), categoryId: category.id),
        );
      }
    }
  }
  for (final drama in dramas) {
    if (drama.source != source) continue;
    for (final value in [drama.category, ...drama.tags]) {
      if (!_meaningful(value)) continue;
      topics.putIfAbsent(_topicKey(value), () => CatalogTopic(value.trim()));
    }
  }
  return List.unmodifiable(topics.values);
}

List<Drama> topicDramas(
  DramaSource source,
  CatalogTopic topic,
  Iterable<Drama> dramas,
) => List.unmodifiable(
  {
    for (final drama in dramas)
      if (drama.source == source && topic.matches(drama)) drama.key: drama,
  }.values,
);
