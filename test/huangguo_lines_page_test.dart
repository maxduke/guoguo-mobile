import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/huangguo_lines_page.dart';

class _Provider implements ProviderClient {
  final calls = <({String method, Map<String, dynamic> args})>[];
  String selected = '';
  bool failSave = false;
  Completer<Map<String, dynamic>>? probe;
  Map<String, dynamic> get state => {
    'selected': selected,
    'items': [
      {'url': 'https://line.example.org', 'host': 'line.example.org'},
    ],
    'warning': '',
  };
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add((method: method, args: args));
    switch (method) {
      case 'huangguoLines':
        return state;
      case 'huangguoLineSelect':
        if (failSave) {
          throw const ProviderException('private https://host/?token=secret');
        }
        selected = args['url'] as String;
        return state;
      case 'huangguoLineProbe':
        return probe?.future ??
            {
              'apiValid': false,
              'httpStatus': 200,
              'elapsedMs': 22,
              'failure': 'invalid_data',
              'error': 'private https://host/?token=secret',
            };
      default:
        throw StateError('Unexpected method $method');
    }
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _Provider provider, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: HuangguoLinesPage(provider: provider),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opening loads published lines without probing or changing selection',
    (tester) async {
      final provider = _Provider();
      await mount(tester, provider);
      expect(provider.calls.map((call) => call.method), ['huangguoLines']);
      expect(provider.calls.single.args['refresh'], true);
      expect(find.text('自动选择'), findsOneWidget);
      expect(find.text('尚未检测'), findsOneWidget);
      expect(find.text('line.example.org'), findsOneWidget);
    },
  );

  testWidgets(
    'HTTP 200 without catalog data stays failed and exported diagnostics are safe',
    (tester) async {
      final provider = _Provider();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mount(tester, provider);
      await tester.tap(find.text('检测'));
      await tester.pumpAndSettle();
      expect(find.text('没有取得有效目录数据 · HTTP 200'), findsOneWidget);
      expect(find.textContaining('目录接口通过'), findsNothing);
      expect(provider.selected, isEmpty);
      await tester.tap(find.byTooltip('复制线路诊断'));
      await tester.pumpAndSettle();
      final report = jsonDecode(copied!) as Map;
      final sample = (report['items'] as List).single as Map;
      expect(sample['apiValid'], false);
      expect(sample['mediaChecked'], false);
      expect(copied, isNot(contains('private')));
      expect(copied, isNot(contains('secret')));
    },
  );

  testWidgets(
    'selection changes only after saving and can return to automatic',
    (tester) async {
      final provider = _Provider()..failSave = true;
      await mount(tester, provider);
      await tester.tap(find.text('使用此线路'));
      await tester.pumpAndSettle();
      expect(find.text('线路设置未保存，请重试'), findsOneWidget);
      expect(find.text('已选择'), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
      provider.failSave = false;
      await tester.tap(find.text('使用此线路'));
      await tester.pumpAndSettle();
      expect(find.text('已选择'), findsOneWidget);
      expect(provider.selected, 'https://line.example.org');
      await tester.tap(find.text('自动选择'));
      await tester.pumpAndSettle();
      expect(provider.selected, isEmpty);
      expect(find.text('使用此线路'), findsOneWidget);
    },
  );

  testWidgets('a late probe cannot update a closed page', (tester) async {
    final provider = _Provider()..probe = Completer<Map<String, dynamic>>();
    await mount(tester, provider);
    await tester.tap(find.text('检测'));
    await tester.pump();
    expect(find.text('正在检测目录接口…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    provider.probe!.complete({
      'apiValid': true,
      'httpStatus': 200,
      'elapsedMs': 2,
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen and large text keep line actions reachable', (
    tester,
  ) async {
    final provider = _Provider();
    await mount(tester, provider, size: const Size(320, 568), scale: 2.5);
    await tester.scrollUntilVisible(find.text('使用此线路'), 200);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('使用此线路'));
    await tester.pumpAndSettle();
    expect(provider.selected, 'https://line.example.org');
    expect(tester.takeException(), isNull);
  });
}
