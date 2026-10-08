import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/ui/player_sheets.dart';

import 'player_cast_handoff_test.dart'
    show NativeCastPlayer, LocalDownloads, AirPlayFixturePreparer;
import 'widget_test.dart' show NoNetwork;

class _Provider extends NoNetwork {
  final resolved = <(String, int)>[];
  Completer<void>? gate;
  List<int> firstQualities = [720, 1080];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method != 'resolve') return {};
    final id = (arguments['chapter'] as Map)['id'] as String;
    final quality = arguments['quality'] as int;
    resolved.add((id, quality));
    await gate?.future;
    final qualities = id == 'one' ? firstQualities : [360, 480];
    return {
      'url': 'https://fixture.test/$id.mp4',
      'remoteUrl': 'https://fixture.test/$id.mp4',
      'qualities': qualities,
      'quality': quality == 0 ? qualities.last : quality,
    };
  }
}

class _Downloads extends LocalDownloads {
  _Downloads(super.store);
  final added = <(String, int)>[];
  @override
  Future<void> enqueue(Drama drama, Episode episode, int index) async =>
      added.add((episode.id, index));
}

void main() {
  Future<(NativeCastPlayer, _Provider, AppStore, _Downloads)> mount(
    WidgetTester tester, {
    MethodChannel? airPlayChannel,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final native = NativeCastPlayer()..install();
    final provider = _Provider();
    final store = AppStore(storage: MemoryStorage(), provider: provider)
      ..preferences.prefetch = false
      ..preferences.autoAdvance = true;
    final downloads = _Downloads(store)..available = false;
    addTearDown(() {
      native.uninstall();
      downloads.dispose();
      store.dispose();
    });
    var preparers = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          store: store,
          downloads: downloads,
          drama: const Drama(
            id: 'fixture',
            source: DramaSource.hongguo,
            title: '菜单换集边界',
          ),
          episodes: [
            Episode.fromJson({'id': 'one'}, 0),
            Episode.fromJson({'id': 'two'}, 1),
          ],
          initialIndex: 0,
          airPlayChannel: airPlayChannel,
          preparerFactory: () => AirPlayFixturePreparer(preparers++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(const Offset(700, 150));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多播放设置'));
    await tester.pumpAndSettle();
    return (native, provider, store, downloads);
  }

  PlayerMoreSheet menu(WidgetTester tester) =>
      tester.widget<PlayerMoreSheet>(find.byType(PlayerMoreSheet));

  void finish(WidgetTester tester) => tester
      .widget<BetterPlayer>(find.byType(BetterPlayer))
      .controller
      .postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));

  testWidgets(
    'an open menu follows automatic advance and ignores old callbacks',
    (tester) async {
      final (native, provider, store, downloads) = await mount(tester);
      final old = menu(tester);
      expect(old.qualities, [720, 1080]);
      finish(tester);
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0), ('two', 0)]);
      expect(native.sources, hasLength(2));
      expect(menu(tester).qualities, [360, 480]);
      expect(menu(tester).quality, 480);
      old.onQuality(1080);
      old.onAction(PlayerMenuAction.download);
      old.onAutoAdvance(false);
      await tester.pumpAndSettle();
      expect(provider.resolved, hasLength(2));
      expect(downloads.added, isEmpty);
      expect(store.preferences.autoAdvance, true);
      expect(find.byType(PlayerMoreSheet), findsOneWidget);

      final select = menu(tester).onQuality;
      select(360);
      select(360);
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0), ('two', 0), ('two', 360)]);
      expect(find.byType(PlayerMoreSheet), findsNothing);
      expect(find.byType(PlayerPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending next media disables media actions and keeps its download target',
    (tester) async {
      final (_, provider, _, downloads) = await mount(tester);
      final gate = provider.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final old = menu(tester);
      finish(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.resolved, [('one', 0), ('two', 0)]);
      expect(menu(tester).qualities, isEmpty);
      expect(menu(tester).pipEnabled, false);
      expect(menu(tester).castEnabled, false);
      old.onAction(PlayerMenuAction.download);
      expect(downloads.added, isEmpty);
      menu(tester).onAction(PlayerMenuAction.download);
      await tester.pump();
      expect(downloads.added, [('two', 1)]);
      gate.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same episode recovery refreshes choices and rejects the old generation',
    (tester) async {
      final (_, provider, _, downloads) = await mount(tester);
      final old = menu(tester);
      provider.firstQualities = [540, 720];
      tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller
          .postEvent(BetterPlayerEvent(BetterPlayerEventType.exception));
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0), ('one', 0)]);
      expect(menu(tester).qualities, [540, 720]);
      expect(menu(tester).quality, 720);
      old.onQuality(1080);
      old.onAction(PlayerMenuAction.download);
      await tester.pumpAndSettle();
      expect(provider.resolved, hasLength(2));
      expect(downloads.added, isEmpty);
      expect(find.byType(PlayerMoreSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'PiP changes update cast availability and reject an earlier enabled action',
    (tester) async {
      final (native, _, _, _) = await mount(tester);
      final old = menu(tester);
      expect(old.castEnabled, true);
      native.emit('pipStart');
      await tester.pumpAndSettle();
      expect(menu(tester).castEnabled, false);
      old.onAction(PlayerMenuAction.cast);
      await tester.pumpAndSettle();
      expect(find.byType(PlayerMoreSheet), findsOneWidget);
      native.emit('pipStop');
      await tester.pumpAndSettle();
      expect(menu(tester).castEnabled, true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dismissed callbacks cannot enqueue or pop the player twice', (
    tester,
  ) async {
    final (_, _, store, downloads) = await mount(tester);
    final old = menu(tester);
    old.onAction(PlayerMenuAction.download);
    old.onAction(PlayerMenuAction.download);
    await tester.pumpAndSettle();
    expect(downloads.added, [('one', 0)]);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(PlayerMoreSheet), findsNothing);
    old.onAutoAdvance(false);
    expect(store.preferences.autoAdvance, true);
    await tester.pumpWidget(const SizedBox());
    old.onAction(PlayerMenuAction.download);
    old.onQuality(720);
    expect(downloads.added, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AirPlay routing removes local media choices until the phone is available',
    (tester) async {
      const channel = MethodChannel('guoguo/menu-state-airplay');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var external = false;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getState' ? {'routed': external} : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final (_, provider, _, _) = await mount(tester, airPlayChannel: channel);
      final old = menu(tester);
      Future<void> route(bool routed) async {
        external = routed;
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('state', {'sessionId': '', 'routed': routed}),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await tester.pumpAndSettle();
      }

      await route(true);
      expect(menu(tester).qualities, isEmpty);
      expect(menu(tester).pipEnabled, false);
      expect(menu(tester).castEnabled, false);
      old.onQuality(720);
      old.onAction(PlayerMenuAction.pip);
      old.onAction(PlayerMenuAction.cast);
      await tester.pumpAndSettle();
      expect(provider.resolved, [('one', 0)]);
      expect(find.byType(PlayerMoreSheet), findsOneWidget);
      await route(false);
      expect(menu(tester).qualities, [720, 1080]);
      expect(menu(tester).pipEnabled, true);
      expect(menu(tester).castEnabled, true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving with a pending menu refresh ignores late results and callbacks',
    (tester) async {
      final (_, provider, _, downloads) = await mount(tester);
      final old = menu(tester);
      final gate = provider.gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      finish(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(provider.resolved, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      old.onAction(PlayerMenuAction.download);
      old.onQuality(720);
      await tester.pumpAndSettle();
      expect(downloads.added, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
