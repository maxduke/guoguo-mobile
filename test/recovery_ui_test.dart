import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/startup_record_recovery.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/user_input_exception.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/record_recovery_page.dart';

import 'widget_test.dart' show NoNetwork;

class _Downloads extends DownloadStore {
  _Downloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}

class _Storage extends MemoryStorage {
  bool fail = true;
  int writes = 0;
  Completer<void>? gate;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
    await gate?.future;
    if (fail) throw const FileSystemException('disk full private path');
    await super.write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(
    id: 'saved',
    source: DramaSource.hongguo,
    title: '保留收藏意图',
  );
  final backup = RecordBackup([drama], []);
  late Directory root;
  late File original;
  late StartupRecordRecovery recovery;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('record-recovery-ui-');
    original = await File(
      '${root.path}/records.json',
    ).writeAsString('damaged record');
    recovery = StartupRecordRecovery(AppFileStorage(root));
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> openRecovery(
    WidgetTester tester, {
    Future<RecordBackup?> Function()? select,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => RecordRecoveryPage(
                    recovery: recovery,
                    selectBackup: select ?? () async => backup,
                    shareOriginal: (_, file) async {
                      expect(await file.readAsString(), 'damaged record');
                    },
                  ),
                ),
              ),
              child: const Text('打开恢复'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开恢复'));
    await tester.pumpAndSettle();
  }

  Future<void> finishFileOperation(WidgetTester tester) async {
    // File IO and the JSON worker advance on the real event loop; frames and
    // notifier continuations advance on the widget test's clock.
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Recovery file operation did not finish');
  }

  testWidgets(
    'backup picker cancellation and preview cancellation leave the original untouched',
    (tester) async {
      await openRecovery(tester, select: () async => null);
      await tester.tap(find.text('选择记录备份'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(original.readAsString), 'damaged record');
      expect(
        await tester.runAsync(
          () => Directory('${root.path}/recovery').exists(),
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await openRecovery(tester);
      await tester.tap(find.text('选择记录备份'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 部收藏'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(original.readAsString), 'damaged record');
      expect(
        await tester.runAsync(
          () => Directory('${root.path}/recovery').exists(),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'confirmed recovery preserves the file and returns to retry startup',
    (tester) async {
      await openRecovery(tester);
      await tester.tap(find.text('选择记录备份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留原文件并恢复'));
      await finishFileOperation(tester);
      expect(find.text('打开恢复'), findsOneWidget);
      expect(find.byType(RecordRecoveryPage), findsNothing);
      expect(
        await tester.runAsync(original.readAsString),
        contains('guoguo.records'),
      );
      final copy =
          (await tester.runAsync(
                () => Directory(
                  '${root.path}/recovery',
                ).list(recursive: true).where((e) => e is File).toList(),
              ))!.single
              as File;
      expect(await tester.runAsync(copy.readAsString), 'damaged record');
    },
  );

  testWidgets(
    'invalid backup and failed recovery keep actions available without exposing paths',
    (tester) async {
      await openRecovery(
        tester,
        select: () async => throw const UserInputException('备份损坏或格式不兼容，原记录未修改'),
      );
      await tester.tap(find.text('选择记录备份'));
      await tester.pumpAndSettle();
      expect(find.text('备份损坏或格式不兼容，原记录未修改'), findsOneWidget);
      expect(await tester.runAsync(original.readAsString), 'damaged record');
      await tester.runAsync(() => Directory('${original.path}.tmp').create());
      await tester.tap(find.text('保留原文件，重新建立记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留原文件并重新建立'));
      await finishFileOperation(tester);
      expect(find.textContaining('恢复操作未完成'), findsOneWidget);
      expect(find.textContaining(root.path), findsNothing);
      expect(await tester.runAsync(original.readAsString), 'damaged record');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '选择记录备份'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'bootstrap follows system dark mode and scrolls in a short large-text window',
    (tester) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        Bootstrap(load: () async => throw RecordLoadFailure(recovery)),
      );
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('果果'))).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('记录恢复'));
      await tester.tap(find.text('记录恢复'));
      await tester.pumpAndSettle();
      expect(find.byType(RecordRecoveryPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'retry save commits the existing intent once without networking',
    (tester) async {
      final storage = _Storage();
      final store = AppStore(storage: storage, provider: NoNetwork())
        ..offline = true;
      final downloads = _Downloads(store);
      addTearDown(downloads.dispose);
      addTearDown(store.dispose);
      await expectLater(
        store.records.toggleFavorite(drama),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.records.favorites.containsKey(drama.key), isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, downloads: downloads, autoLoad: false),
        ),
      );
      await tester.pumpAndSettle();
      storage.fail = false;
      storage.gate = Completer<void>();
      final before = storage.writes;
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      expect(find.text('正在保存记录…'), findsOneWidget);
      expect(find.text('重试保存'), findsNothing);
      expect(storage.writes, before + 1);
      storage.gate!.complete();
      await tester.pumpAndSettle();
      expect(store.persistenceError, isNull);
      expect(store.records.favorites.containsKey(drama.key), isTrue);
      expect(
        (storage.value!['records']['favorites'] as List).single['id'],
        drama.id,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
