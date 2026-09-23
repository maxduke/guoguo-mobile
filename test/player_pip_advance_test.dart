import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/player_page.dart';

import 'widget_test.dart' show NoNetwork;

class _LocalDownloads extends DownloadStore {
  _LocalDownloads(super.store, this.directory);
  final String directory;
  final requestedIds = <String>[];

  @override
  Future<String?> localFile(Drama drama, Episode episode) async {
    requestedIds.add(episode.id);
    return '$directory/pip_episode_${episode.id}.mp4';
  }
}

class _NativePlayer {
  static const channel = MethodChannel('better_player_channel');
  static const eventChannel = MethodChannel(
    'better_player_channel/videoEvents7',
  );
  static const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity',
  );
  static const connectivityStatus = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  final sources = <String>[];
  final plays = <Object?>[];
  final pauses = <Object?>[];
  final ids = <Object?>[];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'create') return {'textureId': 7};
      if (call.method == 'setDataSource') {
        ids.add(args?['textureId']);
        final source = args?['dataSource'] as Map;
        sources.add(source['uri'] as String);
        scheduleMicrotask(
          () => emit('initialized', {
            'duration': 30000,
            'width': 320.0,
            'height': 180.0,
          }),
        );
      }
      if (call.method == 'play') plays.add(args?['textureId']);
      if (call.method == 'pause') pauses.add(args?['textureId']);
      if (call.method == 'position') return 0;
      return null;
    });
    messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(connectivityStatus, (_) async => null);
  }

  void emit(String event, [Map<String, Object?> extra = const {}]) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.handlePlatformMessage(
      eventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': event,
        ...extra,
      }),
      (_) {},
    );
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
    messenger.setMockMethodCallHandler(connectivity, null);
    messenger.setMockMethodCallHandler(connectivityStatus, null);
  }
}

void main() {
  testWidgets(
    'PiP keeps one texture across episodes and stops advancing when closed',
    (tester) async {
      final platform = _NativePlayer()..install();
      addTearDown(platform.uninstall);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      final directory = Directory.systemTemp.createTempSync('guoguo-pip-');
      File('${directory.path}/pip_episode_1.mp4').createSync();
      File('${directory.path}/pip_episode_2.mp4').createSync();
      File('${directory.path}/pip_episode_3.mp4').createSync();
      File('${directory.path}/pip_episode_4.mp4').createSync();
      addTearDown(() => directory.deleteSync(recursive: true));
      final downloads = _LocalDownloads(store, directory.path);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: '1',
              source: DramaSource.hongguo,
              title: '剧',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
              Episode.fromJson({'id': '2'}, 1),
              Episode.fromJson({'id': '3'}, 2),
              Episode.fromJson({'id': '4'}, 3),
            ],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.sources, hasLength(1));
      expect(platform.plays, hasLength(1));

      platform.emit('pipStart');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      platform.emit('completed');
      platform.emit(
        'completed',
      ); // A duplicate completion must not skip episode 2.
      await tester.pumpAndSettle();

      expect(platform.sources, hasLength(2));
      expect(platform.sources.last, contains('pip_episode_2.mp4'));
      expect(platform.ids, [7, 7]);
      expect(platform.plays, hasLength(2));
      // A transient resume does not end PiP until native reports pipStop.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      store.prefetch = false;
      platform.emit('completed');
      await tester.pumpAndSettle();
      expect(platform.sources.last, contains('pip_episode_3.mp4'));
      expect(platform.ids, [7, 7, 7]);
      expect(platform.plays, hasLength(3));
      store.prefetch = true;
      platform.emit('play');
      await tester.pump(); // Arm the delayed prefetch before closing PiP.
      final pausesBeforeClose = platform.pauses.length;
      platform.emit('pipStop');
      await tester.pump(const Duration(seconds: 3));
      expect(platform.pauses.length, greaterThan(pausesBeforeClose));
      expect(downloads.requestedIds, isNot(contains('4')));
      final playsBeforeCompletion = platform.plays.length;
      platform.emit('completed');
      await tester.pumpAndSettle();
      expect(platform.sources, hasLength(3));
      expect(platform.plays, hasLength(playsBeforeCompletion));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
