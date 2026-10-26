import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_startup.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/components.dart';

import 'widget_test.dart' show NoNetwork;

class _Downloads extends DownloadStore {
  _Downloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture Chinese adaptive home layouts', (tester) async {
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('guoguo-adaptive-preview-'),
    );
    const path = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(path, (_) async => temporary!.path);
    addTearDown(() => messenger.setMockMethodCallHandler(path, null));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await coverCache.getFileFromCache('adaptive-preview-initialization');
      await Directory('build/adaptive-previews').create(recursive: true);
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
    for (final sample in [
      ('phone', const Size(390, 844), 1.0),
      ('small-large-text', const Size(320, 640), 2.0),
      ('landscape-notices', const Size(740, 320), 2.0),
      ('tablet', const Size(1024, 768), 1.0),
      ('television', const Size(1280, 720), 1.0),
      ('split-window', const Size(500, 768), 1.0),
    ]) {
      for (final brightness in Brightness.values) {
        tester.view.physicalSize = sample.$2;
        tester.view.devicePixelRatio = 1;
        final store = AppStore(
          storage: MemoryStorage(),
          provider: NoNetwork(),
          now: () => DateTime(2026, 10, 26, 12),
        )..offline = true;
        final dramas = List.generate(
          6,
          (i) => Drama(
            id: '$i',
            source: DramaSource.hongguo,
            title: ['山海有归期：故乡与远方的故事', '春风不负你', '重逢在雨季'][i % 3],
            category: '合成布局示例',
            episodes: 80,
          ),
        );
        store.catalog.discoveryCache.putRecommendations(
          RecommendationGenre.shortPlay,
          dramas,
          store.now(),
        );
        final downloads = _Downloads(store);
        AppStartup? startup;
        if (sample.$1 == 'landscape-notices') {
          store.persistenceError = '记录暂未保存，请检查可用空间后重试';
          store.cachePersistenceError = '目录缓存暂未保存，请检查可用空间后重试';
          startup =
              AppStartup(
                  store: store,
                  downloads: downloads,
                  initializeCore: () async {},
                  checkOffline: () async => true,
                  offlineChanges: const Stream.empty(),
                )
                ..coreError = '站源连接暂未就绪，可浏览已有记录，请重试'
                ..networkError = '网络状态暂时无法获取，可继续浏览，请重试';
        }
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: guoguoTheme(
                brightness,
                television: sample.$1 == 'television',
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(sample.$3)),
                child: TelevisionScope(
                  enabled: sample.$1 == 'television',
                  child: child!,
                ),
              ),
              home: HomePage(
                store: store,
                downloads: downloads,
                startup: startup,
                autoLoad: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Future<void> capture(String name) async {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/adaptive-previews/$name-${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture(sample.$1);
        if (sample.$1 == 'television') {
          final action = find.descendant(
            of: find.byType(DramaCard).first,
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.button == true,
            ),
          );
          Focus.of(tester.element(action)).requestFocus();
          await tester.pumpAndSettle();
          expect(find.text('红果 · 80 集'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture('television-focused');
        }
        await tester.pumpWidget(const SizedBox());
        if (startup != null) {
          startup.dispose();
        } else {
          downloads.dispose();
          store.dispose();
        }
      }
    }
    // Image decoding can complete after a preview is unmounted. Join it before
    // advancing CacheStore's scheduled database cleanup and closing the cache.
    final closing = Stopwatch()..start();
    while (tester.binding.imageCache.pendingImageCount > 0 &&
        closing.elapsed < const Duration(seconds: 10)) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    expect(tester.binding.imageCache.pendingImageCount, 0);
    await tester.pump(coverCache.store.cleanupRunMinInterval);
    await tester.runAsync(() async {
      await coverCache.dispose();
      await temporary!.delete(recursive: true);
    });
  }, skip: font == null);
}
