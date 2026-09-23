import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/catalog_query.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/episode_grid.dart';
import 'package:guoguo_mobile/ui/home_page.dart';

class UpgradeProvider implements ProviderClient {
  final calls = <String>[];
  Completer<Map<String, dynamic>>? gate;
  Map<String, dynamic> result = {};
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    calls.add(method);
    return gate?.future ?? Future.value(result);
  }
}

const drama = Drama(
  id: 'hongguo:123',
  source: DramaSource.hongguo,
  title: '普通弓箭手（第五季）',
  cover: 'old',
  description: '保留简介',
);

void main() {
  test(
    'normalizes fullwidth, punctuation, tokenized queries and natural seasons',
    () {
      expect(matchesDrama(drama, '普通弓箭手 第5季'), isTrue);
      expect(searchText('ＡＢＣ： 第五季'), 'abc第5季');
      expect(naturalTitleCompare('故事第九季', '故事第十季'), lessThan(0));
      expect(naturalTitleCompare('故事第2季', '故事第11季'), lessThan(0));
      expect(heatValue('1.2万热度'), 12000);
      final rows = [
        drama,
        const Drama(
          id: '2',
          source: DramaSource.hongguo,
          title: '高热度',
          heat: '1万',
        ),
        const Drama(
          id: '3',
          source: DramaSource.hongguo,
          title: '会员',
          vip: true,
          heat: '9万',
        ),
      ];
      expect(
        queryCatalog(
          rows,
          hideVip: true,
          sort: CatalogSort.heat,
        ).map((d) => d.id),
        ['2', drama.id],
      );
    },
  );

  test(
    'metadata coalesces, merges saved records, preserves progress and persists new fields',
    () async {
      final provider = UpgradeProvider()..gate = Completer();
      final storage = MemoryStorage();
      final store = AppStore(storage: storage, provider: provider);
      store.favorites[drama.key] = drama;
      store.history[drama.key] = WatchRecord(
        drama: drama,
        episodeId: 'e3',
        episodeIndex: 2,
        positionMs: 12345,
        durationMs: 60000,
        updatedAt: DateTime.utc(2026),
      );
      final first = store.refreshDetail(drama),
          second = store.refreshDetail(drama);
      provider.gate!.complete({
        'item': {
          ...drama.toJson(),
          'cover': 'new',
          'description': '',
          'vip': true,
          'heat': '3万',
          'date': '2026-09-22',
          'tags': ['动作'],
        },
      });
      await Future.wait([first, second]);
      expect(provider.calls, ['detail']);
      expect(store.currentDrama(drama).description, drama.description);
      expect(store.history[drama.key]!.positionMs, 12345);
      expect(store.history[drama.key]!.drama.cover, 'new');
      await store.refreshDetail(drama);
      expect(provider.calls.length, 1);
      final restored = AppStore(storage: storage, provider: provider);
      await restored.load();
      expect(restored.favorites[drama.key]!.vip, true);
      expect(restored.favorites[drama.key]!.tags, ['动作']);
      expect(restored.currentDrama(drama).heat, '3万');
      restored.dispose();
      store.dispose();
    },
  );

  test('wrong identity never replaces detail or saved records', () async {
    final provider = UpgradeProvider()
      ..result = {
        'item': {...drama.toJson(), 'id': 'other'},
      };
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    store.favorites[drama.key] = drama;
    expect((await store.refreshDetail(drama)).id, drama.id);
    expect(store.favorites[drama.key], same(drama));
    expect(store.detailErrors[drama.key], isNotNull);
    store.dispose();
  });

  testWidgets('clearing query suppresses stale suggestions', (tester) async {
    final provider = UpgradeProvider()..gate = Completer();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    store.catalogs[DramaSource.hongguo] = [drama];
    final downloads = DownloadStore(store);
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(store: store, downloads: downloads, autoLoad: false),
      ),
    );
    await tester.enterText(find.byType(TextField), '普通');
    await tester.pump(const Duration(milliseconds: 299));
    expect(provider.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 2));
    expect(provider.calls, ['suggestions']);
    await tester.tap(find.byTooltip('清空搜索'));
    provider.gate!.complete({
      'items': [
        {'name': '过期联想'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('过期联想'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    store.dispose();
  });

  testWidgets('late formal search cannot replace a newer local query', (
    tester,
  ) async {
    final provider = UpgradeProvider()..gate = Completer();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    store.catalogs[DramaSource.hongguo] = [drama];
    final downloads = DownloadStore(store);
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(store: store, downloads: downloads, autoLoad: false),
      ),
    );
    await tester.enterText(find.byType(TextField), '旧关键词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(provider.calls, ['search']);
    await tester.enterText(find.byType(TextField), '普通弓箭手');
    provider.gate!.complete({
      'items': [
        {...drama.toJson(), 'id': 'old', 'title': '旧结果'},
      ],
      'warning': '旧警告',
    });
    await tester.pump();
    expect(find.text('旧警告'), findsNothing);
    expect(find.text('联网结果'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    store.dispose();
  });

  testWidgets(
    'episode pages and jump preserve sparse original episode numbers',
    (tester) async {
      final episodes = List.generate(
        65,
        (i) => Episode.fromJson({'id': '$i', 'currentEpisode': (i + 1) * 2}, i),
      );
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeGrid(
              episodes: episodes,
              initialIndex: 34,
              onJump: (index) => selected = index,
              builder: (_, index) => Text('分集 ${episodes[index].number}'),
            ),
          ),
        ),
      );
      expect(find.text('61–120 集'), findsNothing);
      expect(find.text('62–120 集'), findsOneWidget);
      await tester.tap(find.text('跳集'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '3');
      await tester.tap(find.text('播放'));
      await tester.pump();
      expect(find.text('没有这一集，请输入已有集数'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '124');
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(selected, 61);
      expect(find.text('122–130 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
