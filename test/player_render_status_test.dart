import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/ui/player_render_status.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/theme.dart';

const playback = <String, Object?>{
  'prepared': true,
  'loading': false,
  'initialized': true,
  'playing': true,
  'width': 1080,
  'height': 1920,
  'uiTelevision': true,
  'coverVisible': false,
};
const device = <String, Object?>{
  'manufacturer': 'Fixture',
  'model': 'TV 9',
  'androidVersion': '10',
  'apiLevel': 29,
  'version': '0.20.3-dev',
  'build': 55,
  'abis': ['armeabi-v7a'],
  'renderingPolicy': 'legacy-opengl',
};

Future<void> mount(
  WidgetTester tester,
  Future<Map<String, Object?>> future, {
  Size size = const Size(1280, 720),
  double scale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: guoguoTheme(Brightness.dark, television: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: TelevisionScope(enabled: true, child: child!),
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 720,
            height: size.height * .84,
            child: PlayerRenderStatus(playback: playback, deviceInfo: future),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'render snapshot shows device and cover state and copies structured data',
    (tester) async {
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await mount(tester, Future.value(device));
      expect(find.textContaining('Fixture TV 9'), findsOneWidget);
      expect(find.textContaining('旧版 OpenGL（TV 兼容）'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('封面：隐藏'));
      expect(find.textContaining('封面：隐藏'), findsOneWidget);
      await tester.ensureVisible(find.text('复制状态'));
      await tester.tap(find.text('复制状态'));
      await tester.pump();
      final result = jsonDecode(copied!) as Map;
      expect(result['device']['apiLevel'], 29);
      expect(result['playback']['coverVisible'], false);
      expect(result['playback']['playing'], true);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV can traverse every status row with D-pad at large text', (
    tester,
  ) async {
    await mount(
      tester,
      Future.value(device),
      size: const Size(960, 540),
      scale: 1.5,
    );
    expect(
      Focus.of(tester.element(find.textContaining('应用：'))).hasPrimaryFocus,
      true,
    );
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(Focus.of(tester.element(find.text('复制状态'))).hasPrimaryFocus, true);
    expect(find.text('复制状态').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed device information leaves the playback snapshot readable',
    (tester) async {
      final pending = Completer<Map<String, Object?>>();
      await mount(tester, pending.future, settle: false);
      pending.completeError(StateError('unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('设备信息暂不可用'), findsOneWidget);
      await tester.ensureVisible(find.textContaining('画面尺寸：1080 × 1920'));
      expect(find.textContaining('画面尺寸：1080 × 1920'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
