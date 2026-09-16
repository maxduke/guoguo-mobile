import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class NoNetwork implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => {'items': []};
}

void main() {
  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('navigation and layout at $size in $mode', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
          ..themeMode = mode;
        store.catalogs[DramaSource.hongguo] = List.generate(
          8,
          (i) => Drama(
            id: '$i',
            source: DramaSource.hongguo,
            title: ['山海有归期', '春风不负你', '重逢在雨季', '晚风知我意'][i % 4],
            category: '测试样例',
            episodes: 80,
          ),
        );
        final downloads = DownloadStore(store);
        await tester.pumpWidget(
          GuoguoApp(store: store, downloads: downloads, autoLoad: false),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('发现好剧'), findsOneWidget);
        await tester.tap(find.text('追剧'));
        await tester.pumpAndSettle();
        expect(find.text('留给喜欢的故事'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('下载'));
        await tester.pumpAndSettle();
        expect(find.text('下载管理'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        expect(find.text('外观'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      });
    }
  }
}
