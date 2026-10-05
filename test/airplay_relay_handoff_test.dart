import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/airplay_session.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';
import 'package:guoguo_mobile/platform/casting.dart';

class RecordedRelay extends CastRelay {
  RecordedRelay(this.onStart)
    : super(addressResolver: (_) async => InternetAddress.loopbackIPv4);
  final void Function(String) onStart;
  @override
  Future<String> start(
    ResolvedMedia media,
    String? localPath, {
    Uri? receiver,
  }) async {
    final url = await super.start(media, localPath, receiver: receiver);
    onStart(url);
    return url;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('guoguo/airplay');
  test(
    'current-item promotion alone must not revoke the predecessor HTTP URL',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'airplay-handoff-',
      );
      for (var i = 1; i <= 2; i++) {
        await File(
          '${directory.path}/episode-$i.mp4',
        ).writeAsBytes(List.filled(1024, i));
      }
      final originalHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? id;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'open') {
          id = (call.arguments as Map)['sessionId'] as String;
        }
        return null;
      });
      final urls = <String>[];
      final ready = Completer<void>();
      final session = AirPlaySession(
        loadSource: (i) async {
          final path = '${directory.path}/episode-${i + 1}.mp4';
          return CastSource(
            media: ResolvedMedia.fromJson({
              'url': Uri.file(path).toString(),
              'remoteUrl': '',
            }),
            localPath: path,
            title: 'episode ${i + 1}',
            position: Duration.zero,
            duration: Duration.zero,
            playing: true,
          );
        },
        retainSources: (_) {},
        episodeCount: 2,
        autoAdvance: () => true,
        relayFactory: () => RecordedRelay((url) {
          urls.add(url);
          if (urls.length == 2 && !ready.isCompleted) ready.complete();
        }),
      );
      addTearDown(() async {
        await session.close();
        session.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        HttpOverrides.global = originalHttp;
        await directory.delete(recursive: true);
      });
      await session.start(
        initialIndex: 0,
        initialPosition: Duration.zero,
        initialPlaying: true,
        speed: 1,
      );
      await ready.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final initial = await (await client.headUrl(
        Uri.parse(urls.first),
      )).close();
      expect(initial.statusCode, 200);
      await initial.drain<void>();
      final done = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('state', {
            'sessionId': id,
            'sequence': 1,
            'itemId': '1',
            'positionMs': 0,
            'durationMs': 0,
            'playing': true,
            'active': true,
            'routed': true,
            'closed': false,
            'ended': false,
            'needsNext': true,
            'retainedItemIds': ['0', '1'],
          }),
        ),
        (_) => done.complete(),
      );
      await done.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      var predecessorReadable = false;
      try {
        final old = await (await client.headUrl(Uri.parse(urls.first))).close();
        predecessorReadable = old.statusCode == 200;
        await old.drain<void>();
      } on SocketException {
        /* Expected base-code regression. */
      }
      expect(
        predecessorReadable,
        true,
        reason:
            'Next item is only promoted, with zero duration/progress; receiver handoff is not yet confirmed.',
      );
      final confirmed = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('state', {
            'sessionId': id,
            'sequence': 2,
            'itemId': '1',
            'positionMs': 3000,
            'durationMs': 120000,
            'playing': true,
            'active': true,
            'routed': true,
            'closed': false,
            'ended': false,
            'needsNext': false,
            'retainedItemIds': ['1'],
          }),
        ),
        (_) => confirmed.complete(),
      );
      await confirmed.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(() async {
        final request = await client.headUrl(Uri.parse(urls.first));
        await request.close();
      }(), throwsA(isA<SocketException>()));
      final current = await (await client.headUrl(Uri.parse(urls[1]))).close();
      expect(current.statusCode, 200);
      await current.drain<void>();
    },
  );
}
