import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'widget_test.dart' show NoNetwork;

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture designed phone and tablet previews with fixture content', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fontLoader = FontLoader('sans-serif')
        ..addFont(
          Future.value(ByteData.sublistView(await File(font!).readAsBytes())),
        );
      await fontLoader.load();
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
    for (final size in [const Size(390, 844), const Size(1024, 768)]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
          ..themeMode = mode;
        store.catalogs[DramaSource.hongguo] = List.generate(
          8,
          (i) => Drama(
            id: '$i',
            source: DramaSource.hongguo,
            title: ['山海有归期', '春风不负你', '重逢在雨季', '晚风知我意'][i % 4],
            category: '布局示例',
            episodes: 80,
          ),
        );
        final downloads = DownloadStore(store);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: GuoguoApp(
              store: store,
              downloads: downloads,
              autoLoad: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('screenshots').create();
          await File(
            'screenshots/${size.width < 500 ? 'phone' : 'tablet'}-${mode.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      }
    }
    // Export the actual app mark at each platform-required size.
    final catalog =
        jsonDecode(
              File(
                'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
              ).readAsStringSync(),
            )
            as Map;
    final targets = <String, int>{};
    for (final entry in catalog['images'] as List) {
      final size = double.parse((entry['size'] as String).split('x').first);
      final scale = double.parse(
        (entry['scale'] as String).replaceAll('x', ''),
      );
      targets['ios/Runner/Assets.xcassets/AppIcon.appiconset/${entry['filename']}'] =
          (size * scale).round();
    }
    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      targets['android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png'] =
          entry.value;
    }
    for (final target in targets.entries) {
      final pixels = target.value.toDouble();
      tester.view.physicalSize = Size(pixels, pixels);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: CustomPaint(painter: _MarkPainter()),
        ),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(target.key).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, skip: font == null);
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF235849),
    );
    final path = Path()
      ..moveTo(size.width * .38, size.height * .27)
      ..lineTo(size.width * .74, size.height * .5)
      ..lineTo(size.width * .38, size.height * .73)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFF7F5EF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
