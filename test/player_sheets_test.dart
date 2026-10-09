import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/player_sheets.dart';

void main() {
  testWidgets('episode sheet forwards selection and retains VIP labels', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerEpisodeSheet(
            episodes: const [
              Episode(id: '1', title: '一', number: 1, raw: {}),
              Episode(id: '2', title: '二', number: 2, raw: {'vip': true}),
            ],
            index: 0,
            onSelect: (index) => selected = index,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('选集 · 共 2 集'), findsOneWidget);
    await tester.tap(find.text('2\nVIP'));
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('more sheet preserves disabled actions and quality callbacks', (
    tester,
  ) async {
    final actions = <PlayerMenuAction>[];
    bool? advance;
    int? quality;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerMoreSheet(
            autoAdvance: true,
            fill: false,
            pipEnabled: false,
            qualities: const [720, 1080],
            quality: 1080,
            onAutoAdvance: (value) => advance = value,
            onAction: actions.add,
            onQuality: (value) => quality = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('720P'));
    expect(quality, 720);
    await tester.tap(find.byType(Switch));
    expect(advance, false);
    await tester.scrollUntilVisible(
      find.text('相关剧集'),
      160,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('相关剧集'));
    expect(actions, [PlayerMenuAction.related]);
    await tester.ensureVisible(find.text('画中画'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('画中画'));
    expect(find.text('投屏到电视'), findsNothing);
    expect(actions, [PlayerMenuAction.related]);
    expect(tester.takeException(), isNull);
  });

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(640, 320), 1.0),
    (const Size(390, 844), 2.0),
  ]) {
    testWidgets(
      'more sheet fits $size at text scale $scale with reachable help',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final actions = <PlayerMenuAction>[];
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    isScrollControlled: true,
                    builder: (_) => SafeArea(
                      child: PlayerMoreSheet(
                        autoAdvance: true,
                        fill: false,
                        pipEnabled: true,
                        qualities: const [360, 480, 720, 1080],
                        quality: 1080,
                        onAutoAdvance: (_) {},
                        onAction: actions.add,
                        onQuality: (_) {},
                      ),
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
        expect(find.text('清晰度').hitTestable(), findsOneWidget);
        expect(find.text('360P').hitTestable(), findsOneWidget);
        expect(find.textContaining('单击显示或隐藏控件'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('下载当前集'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(find.text('下载当前集').hitTestable(), findsOneWidget);
        await tester.tap(find.text('下载当前集'));
        expect(actions, [PlayerMenuAction.download]);
        await tester.scrollUntilVisible(
          find.text('播放手势'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('播放手势'));
        await tester.pumpAndSettle();
        expect(find.textContaining('单击显示或隐藏控件'), findsOneWidget);
        expect(find.textContaining('长按临时 2 倍速，松手恢复原倍速'), findsOneWidget);
        expect(find.textContaining('按住后左右滑动'), findsNothing);
        await tester.ensureVisible(find.textContaining('单击显示或隐藏控件'));
        await tester.pumpAndSettle();
        expect(find.textContaining('单击显示或隐藏控件').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('播放手势'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('播放手势'));
        await tester.pumpAndSettle();
        expect(find.textContaining('单击显示或隐藏控件'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
