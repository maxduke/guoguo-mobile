import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/airplay_session.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';

import 'support/cast_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('guoguo/airplay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AirPlaySession session;
  late FakeCastRelay relay;
  late List<String> calls;
  late Object key;
  late List<String> installed;
  bool failPicker = false;

  Future<void> open({bool showPicker = true}) => session.open(
    sourceKey: key,
    source: castSource(),
    install: (url) async {
      installed.add(url);
      return true;
    },
    showPicker: showPicker,
  );

  Future<void> emit(int texture, bool active, {bool routed = false}) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('externalPlaybackChanged', {
          'textureId': texture,
          'active': active,
          'routed': routed,
        }),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() {
    relay = FakeCastRelay();
    calls = [];
    installed = [];
    key = Object();
    failPicker = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect((call.arguments as Map)['textureId'], 7);
      calls.add(call.method);
      if (call.method == 'prepareAirPlay') {
        return {'active': false, 'routed': false};
      }
      if (call.method == 'showAirPlayRoutes' && failPicker) {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    session = AirPlaySession(relayFactory: () => relay)..textureId = 7;
  });
  tearDown(() {
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'an inherited system audio route cannot opt an unprepared player into AirPlay',
    () async {
      await emit(7, false, routed: true);
      expect(session.routed, false);
      expect(session.active, false);
      expect(relay.starts, 0);
    },
  );

  test(
    'install reachable media before route selection and reuse after returning to phone',
    () async {
      await open();
      expect(installed, ['http://192.168.1.2:8080/token/0.mp4']);
      expect(calls, ['prepareAirPlay', 'showAirPlayRoutes']);
      await emit(8, true);
      expect(session.active, false);
      await emit(7, true);
      expect(session.active, true);
      await emit(7, false);
      expect(session.active, false);
      await open();
      expect(relay.starts, 1);
      expect(relay.closes, 0);
      expect(installed.length, 1);
    },
  );

  test(
    'next episode prepares native playback without reopening route picker',
    () async {
      await open(showPicker: false);
      expect(calls, ['prepareAirPlay']);
    },
  );

  test('reset rejects late route callbacks for the previous source', () async {
    await open();
    await emit(7, true);
    await session.reset();
    await emit(7, true, routed: true);
    expect(session.routed, false);
    expect(session.active, false);
    expect(relay.closes, 1);
  });

  test(
    'source replacement cancels pending relay and never presents old routes',
    () async {
      relay.startGate = Completer<String>();
      final pending = open();
      await Future<void>.delayed(Duration.zero);
      final failure = expectLater(pending, throwsA(isA<CastCancelled>()));
      final reset = session.reset();
      relay.startGate!.complete('http://192.168.1.2/old.mp4');
      await failure;
      await reset;
      expect(calls, isEmpty);
      expect(installed, isEmpty);
      expect(relay.closes, 1);
      expect(session.preparing, false);
    },
  );

  test('superseded installation closes unused relay', () async {
    await expectLater(
      session.open(
        sourceKey: key,
        source: castSource(),
        install: (_) async => false,
      ),
      throwsA(isA<CastCancelled>()),
    );
    expect(relay.closes, 1);
    expect(calls, isEmpty);
  });

  test(
    'picker failure retains active source and retry does not reload video',
    () async {
      failPicker = true;
      await expectLater(open(), throwsA(isA<PlatformException>()));
      expect(relay.closes, 0);
      failPicker = false;
      await open();
      expect(relay.starts, 1);
      expect(installed.length, 1);
    },
  );

  test(
    'repeated taps cannot create competing sources during installation',
    () async {
      final gate = Completer<bool>();
      final pending = session.open(
        sourceKey: key,
        source: castSource(),
        install: (_) => gate.future,
      );
      await Future<void>.delayed(Duration.zero);
      await open();
      expect(relay.starts, 1);
      gate.complete(true);
      await pending;
      expect(calls, ['prepareAirPlay', 'showAirPlayRoutes']);
    },
  );
}
