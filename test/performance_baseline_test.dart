import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/domain/catalog_query.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/downloads_page.dart';
import 'package:guoguo_mobile/ui/library_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';

// Opt-in measurements, never timing thresholds in ordinary CI.
const _samples = 5;
final _at = DateTime.utc(2026, 10, 9);
final _report = <String, dynamic>{};
Object? _sink;

class _NoNetwork implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw StateError('Benchmark attempted provider request: $method');
}

// Render grouping/progress only; exclude native recovery and filesystem scans.
class _RenderDownloads extends DownloadStore {
  _RenderDownloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}

Map<String, dynamic> _fixture(int count, int history, {bool covers = true}) {
  final empty = AppStore(storage: MemoryStorage(), provider: _NoNetwork());
  final state = empty.snapshot();
  empty.dispose();
  final dramas = [
    for (var i = 0; i < count; i++)
      Drama(
        id: 'hongguo:fixture-$i',
        source: DramaSource.hongguo,
        title: '合成短剧 $i 第${i % 9 + 1}季',
        description: List.filled(16, '合成简介用于测量目录载荷，不是真实作品。').join(),
        cover: covers ? 'https://fixtures.invalid/covers/$i.jpg' : '',
        category: i.isEven ? '爱情' : '都市',
        tags: const ['剧情', '短剧'],
        episodes: 40,
        date: '2026-10-${(i % 28 + 1).toString().padLeft(2, '0')}',
        heat: '${i % 100}万',
      ),
  ];
  final rows = dramas.map((drama) => drama.toJson()).toList();
  state['catalogs'] = {'hongguo': rows};
  state['categorySlices'] = {
    'hongguo|': {'items': rows, 'page': (count / 50).ceil(), 'more': false},
  };
  state['pages'] = {'hongguo': (count / 50).ceil()};
  state['hasMore'] = {'hongguo': false};
  state['episodes'] = {
    for (final drama in dramas.take(50))
      drama.key: [
        for (var i = 0; i < 40; i++)
          {
            'id': '${drama.id}:$i',
            'title': '第 ${i + 1} 集',
            'currentEpisode': '${i + 1}',
            'vip': false,
          },
      ],
  };
  state['records'] = RecordBackup(dramas.take(history).toList(), [
    for (final drama in dramas.take(history))
      WatchRecord(
        drama: drama,
        episodeId: '${drama.id}:0',
        episodeIndex: 0,
        episodeNumber: 1,
        positionMs: 10000,
        durationMs: 60000,
        updatedAt: _at,
      ),
  ]).toJson();
  return state;
}

Map<String, dynamic> _summary(List<double> values, int iterations) {
  final sorted = values.toList()..sort();
  return {
    'medianUsPerOperation': sorted[sorted.length ~/ 2],
    'samplesUsPerOperation': values,
    'iterationsPerSample': iterations,
    'warmups': 1,
  };
}

Map<String, dynamic> _sync(Object? Function() operation, {int iterations = 1}) {
  final values = <double>[];
  for (var sample = -1; sample < _samples; sample++) {
    final clock = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      _sink = operation();
    }
    clock.stop();
    if (sample >= 0) values.add(clock.elapsedMicroseconds / iterations);
  }
  return _summary(values, iterations);
}

Future<Map<String, dynamic>> _async(Future<void> Function() operation) async {
  final values = <double>[];
  for (var sample = -1; sample < _samples; sample++) {
    final clock = Stopwatch()..start();
    await operation();
    clock.stop();
    if (sample >= 0) values.add(clock.elapsedMicroseconds.toDouble());
  }
  return _summary(values, 1);
}

Future<Map<String, int>> _readWithHeartbeat(
  Future<void> Function() operation,
) async {
  final clock = Stopwatch()..start();
  var previous = 0, longestGap = 0, ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
    final now = clock.elapsedMicroseconds;
    longestGap = max(longestGap, now - previous);
    previous = now;
    ticks++;
  });
  try {
    await operation();
    clock.stop();
    // Include the tail even if decoding returns before a delayed timer fires.
    longestGap = max(longestGap, clock.elapsedMicroseconds - previous);
    return {
      'wallUs': clock.elapsedMicroseconds,
      'maxEventLoopGapUs': longestGap,
      'timerTicks': ticks,
    };
  } finally {
    timer.cancel();
  }
}

// Reproduce the pre-0.19.3 reader as an interleaved control using identical bytes.
Future<Map<String, dynamic>?> _readOnCurrentIsolate(File file) async {
  if (!await file.exists()) return null;
  return Map<String, dynamic>.from(
    jsonDecode(await file.readAsString()) as Map,
  );
}

