import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'detail_episode_ux_test.dart' show FakeDownloads, episodes;
import 'widget_test.dart' show NoNetwork;

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture detail phone and tablet with synthetic content', (
    tester,
  ) async {
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('guoguo-detail-preview-'),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => temporary!.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
    await tester.runAsync(() async {
      await (FontLoader('sans-serif')..addFont(
            Future.value(ByteData.sublistView(await File(font!).readAsBytes())),
          ))
          .load();
      final icons = Platform.environment['GUOGUO_ICON_FONT'];
      if (icons != null) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(icons).readAsBytes()),
              ),
            ))
            .load();
      }
    });
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(390, 844), const Size(1024, 768)]) {
      for (final brightness in Brightness.values) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
          ..offline = true;
        const drama = Drama(
          id: 'preview',
          source: DramaSource.hongguo,
          title: '山海有归期',
          category: '布局示例',
          episodes: 70,
          description:
              '多年以后，故乡的一封来信，让她重新踏上归途。在山海之间，一段关于重逢与成长的故事慢慢展开。\n\n本页面使用合成内容展示布局，不是站源实测。',
        );
        store.catalog.episodeCache[drama.key] = episodes();
        store.records.restore(
          RecordBackup([], [
            WatchRecord(
              drama: drama,
              episodeId: 'e3',
              episodeIndex: 3,
              positionMs: 30000,
              durationMs: 120000,
              updatedAt: DateTime.now(),
            ),
          ]),
          {},
        );
        final downloads = FakeDownloads(store);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: guoguoTheme(brightness),
              home: DetailPage(
                store: store,
                downloads: downloads,
                drama: drama,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'screenshots/detail-${size.width < 500 ? 'phone' : 'tablet'}-${brightness.name}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      }
    }
    await tester.pump(const Duration(seconds: 11));
    await tester.runAsync(() async {
      await coverCache.dispose();
      await temporary!.delete(recursive: true);
    });
  }, skip: font == null);
}
