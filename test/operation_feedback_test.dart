import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/user_input_exception.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/components.dart';

void main() {
  final cases = <(Object, String)>[
    (StateError('https://private.invalid?token=secret'), '操作未完成，请稍后重试'),
    (const FormatException('Invalid JSON', 'secret', 1), '操作未完成，请稍后重试'),
    (const UserInputException('备份文件超过 20 MB'), '备份文件超过 20 MB'),
    (const ProviderException('请联网后检查更新'), '请联网后检查更新'),
    (
      const ProviderException('secret', userMessage: '站源暂时不可用，请稍后重试'),
      '站源暂时不可用，请稍后重试',
    ),
  ];
  for (var i = 0; i < cases.length; i++) {
    final (error, expected) = cases[i];
    testWidgets('operation feedback uses displayable messages $i', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => perform(context, () async => throw error),
                child: const Text('操作'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
    });
  }

  testWidgets('a failed action after leaving has no late feedback', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => perform(context, () => pending.future),
              child: const Text('操作'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('操作'));
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('secret'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
