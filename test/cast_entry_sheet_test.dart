import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/airplay_session.dart';
import 'package:guoguo_mobile/ui/cast_entry_sheet.dart';

import 'support/cast_fakes.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required Size size,
    required double scale,
    required bool engaged,
    GlobalKey? previewKey,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session =
        AirPlaySession(
            loadSource: (_) async => castSource(),
            retainSources: (_) {},
            episodeCount: 1,
            autoAdvance: () => false,
            relayFactory: FakeCastRelay.new,
            channel: const MethodChannel('guoguo/cast-entry-layout'),
          )
          ..engaged = engaged
          ..routed = engaged;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'sans-serif',
            ),
          ),
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
                    child: CastEntrySheet(
                      airplay: session,
                      televisionEnabled: !engaged,
                      airPlayEnabled: !engaged,
                      routesEnabled: false,
                      returnEnabled: engaged,
                      returnPending: engaged,
                      returning: false,
                      unavailableReason: null,
                      onAction: (_) => Navigator.pop(context),
                    ),
                  ),
                ),
                child: const Text('打开投屏'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开投屏'));
    await tester.pumpAndSettle();
  }

  for (final sample in [
    (const Size(320, 640), 2.0),
    (const Size(640, 320), 2.0),
    (const Size(1024, 768), 1.0),
  ]) {
    for (final engaged in [false, true]) {
      testWidgets(
        'casting choices are reachable at $sample, engaged=$engaged',
        (tester) async {
          await mount(
            tester,
            size: sample.$1,
            scale: sample.$2,
            engaged: engaged,
          );
          expect(tester.takeException(), isNull);
          expect(
            find.text(engaged ? 'AirPlay 已连接' : 'AirPlay'),
            findsOneWidget,
          );
          final target = engaged ? '结束 AirPlay，返回手机' : '电视设备';
          await tester.scrollUntilVisible(
            find.text(target),
            100,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.pumpAndSettle();
          expect(find.text(target).hitTestable(), findsOneWidget);
          if (engaged) {
            expect(
              tester.getSize(find.widgetWithText(FilledButton, target)).height,
              greaterThanOrEqualTo(48),
            );
          } else {
            expect(
              tester.getSize(find.widgetWithText(ListTile, target)).height,
              greaterThanOrEqualTo(48),
            );
          }
          final action = find.semantics.byLabel(
            RegExp('^${RegExp.escape(target)}'),
          );
          expect(action, findsOne);
          tester.semantics.tap(action);
          await tester.pumpAndSettle();
          expect(find.byType(CastEntrySheet), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  final font = Platform.environment['GUOGUO_PREVIEW_FONT'];
  testWidgets('capture CJK casting choices and status', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader('sans-serif')..addFont(
            Future.value(ByteData.sublistView(await File(font!).readAsBytes())),
          ))
          .load();
      final icons = Platform.environment['GUOGUO_ICON_FONT'];
      if (icons != null) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(await File(icons).readAsBytes()),
              ),
            ))
            .load();
      }
      await Directory('build/cast-entry-previews').create(recursive: true);
    });
    for (final sample in [
      (const Size(390, 844), 1.0, 'phone'),
      (const Size(320, 640), 2.0, 'small-large-text'),
      (const Size(640, 320), 2.0, 'landscape-large-text'),
      (const Size(1024, 768), 1.0, 'tablet'),
    ]) {
      for (final engaged in [false, true]) {
        final key = GlobalKey();
        await mount(
          tester,
          size: sample.$1,
          scale: sample.$2,
          engaged: engaged,
          previewKey: key,
        );
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/cast-entry-previews/${sample.$3}-${engaged ? 'status' : 'choices'}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }
  }, skip: font == null);
}
