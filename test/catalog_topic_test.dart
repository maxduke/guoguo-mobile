import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/source_diagnostics.dart';
import 'package:guoguo_mobile/domain/catalog_response.dart';
import 'package:guoguo_mobile/domain/catalog_topic.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/source_diagnostic.dart';

void main() {
  test(
    'topics use real metadata and category IDs for each of the nineteen sources',
    () {
      for (final source in DramaSource.values) {
        final topics = catalogTopics(
          source,
          [
            Drama(
              id: '1',
              source: source,
              title: '故事',
              category: ' 都市 ',
              tags: const ['都市', '治愈', '', '未分类'],
            ),
            Drama(
              id: '2',
              source: DramaSource.values.firstWhere((other) => other != source),
              title: '其他',
              tags: const ['其他站私有题材'],
            ),
          ],
          categories: const [
            SourceCategory('', '全部'),
            SourceCategory('city-id', '都市'),
          ],
        );
        expect(topics.map((topic) => topic.name), ['都市', '治愈']);
        expect(
          topics.first.categoryId,
          source.topicCategories ? 'city-id' : null,
        );
        expect(topics.last.remote, isFalse);
      }
    },
  );

  test(
    'topic matching uses exact categories and tags rather than title search',
    () {
      const source = DramaSource.huangguo;
      const topic = CatalogTopic('都市');
      final rows = topicDramas(source, topic, const [
        Drama(id: '1', source: source, title: '都市之旅', tags: ['仙侠']),
        Drama(id: '2', source: source, title: '山海', category: ' 都市 '),
        Drama(id: '3', source: source, title: '归期', tags: ['都市']),
        Drama(id: '3', source: source, title: '归期', tags: ['都市']),
        Drama(id: '4', source: source, title: '其他', tags: ['都市生活']),
        Drama(
          id: '2',
          source: DramaSource.hongguo,
          title: '其他来源',
          tags: ['都市'],
        ),
      ]);
      expect(rows.map((row) => row.id), ['2', '3']);
    },
  );

  test(
    'request summaries ignore cancellation, background work and typing suggestions',
    () {
      final diagnostics = SourceDiagnostics(now: DateTime.now);
      addTearDown(diagnostics.dispose);
      final start = DateTime(2026, 11, 5, 18);
      SourceDiagnostic sample(
        int minute, {
        String result = 'success',
        bool background = false,
        String method = 'catalog',
        DramaSource source = DramaSource.huangguo,
      }) => SourceDiagnostic(
        source: source,
        method: method,
        at: start.add(Duration(minutes: minute)),
        elapsedMs: 100,
        result: result,
        background: background,
      );
      final latest = sample(2, result: 'failed');
      diagnostics.add(latest);
      diagnostics.add(sample(1)); // Earlier-started request completed later.
      diagnostics.add(sample(3, result: 'cancelled'));
      diagnostics.add(sample(4, background: true));
      diagnostics.add(sample(5, method: 'suggestions'));
      diagnostics.add(sample(6, source: DramaSource.hongguo));
      expect(diagnostics.latestFor(DramaSource.huangguo), same(latest));
      expect(diagnostics.latestFor(DramaSource.yeguo), isNull);
      diagnostics.clear(source: DramaSource.huangguo);
      expect(diagnostics.samples.single.source, DramaSource.hongguo);
    },
  );
}
