import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/source_selector.dart';

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(320, 740),
  double scale = 1,
  double keyboard = 0,
  bool includeAll = false,
  required List<DramaSource?> changes,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  DramaSource? selected = DramaSource.hongguo;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SourceSelector(
            value: selected,
            includeAll: includeAll,
            onChanged: (value) => setState(() {
              changes.add(value);
              selected = value;
            }),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(SourceSelector),
      matching: find.byType(OutlinedButton),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(320, 740),
    const Size(1024, 768),
  ]) {
    testWidgets('all nineteen sources remain selectable on $size', (
      tester,
    ) async {
      final changes = <DramaSource?>[];
      await _mount(tester, size: size, changes: changes);
      expect(find.byType(ChoiceChip), findsNothing);
      await _open(tester);
      for (final source in DramaSource.values) {
        final tile = find.widgetWithText(ChoiceChip, source.label);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        expect(tile.hitTestable(), findsOneWidget, reason: source.label);
        expect(
          tester.widget<ChoiceChip>(tile).selected,
          source == DramaSource.hongguo,
        );
      }
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pumpAndSettle();
      expect(changes, [DramaSource.wuguo]);
      expect(find.text('伍果'), findsOneWidget);
      await _open(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '伍果'));
      await tester.pumpAndSettle();
      expect(changes, [DramaSource.wuguo]);
      await _open(tester);
      await tester.tap(find.byTooltip('关闭站源选择'));
      await tester.pumpAndSettle();
      expect(changes, [DramaSource.wuguo]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search supports source names and the all-source record filter', (
    tester,
  ) async {
    final changes = <DramaSource?>[];
    await _mount(tester, changes: changes, includeAll: true);
    await _open(tester);
    await tester.enterText(find.byType(TextField), ' WUGUO ');
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsOneWidget);
    expect(find.text('伍果'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的站源'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.enterText(find.byType(TextField), '全部');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '全部站源'));
    await tester.pumpAndSettle();
    expect(changes, [null]);
    expect(find.text('全部站源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final layout in [
    (size: const Size(320, 740), scale: 2.0, keyboard: 300.0),
    (size: const Size(844, 390), scale: 1.0, keyboard: 240.0),
  ]) {
    testWidgets('source search remains usable with $layout', (tester) async {
      final changes = <DramaSource?>[];
      await _mount(
        tester,
        size: layout.size,
        scale: layout.scale,
        keyboard: layout.keyboard,
        includeAll: true,
        changes: changes,
      );
      await _open(tester);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '伍果');
      await tester.pumpAndSettle();
      final tile = find.widgetWithText(ChoiceChip, '伍果');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      expect(tile.hitTestable(), findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(changes, [DramaSource.wuguo]);
      expect(tester.takeException(), isNull);
    });
  }
}
