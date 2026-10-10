import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _NoNetwork implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw StateError('unexpected request');
}

Map<String, dynamic> _cache(int page) => {
  'pages': {'hongguo': page},
};

int _page(Object? value) =>
    ((value as Map)['cache']['pages'] as Map)['hongguo'] as int;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('guoguo-cache-queue-');
  });
  tearDown(() => directory.delete(recursive: true));
  File file(String name) => File('${directory.path}/$name');
  Future<int> savedPage() async =>
      _page(jsonDecode(await file('catalog-cache.json').readAsString()));

  test(
    'a synchronous burst captures and commits its latest snapshot once',
    () async {
      var captures = 0, encodes = 0;
      final storage = AppFileStorage(
        directory,
        encodeCache: (value) async {
          encodes++;
          return jsonEncode(value);
        },
      );
      final saves = [
        for (var page = 1; page <= 5; page++)
          storage.writeCacheSnapshot(() {
            captures++;
            return _cache(page);
          }),
      ];
      await Future.wait(saves);
      expect(captures, 1);
      expect(encodes, 1);
      expect(await savedPage(), 5);
    },
  );

  test('writes arriving during IO wait for their own latest commit', () async {
    final firstStarted = Completer<void>(), secondStarted = Completer<void>();
    final firstGate = Completer<void>(), secondGate = Completer<void>();
    final pages = <int>[];
    var captures = 0, finished = 0;
    final storage = AppFileStorage(
      directory,
      encodeCache: (value) async {
        pages.add(_page(value));
        if (pages.length == 1) {
          firstStarted.complete();
          await firstGate.future;
        } else {
          secondStarted.complete();
          await secondGate.future;
        }
        return jsonEncode(value);
      },
    );
    Future<void> save(int page) => storage.writeCacheSnapshot(() {
      captures++;
      return _cache(page);
    });
    final first = save(1);
    await firstStarted.future;
    final later = [
      for (var page = 2; page <= 5; page++) save(page).then((_) => finished++),
    ];
    firstGate.complete();
    await first;
    await secondStarted.future;
    expect(await savedPage(), 1);
    expect(finished, 0);
    expect(captures, 2);
    expect(pages, [1, 5]);
    secondGate.complete();
    await Future.wait(later);
    expect(finished, 4);
    expect(await savedPage(), 5);
  });

  test(
    'public map writes detach nested inputs before queued coalescing',
    () async {
      final storage = AppFileStorage(directory);
      final first = _cache(1), latest = _cache(2);
      final saves = [storage.writeCache(first), storage.writeCache(latest)];
      (first['pages'] as Map)['hongguo'] = 90;
      (latest['pages'] as Map)['hongguo'] = 99;
      await Future.wait(saves);
      expect(await savedPage(), 2);
    },
  );

  test(
    'clear separates pending writes from new use and preserves records',
    () async {
      final firstStarted = Completer<void>(), thirdStarted = Completer<void>();
      final firstGate = Completer<void>(), thirdGate = Completer<void>();
      final pages = <int>[];
      final storage = AppFileStorage(
        directory,
        encodeCache: (value) async {
          final page = _page(value);
          pages.add(page);
          if (page == 1) {
            firstStarted.complete();
            await firstGate.future;
          } else if (page == 3) {
            thirdStarted.complete();
            await thirdGate.future;
          }
          return jsonEncode(value);
        },
      );
      await storage.writeRecords({
        'records': {
          'history': ['kept'],
        },
      });
      final records = await file('records.json').readAsBytes();
      final first = storage.writeCache(_cache(1));
      await firstStarted.future;
      final second = storage.writeCache(_cache(2));
      final clearing = storage.clearCatalogCache();
      final third = storage.writeCache(_cache(3));
      firstGate.complete();
      await clearing;
      await thirdStarted.future;
      expect(await file('catalog-cache.json').exists(), false);
      expect(await file('records.json').readAsBytes(), records);
      thirdGate.complete();
      await Future.wait([first, second, third]);
      expect(pages, [1, 2, 3]);
      expect(await savedPage(), 3);
    },
  );

  test(
    'size measurement cannot absorb a later save ahead of its barrier',
    () async {
      final started = Completer<void>(), laterStarted = Completer<void>();
      final gate = Completer<void>(), laterGate = Completer<void>();
      String? measuredJson;
      final storage = AppFileStorage(
        directory,
        encodeCache: (value) async {
          if (_page(value) == 1) {
            started.complete();
            await gate.future;
          } else if (_page(value) == 22) {
            measuredJson = jsonEncode(value);
          } else {
            laterStarted.complete();
            await laterGate.future;
          }
          return jsonEncode(value);
        },
      );
      final first = storage.writeCache(_cache(1));
      await started.future;
      final second = storage.writeCache(_cache(22));
      final measuring = storage.catalogCacheBytes();
      final last = storage.writeCache(_cache(333));
      gate.complete();
      expect(await measuring, utf8.encode(measuredJson!).length);
      await laterStarted.future;
      expect(await savedPage(), 22);
      laterGate.complete();
      await Future.wait([first, second, last]);
      expect(await savedPage(), 333);
    },
  );

  test(
    'capture failure rejects the entire waiting batch and permits retry',
    () async {
      final storage = AppFileStorage(directory);
      await storage.writeCache(_cache(1));
      final first = storage.writeCacheSnapshot(() => _cache(2));
      final second = storage.writeCacheSnapshot(
        () => throw StateError('capture failed'),
      );
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(await savedPage(), 1);
      await storage.writeCacheSnapshot(() => _cache(3));
      expect(await savedPage(), 3);
    },
  );

  test(
    'atomic cache failure keeps committed records and reports all waiters',
    () async {
      final storage = AppFileStorage(directory);
      final store = AppStore(storage: storage, provider: _NoNetwork());
      addTearDown(store.dispose);
      await store.persist();
      final previous = await file('catalog-cache.json').readAsBytes();
      final obstacle = await Directory(
        '${directory.path}/catalog-cache.json.tmp',
      ).create();
      store.catalog.catalogPages[DramaSource.hongguo] = 9;
      await Future.wait([
        for (var i = 0; i < 3; i++)
          expectLater(
            store.persist(records: false),
            throwsA(isA<FileSystemException>()),
          ),
      ]);
      expect(store.cachePersistenceError, isNotNull);
      expect(store.persistenceError, isNull);
      expect(await file('catalog-cache.json').readAsBytes(), previous);
      await obstacle.delete();
      await store.persist(records: false);
      expect(store.cachePersistenceError, isNull);
      final restored = AppStore(
        storage: AppFileStorage(directory),
        provider: _NoNetwork(),
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.catalog.catalogPages[DramaSource.hongguo], 9);
    },
  );

  test(
    'records stay independent and an awaited cache save survives disposal',
    () async {
      final started = Completer<void>(), gate = Completer<void>();
      final storage = AppFileStorage(
        directory,
        encodeCache: (value) async {
          started.complete();
          await gate.future;
          return jsonEncode(value);
        },
      );
      final store = AppStore(storage: storage, provider: _NoNetwork());
      await store.persist(cache: false);
      const drama = Drama(id: 'a', source: DramaSource.hongguo, title: '保留资料');
      store.catalog.catalogs[DramaSource.hongguo] = [drama];
      final saving = store.persist(records: false);
      await started.future;
      await store.records
          .toggleFavorite(drama)
          .timeout(const Duration(seconds: 2));
      expect(gate.isCompleted, false);
      store.dispose();
      gate.complete();
      await saving;
      final restored = AppStore(
        storage: AppFileStorage(directory),
        provider: _NoNetwork(),
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.records.favorites[drama.key]!.title, drama.title);
      expect(restored.catalog.library.single.title, drama.title);
    },
  );

  test(
    'ordinary file writes preserve every queued document in order',
    () async {
      final observed = <int>[];
      final storage = FileStorage(
        directory,
        fileName: 'download-manifest.json',
        encode: (value) async {
          observed.add((value as Map)['revision'] as int);
          return jsonEncode(value);
        },
      );
      await Future.wait([
        for (var revision = 1; revision <= 5; revision++)
          storage.write({'revision': revision}),
      ]);
      expect(observed, [1, 2, 3, 4, 5]);
      expect((await storage.read())!['revision'], 5);
    },
  );

  test(
    'a failed shared import save rolls back only the import, keeping later rows',
    () async {
      final started = Completer<void>(), gate = Completer<void>();
      var encodes = 0;
      final storage = AppFileStorage(
        directory,
        encodeCache: (value) async {
          encodes++;
          if (encodes == 1) {
            started.complete();
            await gate.future;
          } else if (encodes == 2) {
            throw const FileSystemException('cache save failed');
          }
          return jsonEncode(value);
        },
      );
      final store = AppStore(storage: storage, provider: _NoNetwork());
      addTearDown(store.dispose);
      await store.persist(cache: false);
      final first = store.persist(records: false);
      await started.future;
      const imported = Drama(
        id: 'imported',
        source: DramaSource.hongguo,
        title: '导入',
      );
      const later = Drama(
        id: 'later',
        source: DramaSource.hongguo,
        title: '后来获取',
      );
      final importing = expectLater(
        store.catalog.importLibraryRows([imported]),
        throwsA(isA<FileSystemException>()),
      );
      final updating = store.catalog.saveRecommendations([later]);
      gate.complete();
      await Future.wait([first, importing, updating]);
      expect(
        store.catalog.library.map((d) => d.key),
        isNot(contains(imported.key)),
      );
      expect(store.catalog.catalogs[DramaSource.hongguo]!.map((d) => d.key), [
        later.key,
      ]);
      await store.persist(records: false);
      final restored = AppStore(
        storage: AppFileStorage(directory),
        provider: _NoNetwork(),
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(
        restored.catalog.catalogs[DramaSource.hongguo]!.map((d) => d.key),
        [later.key],
      );
      expect(store.cachePersistenceError, isNull);
    },
  );
}
