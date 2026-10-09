import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/settings_page.dart';
import 'package:guoguo_mobile/ui/storage_page.dart';
import 'package:guoguo_mobile/ui/playback_diagnostics_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'widget_test.dart' show NoNetwork;

class _CountingDownloads extends DownloadStore {
  _CountingDownloads(super.app) {
    manifestLoaded = true;
  }
  int scans = 0;
  int bytes = 1024;
  @override
  Future<void> refreshUsage() async {
    scans++;
  }

  @override
  int? bytesFor(Iterable<DownloadEntry> entries) => bytes;
  void updateUsage(int value) {
    bytes = value;
    notifyListeners();
  }
}

class _Picker extends FilePickerPlatform {
  int calls = 0;
  final selected = Completer<PlatformFile?>();
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    calls++;
    return selected.future;
  }
}

final class _PickedFile extends PlatformFile {
  _PickedFile(this.bytes);
  final Uint8List bytes;
  @override
  String get name => 'backup.json';
  @override
  Uri get uri => Uri.parse('memory:backup.json');
  @override
  XFile get xFile => XFile.fromData(bytes, name: name);
  @override
  int lengthSync() => bytes.length;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _FailedSave extends MemoryStorage {
  bool fail = false;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (fail) throw const FileSystemException('secret', '/private/records');
    await super.write(value);
  }
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: '果果',
      packageName: 'test',
      version: '1',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  Future<AppStore> mountSettings(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    GlobalKey? preview,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
    final downloads = _CountingDownloads(store);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: preview,
        child: ListenableBuilder(
          listenable: store.preferences.theme,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: guoguoTheme(Brightness.light),
            darkTheme: guoguoTheme(Brightness.dark),
            themeMode: store.preferences.themeMode,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: SettingsPage(store: store, downloads: downloads),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  Finder tile(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(ListTile));

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      await Directory('build/settings-previews').create(recursive: true);
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'build/settings-previews/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'small large-text settings keep theme and advanced actions reachable',
    (tester) async {
      final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
      if (font != null) {
        await tester.runAsync(() async {
          await (FontLoader('sans-serif')..addFont(
                Future.value(
                  ByteData.sublistView(await File(font).readAsBytes()),
                ),
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
      }
      final preview = GlobalKey();
      final store = await mountSettings(
        tester,
        size: const Size(320, 640),
        scale: 2,
        preview: preview,
      );
      expect(find.text('跟随系统').hitTestable(), findsOneWidget);
      expect(find.text('导入剧库 JSON / XZ'), findsNothing);
      expect(find.text('提前开播（实验）'), findsNothing);
      if (font != null) {
        await capture(tester, preview, 'appearance-320-large-light');
      }
      await tester.tap(find.widgetWithText(ChoiceChip, '深色'));
      await tester.pumpAndSettle();
      expect(store.preferences.themeMode, ThemeMode.dark);
      if (font != null) {
        await capture(tester, preview, 'appearance-320-large-dark');
      }
      for (final heading in ['播放与网络', '存储', '记录备份', '关于与支持', '高级工具']) {
        await tester.scrollUntilVisible(find.text(heading).hitTestable(), 200);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('高级工具'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('提前开播（实验）').hitTestable(), 160);
      final progressive = store.preferences.progressivePreparation;
      await tester.tap(find.text('提前开播（实验）'));
      await tester.pumpAndSettle();
      expect(store.preferences.progressivePreparation, !progressive);
      await tester.scrollUntilVisible(
        find.text('导入剧库 JSON / XZ').hitTestable(),
        200,
      );
      await tester.scrollUntilVisible(find.text('导出剧库 XZ').hitTestable(), 200);
      expect(tester.widget<ListTile>(tile('导出剧库 XZ')).enabled, isTrue);
      if (font != null) {
        await capture(tester, preview, 'exchange-320-large-dark');
        await tester.scrollUntilVisible(find.text('高级工具').hitTestable(), -160);
        await tester.pumpAndSettle();
        await capture(tester, preview, 'advanced-320-large-dark');
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'support entry opens copyable diagnostics without playback experiments',
    (tester) async {
      await mountSettings(tester);
      await tester.scrollUntilVisible(find.text('问题反馈与诊断').hitTestable(), 200);
      await tester.tap(find.text('问题反馈与诊断'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackDiagnosticsPage), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '复制诊断',
        ),
        findsOneWidget,
      );
      expect(find.text('提前开播（实验）'), findsNothing);
      expect(find.text('遇到播放问题时，可复制诊断并附在问题反馈中。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings has one storage entry leading to scoped management', (
    tester,
  ) async {
    await mountSettings(tester);
    await tester.scrollUntilVisible(find.text('存储管理').hitTestable(), 200);
    expect(find.text('清理封面缓存'), findsNothing);
    await tester.tap(find.text('存储管理'));
    // Verify navigation without waiting for real filesystem work in the
    // widget test's fake clock. Measurements have real-directory coverage.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(StoragePage), findsOneWidget);
    expect(find.text('下载文件'), findsOneWidget);
    expect(find.byTooltip('重新统计'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'library picker and record backup share a guard and cancellation releases it',
    (tester) async {
      final picker = _Picker(), original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      const path = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(path, (_) async => '/tmp');
      addTearDown(() => messenger.setMockMethodCallHandler(path, null));
      await mountSettings(tester);
      await tester.scrollUntilVisible(find.text('导入记录备份').hitTestable(), 200);
      final backup = tester.widget<ListTile>(tile('导入记录备份')).onTap!;
      await tester.scrollUntilVisible(find.text('高级工具').hitTestable(), 200);
      await tester.tap(find.text('高级工具'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('导入剧库 JSON / XZ').hitTestable(),
        200,
      );
      await tester.tap(find.text('导入剧库 JSON / XZ'));
      await tester.pump();
      backup();
      await tester.pump();
      expect(picker.calls, 1);
      expect(tester.widget<ListTile>(tile('导入剧库 JSON / XZ')).enabled, isFalse);
      picker.selected.complete(null);
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(tile('导入剧库 JSON / XZ')).enabled, isTrue);
      backup();
      await tester.pumpAndSettle();
      expect(picker.calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving settings during directory preparation suppresses a late picker',
    (tester) async {
      final picker = _Picker(), original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      const path = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final directory = Completer<String>();
      messenger.setMockMethodCallHandler(path, (_) => directory.future);
      addTearDown(() => messenger.setMockMethodCallHandler(path, null));
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _CountingDownloads(store);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SettingsPage(store: store, downloads: downloads),
                  ),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('高级工具').hitTestable(), 200);
      await tester.tap(find.text('高级工具'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('导入剧库 JSON / XZ').hitTestable(),
        200,
      );
      await tester.tap(find.text('导入剧库 JSON / XZ'));
      await tester.pump();
      expect(picker.calls, 0);
      await tester.pageBack();
      await tester.pumpAndSettle();
      directory.complete('/tmp');
      await tester.pumpAndSettle();
      expect(picker.calls, 0);
      expect(find.text('打开设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    Uint8List.fromList([0xff]),
    Uint8List.fromList(utf8.encode('{secret')),
  ]) {
    testWidgets(
      'invalid backup preserves records with a clear message ${invalid.first}',
      (tester) async {
        final picker = _Picker();
        final original = FilePickerPlatform.instance;
        FilePickerPlatform.instance = picker;
        addTearDown(() => FilePickerPlatform.instance = original);
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
        final downloads = _CountingDownloads(store);
        addTearDown(() {
          downloads.dispose();
          store.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsPage(store: store, downloads: downloads),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('导入记录备份').hitTestable(), 200);
        await tester.tap(find.text('导入记录备份'));
        picker.selected.complete(_PickedFile(invalid));
        await tester.pumpAndSettle();
        expect(find.text('备份损坏或格式不兼容，原记录未修改'), findsOneWidget);
        expect(find.textContaining('secret'), findsNothing);
        expect(store.records.favorites, isEmpty);
        expect(
          tester
              .widget<ListTile>(
                find.ancestor(
                  of: find.text('导入记录备份'),
                  matching: find.byType(ListTile),
                ),
              )
              .enabled,
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'backup blocks duplicate pickers, reports save failure and permits retry',
    (tester) async {
      final picker = _Picker();
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      final storage = _FailedSave();
      final store = AppStore(storage: storage, provider: NoNetwork());
      const existing = Drama(
        id: 'existing',
        source: DramaSource.hongguo,
        title: '原有收藏',
      );
      const incoming = Drama(
        id: 'incoming',
        source: DramaSource.hongguo,
        title: '导入收藏',
      );
      await store.records.toggleFavorite(existing);
      final downloads = _CountingDownloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(store: store, downloads: downloads),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('导入记录备份').hitTestable(), 200);
      await tester.tap(find.text('导入记录备份'));
      await tester.tap(find.text('导入记录备份'));
      await tester.pump();
      expect(picker.calls, 1);
      picker.selected.complete(
        _PickedFile(
          Uint8List.fromList(
            utf8.encode(jsonEncode(RecordBackup([incoming], []).toJson())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('合并记录备份'), findsOneWidget);
      storage.fail = true;
      await tester.tap(find.text('合并导入'));
      await tester.pumpAndSettle();
      expect(find.text('备份导入失败，原记录未修改，请稍后重试'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(store.records.favorites.keys, [existing.key]);
      storage.fail = false;
      await tester.tap(find.text('导入记录备份'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(picker.calls, 2);
      await tester.tap(find.text('合并导入'));
      await tester.pumpAndSettle();
      expect(
        store.records.favorites.keys,
        containsAll([existing.key, incoming.key]),
      );
      expect(store.persistenceError, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings uses installed version and avoids rescanning on theme changes',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: '果果',
        packageName: 'test',
        version: '2.3.4',
        buildNumber: '99',
        buildSignature: '',
      );
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final downloads = _CountingDownloads(store);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(store: store, downloads: downloads),
        ),
      );
      await tester.pumpAndSettle();
      await store.preferences.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('果果 · 2.3.4 (99)'), 300);
      expect(find.text('果果 · 2.3.4 (99)'), findsOneWidget);
      expect(downloads.scans, 1);
      await tester.scrollUntilVisible(find.textContaining('1.0 KB'), -200);
      downloads.updateUsage(0);
      await tester.pumpAndSettle();
      expect(find.text('0 B 下载 · 查看缓存与清理'), findsOneWidget);
      expect(downloads.scans, 1);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
}
