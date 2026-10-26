import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/personal_page.dart';
import 'widget_test.dart' show NoNetwork;

const _drama = Drama(id: 'undo', source: DramaSource.hongguo, title: '原来的故事');
final _record = WatchRecord(
  drama: _drama,
  episodeId: 'episode-8',
  episodeIndex: 7,
  episodeNumber: 8,
  positionMs: 12000,
  durationMs: 60000,
  updatedAt: DateTime.utc(2026, 10, 1),
);

class _Storage extends MemoryStorage {
  Completer<void>? gate;
  final entered = Completer<void>();
  bool fail = false;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (gate case final pending?) {
      if (!entered.isCompleted) entered.complete();
      await pending.future;
    }
    if (fail) throw StateError('full disk');
    await super.write(value);
  }
}

AppStore _store([MemoryStorage? storage]) {
  final app = AppStore(
    storage: storage ?? MemoryStorage(),
    provider: NoNetwork(),
  )..offline = true;
  app.records.restore(RecordBackup([_drama], [_record]), {});
  return app;
}

void main() {
  for (final favorite in [false, true]) {
    for (final fail in [false, true]) {
      test(
        'undo ${favorite ? 'favorite' : 'history'} installs only after a successful save fail=$fail',
        () async {
          final storage = _Storage();
          final app = _store(storage);
          addTearDown(app.dispose);
          final records = app.records;
          if (favorite) {
            await records.toggleFavorite(_drama);
          } else {
            await records.removeHistory(_drama.key);
          }
          storage.gate = Completer<void>();
          storage.fail = fail;
          final restoring = favorite
              ? records.restoreFavorite(_drama)
              : records.restoreHistory(_record);
          final failure = fail
              ? expectLater(restoring, throwsStateError)
              : null;
          await storage.entered.future;
          expect(
            favorite
                ? records.favorites.containsKey(_drama.key)
                : records.history.containsKey(_drama.key),
            false,
          );
          storage.gate!.complete();
          if (failure != null) {
            await failure;
            expect(
              favorite
                  ? records.favorites.containsKey(_drama.key)
                  : records.history.containsKey(_drama.key),
              false,
            );
            storage.gate = null;
            storage.fail = false;
            await (favorite
                ? records.restoreFavorite(_drama)
                : records.restoreHistory(_record));
          } else {
            await restoring;
          }
          expect(
            favorite
                ? records.favorites.containsKey(_drama.key)
                : records.history.containsKey(_drama.key),
            true,
          );
          final restored = AppStore(storage: storage, provider: NoNetwork());
          addTearDown(restored.dispose);
          await restored.load();
          if (favorite) {
            expect(restored.records.favorites[_drama.key]!.title, _drama.title);
          } else {
            expect(
              restored.records.history[_drama.key]!.toJson(),
              _record.toJson(),
            );
          }
        },
      );
    }
  }

  test(
    'undo preserves newer progress and a newer favorite of the same identity',
    () async {
      final app = _store();
      addTearDown(app.dispose);
      final newer = WatchRecord(
        drama: _drama,
        episodeId: 'episode-9',
        episodeIndex: 8,
        positionMs: 30000,
        durationMs: 60000,
        updatedAt: DateTime.utc(2026, 10, 26),
      );
      await app.records.removeHistory(_drama.key);
      await app.records.saveWatch(newer);
      await app.records.restoreHistory(_record);
      expect(app.records.history[_drama.key], same(newer));
      const updated = Drama(
        id: 'undo',
        source: DramaSource.hongguo,
        title: '更新后的故事',
      );
      await app.records.toggleFavorite(_drama);
      await app.records.toggleFavorite(updated);
      await app.records.restoreFavorite(_drama);
      expect(app.records.favorites[_drama.key]!.title, updated.title);
    },
  );

  for (final history in [false, true]) {
    testWidgets(
      'personal ${history ? 'history' : 'favorite'} removal offers undo',
      (tester) async {
        final app = _store();
        final downloads = DownloadStore(app);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          downloads.dispose();
          app.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PersonalPage(store: app, downloads: downloads),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (history) {
          await tester.tap(find.text('历史 1'));
          await tester.pumpAndSettle();
        }
        final row = find.byKey(ValueKey('personal:${_drama.key}'));
        final remove = find.descendant(
          of: row,
          matching: find.byTooltip(history ? '删除历史' : '取消收藏'),
        );
        await tester.ensureVisible(remove);
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(history ? app.records.history : app.records.favorites, isEmpty);
        expect(find.text('撤销').hitTestable(), findsOneWidget);
        await tester.tap(find.text('撤销'));
        await tester.pumpAndSettle();
        expect(app.records.favorites[_drama.key], _drama);
        expect(app.records.history[_drama.key], same(_record));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed undo offers retry and leaves the deleted record absent', (
    tester,
  ) async {
    final storage = _Storage();
    final app = _store(storage);
    final downloads = DownloadStore(app);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      app.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PersonalPage(store: app, downloads: downloads),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final remove = find.byTooltip('取消收藏');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    storage.fail = true;
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(app.records.favorites, isEmpty);
    expect(find.text('撤销未完成，请检查设备空间后重试'), findsOneWidget);
    storage.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(app.records.favorites[_drama.key], _drama);
    expect(app.records.history[_drama.key], same(_record));
    expect(tester.takeException(), isNull);
  });
}
