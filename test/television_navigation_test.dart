import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/main.dart';
import 'package:guoguo_mobile/ui/components.dart';
import 'package:guoguo_mobile/ui/player_remote_controls.dart';
import 'package:guoguo_mobile/ui/television_scope.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'widget_test.dart' show NoNetwork;

class _VideoSurfaceProbe extends StatefulWidget {
  const _VideoSurfaceProbe({super.key, required this.onDeactivate});
  final VoidCallback onDeactivate;
  @override
  State<_VideoSurfaceProbe> createState() => _VideoSurfaceProbeState();
}

class _VideoSurfaceProbeState extends State<_VideoSurfaceProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  void deactivate() {
    widget.onDeactivate();
    super.deactivate();
  }
}

void main() {
  testWidgets(
    'media keys read current playback state without requiring a rebuild',
    (tester) async {
      var playing = true, changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerRemoteControls(
            enabled: true,
            controlsVisible: false,
            playing: playing,
            isPlaying: () => playing,
            onShowControls: () {},
            onPlayPause: () {
              changes++;
              playing = !playing;
            },
            onSeekBy: (_) {},
            onPrevious: null,
            onNext: null,
            child: const Scaffold(body: Text('video')),
          ),
        ),
      );
      await tester.pump();
      playing = false; // Native pause arrives independently of the page build.
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
      expect(changes, 1);
      expect(playing, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
      expect(changes, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
      expect(changes, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('remote availability changes retain the mounted video surface', (
    tester,
  ) async {
    var deactivations = 0;
    final enabled = ValueNotifier(true);
    final surface = Scaffold(
      body: _VideoSurfaceProbe(
        key: GlobalKey(),
        onDeactivate: () => deactivations++,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, active, _) => PlayerRemoteControls(
            enabled: active,
            controlsVisible: false,
            onShowControls: () {},
            onPlayPause: () {},
            onSeekBy: (_) {},
            onPrevious: null,
            onNext: null,
            child: surface,
          ),
        ),
      ),
    );
    await tester.pump();
    enabled.value = false;
    await tester.pump();
    expect(deactivations, 0);
    enabled.value = true;
    await tester.pump();
    expect(deactivations, 0);
    await tester.pumpWidget(const SizedBox());
    enabled.dispose();
  });

  testWidgets('TV home navigation is reachable with D-pad and center only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppStore(storage: MemoryStorage(), provider: NoNetwork());
    app.catalog.discoveryCache.putRecommendations(
      RecommendationGenre.shortPlay,
      const [Drama(id: 'one', source: DramaSource.hongguo, title: '电视样本')],
      DateTime.now(),
    );
    final downloads = DownloadStore(app);
    await tester.pumpWidget(
      GuoguoApp(
        store: app,
        downloads: downloads,
        autoLoad: false,
        television: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('接着看'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('我的下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    downloads.dispose();
    app.dispose();
  });

  testWidgets('TV poster focus is visible and center opens the selected card', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TelevisionScope(
          enabled: true,
          child: Scaffold(
            body: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
              },
              child: SizedBox(
                width: 220,
                height: 320,
                child: DramaCard(
                  drama: const Drama(
                    id: 'one',
                    source: DramaSource.hongguo,
                    title: '电视样本',
                  ),
                  favorite: false,
                  onTap: () => opened++,
                  onFavorite: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.byKey(const Key('television-focus-outline')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'remote playback keys preserve explicit play and pause semantics',
    (tester) async {
      var toggles = 0, shown = 0;
      final seeks = <Duration>[];
      Widget app(bool visible, bool playing) => MaterialApp(
        home: PlayerRemoteControls(
          enabled: true,
          controlsVisible: visible,
          playing: playing,
          onShowControls: () => shown++,
          onPlayPause: () => toggles++,
          onSeekBy: seeks.add,
          onPrevious: null,
          onNext: null,
          child: const Scaffold(body: Text('video')),
        ),
      );
      await tester.pumpWidget(app(false, true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
      expect(toggles, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
      expect(toggles, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(seeks, [const Duration(seconds: 10)]);
      await tester.pumpWidget(app(true, false));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPause);
      expect(toggles, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
      expect(toggles, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(seeks, hasLength(1));
      expect(shown, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
