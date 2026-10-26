import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/episode_grid.dart';
import 'package:guoguo_mobile/ui/detail_page.dart';
import 'package:guoguo_mobile/ui/search_page.dart';
import 'package:guoguo_mobile/ui/television_grid.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/theme.dart';
import 'widget_test.dart' show NoNetwork;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void _screen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Widget home) => MaterialApp(
  theme: guoguoTheme(Brightness.light, television: true),
  builder: (_, child) => TelevisionScope(
    enabled: true,
    child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: child!,
    ),
  ),
  home: home,
);

Drama _drama(int index) =>
    Drama(id: '$index', source: DramaSource.hongguo, title: '遥控样本 $index');

bool _cardFocused(WidgetTester tester, int index) {
  final card = find.byWidgetPredicate(
    (widget) => widget is DramaCard && widget.drama.id == '$index',
  );
  final poster = find.descendant(of: card, matching: find.byType(Poster));
  return poster.evaluate().isNotEmpty &&
      Focus.of(tester.element(poster)).hasPrimaryFocus;
}

bool _textFocused(WidgetTester tester, String text) => tester
    .elementList(find.text(text))
    .any((element) => Focus.of(element).hasPrimaryFocus);

void main() {
  testWidgets(
    'TV detail toolbar Down enters episodes and restores the last tile',
    (tester) async {
      _screen(tester);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      final drama = _drama(70);
      store.catalog.episodeCache[drama.key] = [
        for (var i = 0; i < 70; i++)
          Episode.fromJson({'id': 'episode-$i', 'currentEpisode': i + 1}, i),
      ];
      final downloads = DownloadStore(store);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        _app(DetailPage(store: store, downloads: downloads, drama: drama)),
      );
      await tester.pumpAndSettle();
      expect(_textFocused(tester, '开始观看'), true);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_textFocused(tester, '1'), true);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_textFocused(tester, '定位当前'), true);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_textFocused(tester, '1'), true);
      expect(find.text('1').hitTestable(), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_textFocused(tester, '2'), true);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_textFocused(tester, '定位当前'), true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_textFocused(tester, '跳集'), true);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_textFocused(tester, '2'), true);
      expect(find.text('2').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV cards move by row and column and restore after a route', (
    tester,
  ) async {
    _screen(tester);
    var favorites = 0;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 660,
              child: TelevisionGrid(
                sliver: false,
                itemKeys: [for (var i = 0; i < 12; i++) '$i'],
                columns: 3,
                mainAxisExtent: 290,
                autofocusIndex: 0,
                itemBuilder: (context, index) => DramaCard(
                  drama: _drama(index),
                  favorite: false,
                  onFavorite: () => favorites++,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        body: FilledButton(
                          autofocus: true,
                          onPressed: () {},
                          child: Text('详情 $index'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 0), true);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_cardFocused(tester, 1), true);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_cardFocused(tester, 2), true);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_cardFocused(tester, 2), true);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_cardFocused(tester, 5), true);
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_cardFocused(tester, 4), true);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_cardFocused(tester, 1), true);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('详情 1'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 1), true);
    expect(favorites, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TV grid reaches unbuilt rows and keeps identity after reorder', (
    tester,
  ) async {
    _screen(tester);
    final rows = ValueNotifier([for (var i = 0; i < 25; i++) i]);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 660,
              height: 200,
              child: ValueListenableBuilder<List<int>>(
                valueListenable: rows,
                builder: (_, items, _) => TelevisionGrid(
                  sliver: false,
                  itemKeys: [for (final item in items) '$item'],
                  columns: 3,
                  mainAxisExtent: 700,
                  autofocusIndex: 0,
                  itemBuilder: (_, index) => DramaCard(
                    drama: _drama(items[index]),
                    favorite: false,
                    onTap: () {},
                    onFavorite: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 0), true);
    expect(find.text('遥控样本 3'), findsNothing);
    // The first move reaches row 1; repeats must stop at the pending lazy row 2.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 6), true);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_cardFocused(tester, 9), true);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_cardFocused(tester, 10), true);
    final reordered = rows.value.toList();
    reordered[10] = 11;
    reordered[11] = 10;
    rows.value = reordered;
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 10), true);
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_cardFocused(tester, 11), true);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_cardFocused(tester, 13), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    rows.dispose();
  });

  testWidgets(
    'TV home rail enters, remembers content and restores after details',
    (tester) async {
      _screen(tester);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork());
      final rows = [for (var i = 0; i < 6; i++) _drama(i)];
      for (final drama in rows) {
        store.catalog.episodeCache[drama.key] = [
          for (var i = 0; i < 5; i++)
            Episode.fromJson({
              'id': '${drama.id}-e$i',
              'currentEpisode': i + 1,
            }, i),
        ];
      }
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        rows,
        DateTime.now(),
      );
      final downloads = DownloadStore(store);
      await tester.pumpWidget(
        GuoguoApp(
          store: store,
          downloads: downloads,
          autoLoad: false,
          television: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(_textFocused(tester, '发现'), true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_textFocused(tester, '红果'), true);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_textFocused(tester, '搜索剧名'), true);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_textFocused(tester, '更多推荐'), true);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_cardFocused(tester, 0), true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_cardFocused(tester, 1), true);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.byType(EpisodeGrid), findsOneWidget);
      expect(_textFocused(tester, '开始观看'), true);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_textFocused(tester, '1'), true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_cardFocused(tester, 1), true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_textFocused(tester, '发现'), true);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_cardFocused(tester, 1), true);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_cardFocused(tester, 0), true);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_textFocused(tester, '发现'), true);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('接着看'), findsOneWidget);
      expect(_textFocused(tester, '发现'), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      downloads.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'TV episode paging and locate transfer focus to a visible episode',
    (tester) async {
      _screen(tester);
      final episodes = [
        for (var i = 0; i < 65; i++)
          Episode.fromJson({'id': 'e$i', 'currentEpisode': i + 1}, i),
      ];
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 400,
                child: EpisodeGrid(
                  episodes: episodes,
                  initialIndex: 28,
                  autofocus: true,
                  onJump: (_) {},
                  builder: (_, index) => FilledButton(
                    onPressed: () {},
                    child: Text('分集 ${index + 1}'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_textFocused(tester, '分集 29'), true);
      expect(find.text('分集 29').hitTestable(), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_textFocused(tester, '下一页'), true);
      await _key(tester, LogicalKeyboardKey.select);
      expect(_textFocused(tester, '分集 31'), true);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_textFocused(tester, '定位当前'), true);
      await _key(tester, LogicalKeyboardKey.select);
      expect(_textFocused(tester, '分集 29'), true);
      expect(find.text('分集 29').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('TV search focuses results and restores the opened result', (
    tester,
  ) async {
    _screen(tester);
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..offline = true;
    store.catalog.catalogs[DramaSource.hongguo] = [
      for (var i = 0; i < 8; i++) _drama(i),
    ];
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => SearchPage(
            store: store,
            onOpen: (drama) => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(body: Text('已打开 ${drama.id}')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '遥控样本');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 0), true);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_cardFocused(tester, 1), true);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('已打开 1'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_cardFocused(tester, 1), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets(
    'phone episode paging still resets to the start of the new page',
    (tester) async {
      final episodes = [
        for (var i = 0; i < 65; i++)
          Episode.fromJson({'id': 'e$i', 'currentEpisode': i + 1}, i),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 400,
              child: EpisodeGrid(
                episodes: episodes,
                onJump: (_) {},
                builder: (_, index) => Text('分集 ${index + 1}'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(GridView), const Offset(0, -550));
      await tester.pumpAndSettle();
      expect(find.text('分集 1').hitTestable(), findsNothing);
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('31–60 集').last);
      await tester.pumpAndSettle();
      expect(find.text('分集 31').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
