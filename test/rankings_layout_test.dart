import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/rankings_page.dart';

class _RankingProvider implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => method == 'boards'
      ? {
          'items': [
            {'id': 'fixture', 'name': '热播榜'},
          ],
        }
      : {
          'items': [
            {
              'rank': 1,
              'drama': const Drama(
                id: 'huangdou:target',
                source: DramaSource.huangdou,
                title: '用于检查小屏幕榜单标题与封面的长剧名',
              ).toJson(),
            },
          ],
          'hasMore': false,
        };
}

void main() {
  testWidgets(
    'large ranking cover and long title fit; opening preserves identity',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(
        storage: MemoryStorage(),
        provider: _RankingProvider(),
      );
      store.catalog.source = DramaSource.huangdou;
      Drama? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: RankingsPage(store: store, onOpen: (drama) => opened = drama),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Poster), findsOneWidget);
      expect(tester.getSize(find.byType(Poster)), const Size(96, 132));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('用于检查小屏幕榜单标题与封面的长剧名'));
      expect(opened?.id, 'huangdou:target');
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );
}