Future<void> _write(String path) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(_report));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['GUOGUO_PERF_OUTPUT'];
  test(
    'synthetic file read responsiveness baseline',
    () async {
      _report['readEnvironment'] = {
        'os': Platform.operatingSystemVersion,
        'dart': Platform.version,
        'debug': kDebugMode,
        'logicalProcessors': Platform.numberOfProcessors,
        'measuredAt': DateTime.now().toUtc().toIso8601String(),
        'samples': _samples,
        'warmups': 1,
        'timerPeriodMs': 2,
        'scope':
            'Synthetic debug host, warm OS cache; file/UTF-8/JSON read only. '
            'Event-loop timer intervals are not device frames. '
            'Excludes business object restoration, UI and network.',
      };
      final reads = <Map<String, dynamic>>[];
      for (final count in [100, 1000, 10000]) {
        final root = await Directory.systemTemp.createTemp('guoguo-read-perf-');
        try {
          await AppFileStorage(root).write(_fixture(count, 100));
          for (final fileName in ['records.json', 'catalog-cache.json']) {
            final file = File('${root.path}/$fileName');
            final storage = FileStorage(root, fileName: fileName);
            final samples = <String, List<Map<String, int>>>{
              'currentIsolateControl': [],
              'backgroundFileStorage': [],
            };
            final readers = <String, Future<Map<String, dynamic>?> Function()>{
              'currentIsolateControl': () => _readOnCurrentIsolate(file),
              'backgroundFileStorage': storage.read,
            };
            for (var sample = -1; sample < _samples; sample++) {
              final order = sample.isEven
                  ? readers.keys
                  : readers.keys.toList().reversed;
              for (final name in order) {
                Map<String, dynamic>? value;
                final measured = await _readWithHeartbeat(() async {
                  value = await readers[name]!();
                });
                // Validate returned contents outside the measured interval.
                if (fileName == 'records.json') {
                  expect(
                    (value!['records'] as Map)['favorites'],
                    hasLength(100),
                  );
                } else {
                  expect(value!['format'], 'guoguo.catalog-cache');
                  final cache = value!['cache'] as Map;
                  expect(
                    (cache['catalogs'] as Map)['hongguo'],
                    hasLength(count),
                  );
                }
                if (sample >= 0) samples[name]!.add(measured);
              }
            }
            reads.add({
              'catalogCount': count,
              'historyAndFavoritesCount': 100,
              'fileName': fileName,
              'fileBytes': await file.length(),
              ...samples,
            });
            _report['storageReads'] = reads;
            await _write(output!);
          }
        } finally {
          await root.delete(recursive: true);
        }
      }
    },
    skip: output == null
        ? 'Set GUOGUO_PERF_OUTPUT for host measurements'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'synthetic catalog and partitioned disk baseline',
    () async {
      _report['environment'] = {
        'os': Platform.operatingSystemVersion,
        'dart': Platform.version,
        'debug': kDebugMode,
        'logicalProcessors': Platform.numberOfProcessors,
        'measuredAt': DateTime.now().toUtc().toIso8601String(),
        'samples': _samples,
        'scope':
            'Synthetic debug host; warm OS cache. No provider, device video, image decoding or energy measurements.',
      };
      final workloads = <Map<String, dynamic>>[];
      for (final (count, history) in [
        (1000, 100),
        (10000, 100),
        (10000, 1000),
      ]) {
        final root = await Directory.systemTemp.createTemp('guoguo-perf-');
        final storage = AppFileStorage(root);
        await storage.write(_fixture(count, history));
        final app = AppStore(storage: storage, provider: _NoNetwork());
        try {
          await app.load();
          expect(app.catalog.library.length, count);
          expect(app.records.history.length, history);
          final missing = const Drama(
            id: 'missing',
            source: DramaSource.hongguo,
            title: 'missing',
          );
          final metrics = <String, dynamic>{
            'catalogCount': count,
            'historyAndFavoritesCount': history,
            'cachedEpisodes': 2000,
            'lookupFirst': _sync(
              () => app.catalog.currentDrama(app.catalog.library.first),
              iterations: 100,
            ),
            'lookupLast': _sync(
              () => app.catalog.currentDrama(app.catalog.library.last),
              iterations: 100,
            ),
            'lookupMissing': _sync(
              () => app.catalog.currentDrama(missing),
              iterations: 100,
            ),
            'cachedUnion': _sync(
              () => app.catalog.cachedDramas(DramaSource.hongguo),
              iterations: 10,
            ),
            'queryEmpty': _sync(() => queryCatalog(app.catalog.library)),
            'queryWords': _sync(
              () => queryCatalog(app.catalog.library, query: '合成 3'),
            ),
            'queryTitleSort': _sync(
              () => queryCatalog(app.catalog.library, sort: CatalogSort.title),
            ),
            'cacheEncode': _sync(
              () => utf8.encode(jsonEncode(app.catalog.cacheSnapshot())),
            ),
            'recordWrite': await _async(() => app.persist(cache: false)),
            'cacheWrite': await _async(() => app.persist(records: false)),
            'cacheWriteBurst5': await _async(() async {
              await Future.wait([
                for (var i = 0; i < 5; i++) app.persist(records: false),
              ]);
            }),
            'diskReadAndRestore': await _async(() async {
              final restored = AppStore(
                storage: storage,
                provider: _NoNetwork(),
              );
              try {
                await restored.load();
                expect(restored.catalog.library.length, count);
              } finally {
                restored.dispose();
              }
            }),
            'cacheFileBytes': await File(
              '${root.path}/catalog-cache.json',
            ).length(),
            'recordFileBytes': await File('${root.path}/records.json').length(),
            // Entire process, including Flutter and previous workloads; not a cache heap delta.
            'processRssBytes': ProcessInfo.currentRss,
          };
          workloads.add(metrics);
          _report['data'] = workloads;
          await _write(output!);
          expect(_sink, isNotNull);
        } finally {
          app.dispose();
          await root.delete(recursive: true);
        }
      }
      _report['data'] = workloads;
      await _write(output!);
    },
    skip: output == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets('synthetic first-viewport rendering and lazy widget counts', (
    tester,
  ) async {
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('guoguo-perf-render-'),
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => temporary!.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.runAsync(
      () => coverCache.getFileFromCache('performance-initialization'),
    );
    var cacheDisposed = false;
    Future<void> closeCache() async {
      if (cacheDisposed) return;
      cacheDisposed = true;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => coverCache.getFileFromCache('performance-final-drain'),
      );
      // dispose() only closes the database. Run the store's pending cleanup
      // after I/O callbacks have returned to the test clock, before closing it.
      await tester.pump();
      await tester.pump(coverCache.store.cleanupRunMinInterval);
      await tester.runAsync(coverCache.dispose);
    }

    addTearDown(() async {
      await closeCache();
      await tester.runAsync(() => temporary!.delete(recursive: true));
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final results = <Map<String, dynamic>>[];
    Future<void> render(
      Widget page,
      String name,
      int count,
      Finder cards,
    ) async {
      final values = <double>[];
      var mountedCards = 0;
      for (var sample = -1; sample < _samples; sample++) {
        await tester.pumpWidget(const SizedBox());
        final clock = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(theme: guoguoTheme(Brightness.light), home: page),
        );
        clock.stop();
        mountedCards = cards.evaluate().length;
        expect(mountedCards, greaterThan(0));
        expect(mountedCards, lessThan(count));
        expect(tester.takeException(), isNull);
        if (sample >= 0) values.add(clock.elapsedMicroseconds.toDouble());
      }
      results.add({
        'page': name,
        'items': count,
        'mountedCardWidgets': mountedCards,
        'pump': _summary(values, 1),
      });
      await tester.pumpWidget(const SizedBox());
    }

    for (final count in [1000, 10000]) {
      final memory = MemoryStorage()
        ..value = _fixture(count, 100, covers: false);
      final app = AppStore(storage: memory, provider: _NoNetwork());
      await app.load();
      app.offline = true;
      await render(
        LibraryPage(
          store: app,
          autoLoad: false,
          onOpen: (_) {},
          onSearch: () {},
        ),
        'library',
        count,
        find.byType(DramaCard),
      );
      app.dispose();
    }
    for (final count in [100, 1000]) {
      final app = AppStore(storage: MemoryStorage(), provider: _NoNetwork());
      final downloads = _RenderDownloads(app)
        ..entries = [
          for (var i = 0; i < count; i++)
            DownloadEntry(
              id: '$i',
              drama: Drama(
                id: 'd${i ~/ 10}',
                source: DramaSource.hongguo,
                title: '合成下载 ${i ~/ 10}',
              ),
              episode: Episode.fromJson({'id': '$i'}, i % 10),
              index: i % 10,
              directory: '/fixture',
              input: 'video.mp4',
              contentKey: '',
              process: false,
              tasks: [],
            )..progress = .5,
        ];
      await render(
        Scaffold(
          body: DownloadsPage(store: app, downloads: downloads, onOpen: (_) {}),
        ),
        'downloads',
        count,
        find.byType(Card),
      );
      downloads.dispose();
      app.dispose();
    }
    _report['render'] = results;
    await closeCache();
    await tester.runAsync(() => _write(output!));
  }, skip: output == null);
}
