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
            castEnabled: false,
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
    await tester.tap(find.text('相关剧集'));
    expect(actions, [PlayerMenuAction.related]);
    await tester.tap(find.byType(Switch));
    expect(advance, false);
    await tester.ensureVisible(find.text('画中画'));
    await tester.tap(find.text('画中画'));
    await tester.ensureVisible(find.text('投屏到电视'));
    await tester.tap(find.text('投屏到电视'));
    expect(actions, [PlayerMenuAction.related]);
    await tester.scrollUntilVisible(
      find.text('720P'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.text('720P'));
    expect(quality, 720);
    expect(tester.takeException(), isNull);
  });
}
