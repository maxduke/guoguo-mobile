import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/source_diagnostic.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/source_selector.dart';
import 'package:guoguo_mobile/ui/source_request_status.dart';
import 'package:guoguo_mobile/ui/theme.dart';

class _Provider implements ProviderClient {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add(method);
    return {'items': [], 'hasMore': false};
  }
}

void main() {
  Future<({AppStore store, _Provider provider})> mount(
    WidgetTester tester, {
    bool small = false,
    List<DramaSource?>? choices,
  }) async {
    tester.view.physicalSize = small
        ? const Size(320, 568)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    });
    store.sourceDiagnostics.add(
      SourceDiagnostic(
        source: DramaSource.hongguo,
        method: 'catalog',
        at: DateTime(2026, 11, 5, 18),
        elapsedMs: 218,
        networkAttempts: 1,
        validation: 'passed',
      ),
    );
    store.sourceDiagnostics.add(
      SourceDiagnostic(
        source: DramaSource.huangguo,
        method: 'search',
        at: DateTime(2026, 11, 5, 18, 1),
        elapsedMs: 900,
        result: 'failed',
        failure: 'timeout',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: guoguoTheme(small ? Brightness.dark : Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(small ? 2.5 : 1),
            viewInsets: EdgeInsets.only(bottom: small ? 200 : 0),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SourceSelector(
            value: DramaSource.hongguo,
            catalog: store.catalog,
            preferences: store.preferences,
            onChanged: (source) => choices?.add(source),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    return (store: store, provider: provider);
  }

  testWidgets(
    'source picker uses existing requests, keeps diagnostic actions scoped and does not probe',
    (tester) async {
      final f = await mount(tester);
      expect(find.text('目录 · 读取成功'), findsWidgets);
      expect(find.text('最近请求记录 · 未验证视频播放'), findsOneWidget);
      expect(f.provider.calls, isEmpty);
      await tester.tap(find.byTooltip('查看红果请求记录'));
      await tester.pumpAndSettle();
      expect(find.text('红果 · 请求记录'), findsOneWidget);
      expect(find.textContaining('黄果'), findsNothing);
      await tester.tap(find.byTooltip('清空站源诊断'));
      await tester.pumpAndSettle();
      expect(
        f.store.sourceDiagnostics.samples.single.source,
        DramaSource.huangguo,
      );
      expect(f.provider.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source status never presents cached metadata as a new network success',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceRequestStatus(
              sample: SourceDiagnostic(
                source: DramaSource.hongguo,
                method: 'catalog',
                at: DateTime(2026, 11, 5),
                elapsedMs: 0,
                requestResult: 'not_requested',
                cacheHits: 1,
                networkAttempts: 0,
              ),
            ),
          ),
        ),
      );
      expect(find.text('目录 · 已保存'), findsOneWidget);
      expect(find.textContaining('读取成功'), findsNothing);
    },
  );

  testWidgets(
    'large-text source selection remains reachable with an open keyboard and issues no requests',
    (tester) async {
      final choices = <DramaSource?>[];
      final f = await mount(tester, small: true, choices: choices);
      await tester.enterText(find.byType(TextField), '黄果');
      await tester.pumpAndSettle();
      final choice = find.widgetWithText(ChoiceChip, '黄果');
      await tester.scrollUntilVisible(
        choice,
        170,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(choices, [DramaSource.huangguo]);
      expect(f.provider.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial results are distinct from a cache fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceRequestStatus(
            sample: SourceDiagnostic(
              source: DramaSource.hongguo,
              method: 'search',
              at: DateTime(2026, 11, 5),
              elapsedMs: 20,
              result: 'partial',
              networkAttempts: 1,
            ),
          ),
        ),
      ),
    );
    expect(find.text('搜索 · 部分结果'), findsOneWidget);
    expect(find.textContaining('缓存'), findsNothing);
  });

  testWidgets('retrying the current source is a separate explicit action', (
    tester,
  ) async {
    final f = await mount(tester);
    expect(f.provider.calls, isEmpty);
    await tester.tap(find.byTooltip('重试当前剧库'));
    await tester.pumpAndSettle();
    expect(f.provider.calls, ['catalog']);
    expect(f.store.catalog.source, DramaSource.hongguo);
  });
}
