import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/settings_page.dart';
import 'widget_test.dart' show NoNetwork;

class _CountingDownloads extends DownloadStore {
  _CountingDownloads(super.app);
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
      expect(find.text('0 B · 在下载页按剧管理'), findsOneWidget);
      expect(downloads.scans, 1);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );
}
