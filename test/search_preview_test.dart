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
import 'package:guoguo_mobile/ui/search_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';

import 'widget_test.dart' show NoNetwork;

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture search history, results and keyboard layouts', (
    tester,
  ) async {
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('guoguo-search-preview-'),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => temporary!.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.runAsync(() async {
      await coverCache.getFileFromCache('search-preview-initialization');
      await Directory('build/search-previews').create(recursive: true);
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
    for (final sample in [
      (const Size(390, 844), 1.0, 0.0, '', 'phone-history'),
      (const Size(1024, 768), 1.0, 0.0, '归期', 'tablet-results'),
      (const Size(320, 640), 1.6, 280.0, '归期', 'small-keyboard'),
    ]) {
      for (final brightness in Brightness.values) {
        tester.view.physicalSize = sample.$1;
        tester.view.devicePixelRatio = 1;
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
          ..offline = true;
        store.catalog.recentSearches.addAll(['山海有归期', '故乡的来信', '一路向北']);
        store.catalog.catalogs[DramaSource.hongguo] = List.generate(
          12,
          (index) => Drama(
            id: 'preview-$index',
            source: DramaSource.hongguo,
            title: index == 0 ? '山海有归期：故乡与远方的故事' : '山海有归期 ${index + 1}',
            category: '合成示例',
            episodes: 60,
          ),
        );
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: guoguoTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(sample.$2),
                  viewInsets: EdgeInsets.only(bottom: sample.$3),
                ),
                child: child!,
              ),
              home: SearchPage(store: store, onOpen: (_) {}, autofocus: false),
            ),
          ),
        );
        if (sample.$4.isNotEmpty) {
          await tester.enterText(find.byType(TextField), sample.$4);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/search-previews/search-${sample.$5}-${brightness.name}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
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
