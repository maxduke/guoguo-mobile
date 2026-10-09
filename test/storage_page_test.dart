import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/storage_manager.dart';
import 'package:guoguo_mobile/platform/playback_temporary_files.dart';
import 'package:guoguo_mobile/ui/storage_page.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'widget_test.dart' show NoNetwork;

const _usage = StorageUsage(
  downloadBytes: 1024,
  playback: PlaybackFileUsage(activeBytes: 2048, unusedBytes: 4096),
  coverBytes: null,
  catalogBytes: 0,
);

class _Manager extends StorageManager {
  _Manager(super.store, super.downloads);
  int scans = 0, cleanups = 0;
  StorageUsage usage = _usage;
  Completer<StorageUsage>? measurement;
  Completer<void>? cleaning;
  bool fail = false;
  @override
  bool get canClearCatalog => true;
  @override
  Future<StorageUsage> measure() async {
    scans++;
    return measurement == null ? usage : measurement!.future;
  }

  @override
  Future<void> clearCatalog() async {
    cleanups++;
    await cleaning?.future;
    if (fail) throw StateError('private failure with secret path');
  }
}

void main() {
  late AppStore store;
  late DownloadStore downloads;
  late _Manager manager;
  setUp(() {
    store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
    downloads = DownloadStore(store);
    manager = _Manager(store, downloads);
  });
  tearDown(() {
    downloads.dispose();
    store.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    _Manager? owner,
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
    GlobalKey? preview,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: guoguoTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: preview,
          child: StoragePage(
            store: store,
            downloads: downloads,
            manager: owner ?? manager,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<VoidCallback> catalogAction(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('清理目录缓存'), 180);
    return tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '清理目录缓存'))
        .onPressed!;
  }

  testWidgets(
    'busy cleanup rejects duplicate callbacks and preserves scopes on failure',
    (tester) async {
      await mount(tester);
      final callback = await catalogAction(tester);
      manager.cleaning = Completer<void>();
      callback();
      callback();
      await tester.pump();
      expect(manager.cleanups, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '清理目录缓存'),
            )
            .onPressed,
        isNull,
      );
      manager.fail = true;
      manager.cleaning!.complete();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('清理未完成，请检查可用空间后重试'), -180);
      expect(find.textContaining('private failure'), findsNothing);
      expect(manager.scans, 1);
      expect(find.text('1.0 KB'), findsOneWidget);
      manager.fail = false;
      final retry = await catalogAction(tester);
      retry();
      await tester.pumpAndSettle();
      expect(manager.cleanups, 2);
      expect(manager.scans, 2);
      expect(find.text('清理完成，已重新统计占用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dependency replacement rejects old callbacks and pending cleanup results',
    (tester) async {
      await mount(tester);
      final callback = await catalogAction(tester);
      manager.cleaning = Completer<void>();
      callback();
      final next = _Manager(store, downloads)
        ..usage = const StorageUsage(
          downloadBytes: 9,
          playback: PlaybackFileUsage(activeBytes: 0, unusedBytes: 0),
          coverBytes: 0,
          catalogBytes: 0,
        );
      await mount(tester, owner: next);
      callback();
      manager.cleaning!.complete();
      await tester.pumpAndSettle();
      expect(manager.cleanups, 1);
      expect(manager.scans, 1);
      expect(next.cleanups, 0);
      expect(next.scans, 1);
      expect(find.text('清理完成，已重新统计占用'), findsNothing);
      await tester.scrollUntilVisible(find.text('下载文件'), -180);
      expect(find.text('9 B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late measurement after unmount has no state updates or feedback',
    (tester) async {
      manager.measurement = Completer<StorageUsage>();
      await mount(tester);
      await tester.pumpWidget(const SizedBox());
      manager.measurement!.complete(_usage);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a covered page rejects saved cleanup callbacks', (tester) async {
    await mount(tester);
    final callback = await catalogAction(tester);
    final context = tester.element(find.byType(StoragePage));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('another route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    callback();
    await tester.pump();
    expect(manager.cleanups, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'download management opens the existing page and remeasures on return',
    (tester) async {
      downloads.initialized = true;
      await mount(tester);
      await tester.tap(find.text('管理下载'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadsPage), findsOneWidget);
      expect(find.widgetWithText(AppBar, '下载'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      manager.usage = const StorageUsage(
        downloadBytes: 7,
        playback: PlaybackFileUsage(activeBytes: 0, unusedBytes: 0),
        coverBytes: 0,
        catalogBytes: 0,
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(manager.scans, 2);
      expect(find.text('7 B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final sample in [
    ('phone', const Size(390, 844), 1.0, Brightness.light),
    ('small-large-dark', const Size(320, 640), 2.0, Brightness.dark),
    ('landscape-large', const Size(844, 390), 2.0, Brightness.light),
    ('tablet', const Size(1024, 768), 1.0, Brightness.dark),
  ]) {
    testWidgets('storage scope controls remain reachable at ${sample.$1}', (
      tester,
    ) async {
      await mount(
        tester,
        size: sample.$2,
        scale: sample.$3,
        brightness: sample.$4,
      );
      expect(find.text('1.0 KB'), findsOneWidget);
      for (final label in ['管理下载', '清理闲置播放文件', '清理封面缓存', '清理目录缓存']) {
        await tester.scrollUntilVisible(find.text(label).hitTestable(), 120);
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(find.text('0 B'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('暂无法统计'), -120);
      expect(find.text('暂无法统计'), findsOneWidget);
      expect(find.byTooltip('重新统计'), findsOneWidget);
    });
  }

  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture Chinese storage layouts', skip: font == null, (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fontLoader = FontLoader('sans-serif')
        ..addFont(
          Future.value(ByteData.sublistView(await File(font!).readAsBytes())),
        );
      await fontLoader.load();
      final icon = Platform.environment['GUOGUO_ICON_FONT'];
      if (icon != null) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(icon).readAsBytes()),
              ),
            ))
            .load();
      }
    });
    for (final sample in [
      ('phone', const Size(390, 844), 1.0, Brightness.light),
      ('small-large-dark', const Size(320, 640), 2.0, Brightness.dark),
      ('landscape-large', const Size(844, 390), 2.0, Brightness.light),
      ('tablet', const Size(1024, 768), 1.0, Brightness.dark),
    ]) {
      final key = GlobalKey();
      await mount(
        tester,
        size: sample.$2,
        scale: sample.$3,
        brightness: sample.$4,
        preview: key,
      );
      await tester.pumpAndSettle();
      for (final section in ['下载文件', '目录与分集缓存']) {
        await tester.scrollUntilVisible(
          find.text(section),
          section == '下载文件' ? -180 : 180,
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/storage-previews').create(recursive: true);
          await File(
            'build/storage-previews/${sample.$1}-$section.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
    }
  });
}
