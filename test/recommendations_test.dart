import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/recommendations_page.dart';
import 'package:guoguo_mobile/ui/components.dart';

class RecommendationProvider implements ProviderClient {
  final requests = <Map<String, dynamic>>[];
  final responses = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    expect(method, 'recommendations');
    requests.add(Map<String, dynamic>.from(args['recommendation'] as Map));
    final response = Completer<Map<String, dynamic>>();
    responses.add(response);
    return response.future;
  }
}

Map<String, dynamic> page(String id, String title, {int next = 18}) => {
  'items': [Drama(id: id, source: DramaSource.hongguo, title: title).toJson()],
  'nextOffset': next,
  'sessionId': 'session',
  'hasMore': true,
};
void main() {
  testWidgets('genre switch ignores old response and uses independent cursor', (
    tester,
  ) async {
    final provider = RecommendationProvider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    await tester.pumpWidget(
      MaterialApp(
        home: RecommendationsPage(store: store, onOpen: (_) {}),
      ),
    );
    expect(provider.requests.single['genre'], 'short_play');
    await tester.tap(find.text('漫剧'));
    await tester.pump();
    expect(provider.requests.last['genre'], 'comic_series');
    expect(provider.requests.last['offset'], 0);
    provider.responses[1].complete(page('hongguo:2', '新分类'));
    await tester.pumpAndSettle();
    provider.responses[0].complete(page('hongguo:1', '旧分类'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DramaCard>(find.byType(DramaCard)).drama.id,
      'hongguo:2',
    );
    expect(find.text('旧分类'), findsNothing);
    expect(store.library.map((d) => d.id), ['hongguo:2']);
    await tester.scrollUntilVisible(find.text('继续推荐'), 200);
    await tester.tap(find.text('继续推荐'));
    await tester.pump();
    expect(provider.requests.last['offset'], 18);
    expect(provider.requests.last['sessionId'], 'session');
    expect(provider.requests.last['seen'], ['hongguo:2']);
    provider.responses.last.completeError(Exception('网络暂不可用'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DramaCard>(find.byType(DramaCard)).drama.id,
      'hongguo:2',
    );
    await tester.scrollUntilVisible(find.text('重试'), -200);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(provider.requests.last['offset'], 18);
    provider.responses.last.complete(page('hongguo:3', '下一页', next: 36));
    await tester.pumpAndSettle();
    expect(store.library.length, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}
