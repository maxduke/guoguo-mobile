import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/continue_watching_card.dart';
import 'package:guoguo_mobile/ui/home_page.dart';
import 'package:guoguo_mobile/ui/personal_page.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'continue_and_range_test.dart' show Routes;

class _Provider implements ProviderClient {
  int chapters = 0;
  var pending = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    if (method == 'chapters') {
      chapters++;
      return pending.future;
    }
    return Future.value({'items': []});
  }
}

class _Downloads extends DownloadStore {
  _Downloads(super.app);
  @override
  Future<void> refreshUsage() async {}
}

AppStore _store(
  _Provider provider, {
  int count = 1,
  bool cached = false,
  String title = '故事',
}) {
  final store = AppStore(storage: MemoryStorage(), provider: provider);
  final dramas = List.generate(
    count,
    (i) => Drama(id: 'd$i', source: DramaSource.hongguo, title: '$title$i'),
  );
  store.records.restore(
    RecordBackup(dramas, [
      for (var i = 0; i < count; i++)
        WatchRecord(
          drama: dramas[i],
          episodeId: 'e4',
          episodeIndex: 1,
          positionMs: 10000,
          durationMs: 60000,
          updatedAt: DateTime.utc(2026, 1, 1, 0, i),
        ),
    ]),
    {},
  );
  if (cached) {
    for (final drama in dramas) {
      store.catalog.episodeUpdatedAt[drama.key] = DateTime.now();
      store.catalog.episodeCache[drama.key] = [
        Episode.fromJson({'id': 'e2', 'currentEpisode': 2}, 0),
        Episode.fromJson({'id': 'e4', 'currentEpisode': 4}, 1),
      ];
    }
  }
  return store;
}

