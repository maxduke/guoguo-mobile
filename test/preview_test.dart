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
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'widget_test.dart' show NoNetwork;
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/rankings_page.dart';
import 'package:guoguo_mobile/ui/recommendations_page.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture designed phone and tablet previews with fixture content', (
    tester,
  ) async {
    final cacheDirectory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('guoguo-preview-'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cacheDirectory!.path,
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
    });
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
        final downloads = _PreviewDownloads(store);
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
    for (final mode in [Brightness.light, Brightness.dark]) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      final store = AppStore(
        storage: MemoryStorage(),
        provider: _PreviewRankings(),
      );
      final downloads = _PreviewDownloads(store)
        ..entries = [
          for (var i = 0; i < 3; i++)
            DownloadEntry(
              id: '$i',
              drama: _previewDrama(i < 2 ? 0 : 1),
              episode: Episode.fromJson({'id': '$i'}, i),
              index: i,
              directory: '/preview',
              input: 'video.mp4',
              contentKey: '',
              process: false,
              tasks: [],
              ready: true,
            ),
        ];
      for (final name in ['rankings', 'downloads', 'recommendations']) {
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: guoguoTheme(mode),
              home: name == 'rankings'
                  ? RankingsPage(store: store, onOpen: (_) {})
                  : name == 'recommendations'
                  ? RecommendationsPage(store: store, onOpen: (_) {})
                  : Scaffold(
                      appBar: AppBar(title: const Text('果果')),
                      body: DownloadsPage(
                        store: store,
                        downloads: downloads,
                        onOpen: (_) {},
                      ),
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
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'screenshots/$name-${mode.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      }
      downloads.dispose();
      store.dispose();
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
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
    await tester.runAsync(() async {
      await coverCache.dispose();
      await cacheDirectory!.delete(recursive: true);
    });
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

Drama _previewDrama(int index) => Drama(
  id: 'preview-$index',
  source: DramaSource.hongguo,
  title: ['山海有归期', '春风不负你', '重逢在雨季'][index % 3],
  category: '都市情感',
  episodes: 80,
  description: '一次久别重逢，让未完的故事有了新的开始。',
);

class _PreviewRankings implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => method == 'boards'
      ? {
          'items': [
            {'id': 'hot', 'name': '热播榜'},
            {'id': 'new', 'name': '新剧榜'},
          ],
        }
      : method == 'recommendations'
      ? {
          'items': [for (var i = 0; i < 5; i++) _previewDrama(i).toJson()],
          'hasMore': true,
          'nextOffset': 18,
          'sessionId': 'preview',
        }
      : {
          'items': [
            for (var i = 0; i < 5; i++)
              {'rank': i + 1, 'drama': _previewDrama(i).toJson()},
          ],
          'hasMore': false,
        };
}

class _PreviewDownloads extends DownloadStore {
  _PreviewDownloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}
