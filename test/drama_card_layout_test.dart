import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/ui/theme.dart';

void main() {
  testWidgets(
    'TV focused poster reveals title and source without another focus stop',
    (tester) async {
      const drama = Drama(
        id: 'long-title',
        source: DramaSource.hongguo,
        title: '山海有归期：故乡与远方之间的一段很长的故事',
        episodes: 80,
      );
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: guoguoTheme(Brightness.dark, television: true),
          builder: (context, child) => TelevisionScope(
            enabled: true,
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
              },
              child: child!,
            ),
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 420,
                child: DramaCard(
                  drama: drama,
                  favorite: false,
                  onTap: () => opened++,
                  onFavorite: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('红果 · 80 集'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('红果 · 80 集'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == drama.title && w.maxLines == 6,
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('收藏 ${drama.title}'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(opened, 1);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('红果 · 80 集'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