Future<void> _mount(
  WidgetTester tester,
  AppStore store,
  DownloadStore downloads, {
  Routes? routes,
  bool personal = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [?routes],
      home: HomePage(store: store, downloads: downloads, autoLoad: false),
    ),
  );
  await tester.pumpAndSettle();
  if (personal) {
    await tester.tap(find.text('追剧'));
    await tester.pumpAndSettle();
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    await Directory('build/personal-previews').create(recursive: true);
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      'build/personal-previews/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  Directory? previewCache;
  if (font != null) {
    setUpAll(() async {
      previewCache = await Directory.systemTemp.createTemp(
        'guoguo-personal-preview-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => previewCache!.path,
          );
      await coverCache.getFileFromCache('personal-preview-initialization');
    });
    tearDownAll(() async {
      await coverCache.dispose();
      await previewCache!.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
    });
  }

  testWidgets(
    'recent continuation is limited and an older favorite plays directly',
    (tester) async {
      final provider = _Provider();
      final store = _store(provider, count: 4, cached: true);
      final downloads = _Downloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      final routes = Routes();
      await _mount(tester, store, downloads, routes: routes);
      expect(find.byType(ContinueWatchingCard), findsNWidgets(3));
      final row = find.byKey(
        ValueKey('personal:${store.records.favorites.values.first.key}'),
      );
      await tester.scrollUntilVisible(
        row.hitTestable(),
        250,
        scrollable: find.descendant(
          of: find.byType(PersonalPage),
          matching: find.byType(Scrollable),
        ),
      );
      final play = find.descendant(of: row, matching: find.text('继续观看'));
      await tester.ensureVisible(play);
      await tester.tap(play);
      final player =
          (routes.last! as MaterialPageRoute<void>).builder(
                tester.element(find.byType(HomePage)),
              )
              as PlayerPage;
      expect(player.drama.id, 'd0');
      expect(player.initialIndex, 1);
      expect(player.episodes[1].number, 4);
      expect(() => player.episodes.clear(), throwsUnsupportedError);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'tab change cancels late resume ${fail ? 'failure' : 'success'} and duplicate taps',
      (tester) async {
        final provider = _Provider();
        final store = _store(provider);
        final downloads = _Downloads(store);
        addTearDown(() {
          downloads.dispose();
          store.dispose();
        });
        final routes = Routes();
        await _mount(tester, store, downloads, routes: routes);
        final before = routes.last;
        await tester.tap(find.byTooltip('继续观看 故事0'));
        await tester.tap(find.byTooltip('继续观看 故事0'));
        await tester.pump();
        expect(provider.chapters, 1);
        await tester.tap(find.text('剧库'));
        await tester.pump();
        if (fail) {
          provider.pending.completeError(StateError('secret'));
        } else {
          provider.pending.complete({
            'chapters': [
              {'id': 'e2'},
              {'id': 'e4'},
            ],
          });
        }
        await tester.pumpAndSettle();
        expect(routes.last, before);
        expect(find.textContaining('secret'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('追剧'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.play_circle_fill_rounded),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'source selection invalidates a pending resume without late feedback',
    (tester) async {
      final provider = _Provider();
      final store = _store(provider);
      final downloads = _Downloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      final routes = Routes();
      await _mount(tester, store, downloads, routes: routes);
      await tester.tap(find.byTooltip('继续观看 故事0'));
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, '全部站源'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.widgetWithText(ChoiceChip, '黄果'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final selected = routes.last;
      provider.pending.completeError(StateError('secret'));
      await tester.pumpAndSettle();
      expect(routes.last, selected);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.text('暂时无法续播，请重试或打开详情'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('opening details invalidates a pending resume', (tester) async {
    final provider = _Provider();
    final store = _store(provider);
    final downloads = _Downloads(store);
    addTearDown(() {
      downloads.dispose();
      store.dispose();
    });
    final routes = Routes();
    await _mount(tester, store, downloads, routes: routes);
    await tester.tap(find.byTooltip('继续观看 故事0'));
    await tester.pump();
    await tester.tap(find.text('详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final details = routes.last;
    provider.pending.complete({
      'chapters': [
        {'id': 'e2'},
        {'id': 'e4'},
      ],
    });
    await tester.pumpAndSettle();
    expect(routes.last, details);
    expect(find.byType(PlayerPage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'home dependency replacement releases pending continuation and rebinds search',
    (tester) async {
      final previousProvider = _Provider();
      final previous = _store(previousProvider);
      final previousDownloads = _Downloads(previous);
      final current = _store(_Provider(), cached: true, title: '新故事');
      final currentDownloads = _Downloads(current);
      addTearDown(() {
        previousDownloads.dispose();
        previous.dispose();
        currentDownloads.dispose();
        current.dispose();
      });
      final routes = Routes();
      Widget app(AppStore store, DownloadStore downloads) => MaterialApp(
        navigatorObservers: [routes],
        home: HomePage(store: store, downloads: downloads, autoLoad: false),
      );
      await tester.pumpWidget(app(previous, previousDownloads));
      await tester.pumpAndSettle();
      final oldInput = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      await tester.tap(find.byTooltip('继续观看 故事0'));
      await tester.pump();
      await tester.pumpWidget(app(current, currentDownloads));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        isNot(same(oldInput)),
      );
      previousProvider.pending.completeError(StateError('secret'));
      await tester.pumpAndSettle();
      expect(find.textContaining('secret'), findsNothing);
      await tester.tap(find.byTooltip('继续观看 新故事0'));
      final player =
          (routes.last! as MaterialPageRoute<void>).builder(
                tester.element(find.byType(HomePage)),
              )
              as PlayerPage;
      expect(player.store, same(current));
      expect(player.downloads, same(currentDownloads));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final personal in [false, true]) {
    testWidgets(
      'returning from settings invalidates ${personal ? 'personal' : 'catalog'} continuation',
      (tester) async {
        PackageInfo.setMockInitialValues(
          appName: '果果',
          packageName: 'test',
          version: '1',
          buildNumber: '1',
          buildSignature: '',
        );
        final provider = _Provider();
        final store = _store(provider);
        final downloads = _Downloads(store);
        addTearDown(() {
          downloads.dispose();
          store.dispose();
        });
        final routes = Routes();
        await _mount(
          tester,
          store,
          downloads,
          routes: routes,
          personal: personal,
        );
        await tester.tap(find.byTooltip('继续观看 故事0'));
        await tester.pump();
        await tester.tap(find.byTooltip('设置'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final visited = routes.last;
        provider.pending.complete({
          'chapters': [
            {'id': 'e2'},
            {'id': 'e4'},
          ],
        });
        await tester.pump();
        expect(routes.last, visited);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.play_circle_fill_rounded),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('active resume failure permits an explicit retry', (
    tester,
  ) async {
    final provider = _Provider();
    final store = _store(provider);
    final downloads = _Downloads(store);
    addTearDown(() {
      downloads.dispose();
      store.dispose();
    });
    final routes = Routes();
    await _mount(tester, store, downloads, routes: routes);
    await tester.tap(find.byTooltip('继续观看 故事0'));
    provider.pending.completeError(StateError('secret'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法续播，请重试或打开详情'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    provider.pending = Completer();
    await tester.tap(find.byTooltip('继续观看 故事0'));
    provider.pending.complete({
      'chapters': [
        {'id': 'e2'},
        {'id': 'e4'},
      ],
    });
    await tester.pump();
    final route = routes.last! as MaterialPageRoute<void>;
    final player =
        route.builder(tester.element(find.byType(HomePage))) as PlayerPage;
    expect(player.initialIndex, 1);
    expect(provider.chapters, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'history back is scoped to the active tab and removal preserves downloaded entries',
    (tester) async {
      final store = _store(_Provider(), cached: true);
      final downloads = _Downloads(store);
      final drama = store.records.favorites.values.single;
      downloads.entries.add(
        DownloadEntry(
          id: 'download',
          drama: drama,
          episode: store.catalog.episodeCache[drama.key]!.last,
          index: 1,
          directory: '/saved',
          input: 'saved.mp4',
          contentKey: '',
          process: false,
          tasks: [],
          ready: true,
        ),
      );
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await _mount(tester, store, downloads);
      await tester.tap(find.text('历史 1'));
      await tester.pumpAndSettle();
      expect(find.text('观看历史'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('接着看'), findsOneWidget);
      await tester.tap(find.text('历史 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除历史'));
      await tester.pumpAndSettle();
      expect(store.records.history, isEmpty);
      expect(downloads.entries.single.id, 'download');
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(find.text('我的下载'), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(HomePage)))!.popDisposition,
        RoutePopDisposition.bubble,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'small screen and large text keep continuation and detail controls reachable',
    (tester) async {
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
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _store(
        _Provider(),
        count: 3,
        cached: true,
        title: '一个非常非常长的故事名称',
      );
      final downloads = _Downloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: preview,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: guoguoTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Scaffold(
              body: PersonalPage(store: store, downloads: downloads),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('详情'), findsNWidgets(3));
      if (font != null) await _capture(tester, preview, 'recent-320-large');
      await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, '查看详情').hitTestable(),
        200,
      );
      expect(tester.takeException(), isNull);
      if (font != null) {
        await _capture(tester, preview, 'favorites-320-large');
        for (final width in [390.0, 1024.0]) {
          for (final mode in [Brightness.light, Brightness.dark]) {
            tester.view.physicalSize = Size(width, 844);
            await tester.pumpWidget(
              RepaintBoundary(
                key: preview,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: guoguoTheme(mode),
                  home: Scaffold(
                    body: PersonalPage(
                      key: ValueKey('$width-$mode'),
                      store: store,
                      downloads: downloads,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await _capture(
              tester,
              preview,
              'recent-${width.toInt()}-${mode.name}',
            );
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
      if (font != null) await tester.pump(const Duration(seconds: 11));
    },
  );
}
