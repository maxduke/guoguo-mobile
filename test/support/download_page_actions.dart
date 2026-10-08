import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/components.dart';

Future<void> openDownloadFilters(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('筛选'),
    -200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('筛选'));
  await tester.pumpAndSettle();
}

Future<void> setDownloadFilters(
  WidgetTester tester, {
  String? status,
  String? source,
  String? sort,
  bool reset = false,
}) async {
  await openDownloadFilters(tester);
  if (source != null) {
    await tester.tap(
      find.descendant(
        of: find.byType(SourceFilter),
        matching: find.byType(OutlinedButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(source).last);
    await tester.pumpAndSettle();
  }
  if (status != null) {
    await tester.ensureVisible(find.text(status));
    await tester.tap(find.text(status));
    await tester.pumpAndSettle();
  }
  if (sort != null) {
    await tester.tap(
      find.byWidgetPredicate((w) => w is DropdownButtonFormField),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(sort).last);
    await tester.pumpAndSettle();
  }
  final action = find.text(reset ? '重置筛选' : '应用');
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> expandDownloadGroup(
  WidgetTester tester, {
  String? dramaKey,
}) async {
  final action = dramaKey == null
      ? find.text('查看分集').first
      : find.descendant(
          of: find.byKey(ValueKey('download-$dramaKey')),
          matching: find.text('查看分集'),
        );
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}
