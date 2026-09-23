import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'widget_test.dart' show NoNetwork;

class _PreviewDownloads extends DownloadStore {
  _PreviewDownloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('download tasks and storage previews', (tester) async {
    final cacheDirectory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('guoguo-download-preview-'),
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
      await (FontLoader('sans-serif')..addFont(
            Future.value(ByteData.sublistView(await File(font!).readAsBytes())),
          ))
          .load();
      final iconFont = Platform.environment['GUOGUO_ICON_FONT'];
      if (iconFont != null) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(iconFont).readAsBytes()),
              ),
            ))
            .load();
      }
      await Directory('build/download-previews').create(recursive: true);
    });
    for (final width in [390.0, 1024.0]) {
      for (final mode in [Brightness.light, Brightness.dark]) {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
        final downloads = _PreviewDownloads(store)
          ..entries = [
            for (var i = 1; i <= 4; i++)
              DownloadEntry(
                id: '$i',
                drama: Drama(
                  id: i < 4 ? '1' : '2',
                  source: DramaSource.hongguo,
                  title: i < 4 ? '山海有归期' : '春风不负你',
                ),
                episode: Episode.fromJson({'id': '$i'}, i - 1),
                index: i - 1,
                directory: '/preview',
                input: 'video.mp4',
                contentKey: '',
                process: false,
                tasks: [],
                ready: i == 1,
                userPaused: i == 2,
                failure: i == 3 ? '网络连接中断，请检查网络后重试' : null,
              )..progress = .45,
          ];
        downloads.bytesByEntry.addAll({
          '1': 240 * 1024 * 1024,
          '2': 100 * 1024 * 1024,
          '3': 80 * 1024 * 1024,
          '4': 22 * 1024 * 1024,
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: guoguoTheme(mode),
              home: Scaffold(
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
        for (final view in ['tasks', 'storage']) {
          if (view == 'storage') {
            await tester.tap(find.text('按剧空间'));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/download-previews/$view-${width.toInt()}-${mode.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      }
    }
    await tester.pump(const Duration(seconds: 11));
    await tester.runAsync(() async {
      await coverCache.dispose();
      await cacheDirectory!.delete(recursive: true);
    });
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, skip: font == null);
}
