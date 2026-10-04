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
  bool failPicker = false, routed = false, active = false;
  String? nativeUrl;
  int nativeRevision = 0;
  Completer<void>? releaseGate;

  Future<void> open({bool showPicker = true}) => session.open(
    sourceKey: key,
    source: castSource(),
    install: (url) async {
      installed.add(url);
      nativeUrl = url;
      nativeRevision++;
      return true;
    },
    showPicker: showPicker,
  );

  Future<void> emit(
    int texture,
    bool external, {
    bool route = false,
    int? revision,
    String? url,
  }) async {
    active = external;
    routed = route || external;
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('externalPlaybackChanged', {
          'textureId': texture,
          'active': external,
          'routed': routed,
          'sourceUrl': url ?? nativeUrl,
          'sourceRevision': revision ?? nativeRevision,
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
    failPicker = routed = active = false;
    nativeUrl = null;
    nativeRevision = 0;
    releaseGate = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getAirPlayState' || call.method == 'prepareAirPlay') {
        return {
          'active': active,
          'routed': routed,
          'sourceUrl': nativeUrl,
          'sourceRevision': nativeRevision,
        };
      }
      if (call.method == 'releaseAirPlay') {
        await releaseGate?.future;
        nativeUrl = null;
        nativeRevision++;
      }
      if (call.method == 'showAirPlayRoutes' && failPicker) {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    session = AirPlaySession(
      relayFactory: () => relay,
      connectionTimeout: const Duration(milliseconds: 10),
    )..textureId = 7;
  });
  tearDown(() async {
    await session.close();
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'inherited audio route is read before native player creation without claiming video connected',
    () async {
      session.textureId = null;
      routed = true;
      await session.refreshRoute();
      expect(session.routed, true);
      expect(session.active, false);
      expect(session.hasSource, false);
      expect(relay.starts, 0);
    },
  );

  test(
    'route picker reuses installed source and ignores other players',
    () async {
      await open();
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
    'next episode retains connection and closes old relay only after native replacement',
    () async {
      await open();
      await emit(7, true);
      final old = relay;
      relay = FakeCastRelay();
      final gate = Completer<bool>();
      key = Object();
      final pending = session.open(
        sourceKey: key,
        source: castSource(),
        install: (_) => gate.future,
        showPicker: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.routed, true);
      expect(old.closes, 0);
      gate.complete(true);
      await pending;
      expect(old.closes, 1);
      expect(relay.closes, 0);
      expect(calls.where((c) => c == 'releaseAirPlay'), isEmpty);
      expect(calls.where((c) => c == 'showAirPlayRoutes'), hasLength(1));
    },
  );

  test(
    'release waits for pending installation then detaches native before closing relay',
    () async {
      final gate = Completer<bool>();
      final pending = session.open(
        sourceKey: key,
        source: castSource(),
        install: (_) => gate.future,
      );
      await Future<void>.delayed(Duration.zero);
      final failure = expectLater(pending, throwsA(isA<CastCancelled>()));
      releaseGate = Completer<void>();
      final release = session.release();
      expect(relay.closes, 0);
      gate.complete(true);
      await failure;
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['releaseAirPlay']);
      expect(relay.closes, 0);
      releaseGate!.complete();
      await release;
      expect(relay.closes, 1);
      expect(session.hasSource, false);
    },
  );

  test(
    'older source callbacks cannot change current route or mark another video connected',
    () async {
      await open();
      await emit(7, true, revision: 3);
      await emit(7, false, revision: 2);
      expect(session.routed, true);
      expect(session.active, true);
      await emit(7, true, revision: 3, url: 'http://192.168.1.2/old.mp4');
      expect(session.active, false);
      expect(session.routed, true);
    },
  );

  test(
    'cancelled relay startup is cleaned without installing old media',
    () async {
      relay.startGate = Completer<String>();
      final pending = open();
      await Future<void>.delayed(Duration.zero);
      final failure = expectLater(pending, throwsA(isA<CastCancelled>()));
      final release = session.release();
      relay.startGate!.complete('http://192.168.1.2/old.mp4');
      await failure;
      await release;
      expect(installed, isEmpty);
      expect(relay.closes, 1);
      expect(session.preparing, false);
    },
  );

  test(
    'failed or superseded installation keeps URL until native consumer is detached',
    () async {
      await expectLater(
        session.open(
          sourceKey: key,
          source: castSource(),
          install: (_) async => false,
        ),
        throwsA(isA<CastCancelled>()),
      );
      expect(relay.closes, 0);
      await session.release();
      expect(relay.closes, 1);
    },
  );

  test(
    'picker failure retains source and retry does not reload video',
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
    'new episode supersedes a pending install without releasing the connection or showing old routes',
    () async {
      final old = relay;
      final gate = Completer<bool>();
      final first = session.open(
        sourceKey: key,
        source: castSource(),
        install: (_) => gate.future,
      );
      await Future<void>.delayed(Duration.zero);
      final cancelled = expectLater(first, throwsA(isA<CastCancelled>()));
      relay = FakeCastRelay();
      key = Object();
      final next = open(showPicker: false);
      expect(old.closes, 0);
      gate.complete(true);
      await cancelled;
      await next;
      expect(old.closes, 1);
      expect(relay.closes, 0);
      expect(calls, ['prepareAirPlay']);
      expect(session.preparing, false);
      expect(session.hasSource, true);
    },
  );

  test(
    'exit waits for ordinary native source setup before detaching and does not pretend the system route is local',
    () async {
      await open();
      await emit(7, true);
      final nativeSetup = Completer<void>();
      final closing = session.close(after: nativeSetup.future);
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNot(contains('releaseAirPlay')));
      expect(relay.closes, 0);
      nativeSetup.complete();
      await closing;
      expect(calls.last, 'releaseAirPlay');
      expect(relay.closes, 1);
      expect(session.routed, true);
      expect(session.active, false);
    },
  );

  test(
    'disposing the previous page cannot remove the new player route subscription',
    () async {
      final old = session;
      session = AirPlaySession(relayFactory: FakeCastRelay.new)..textureId = 8;
      old.dispose();
      await old.close();
      await emit(8, false, route: true);
      expect(session.routed, true);
      expect(session.active, false);
    },
  );

  test(
    'returning to an old episode after a cancelled replacement must reinstall its media',
    () async {
      final original = key;
      await open();
      await expectLater(
        session.open(
          sourceKey: Object(),
          source: castSource(),
          install: (_) async => false,
        ),
        throwsA(isA<CastCancelled>()),
      );
      key = original;
      await open(showPicker: false);
      expect(relay.starts, 3);
      expect(installed, hasLength(2));
    },
  );

  test('repeated taps share the same pending operation', () async {
    final gate = Completer<bool>();
    final pending = session.open(
      sourceKey: key,
      source: castSource(),
      install: (_) => gate.future,
    );
    await Future<void>.delayed(Duration.zero);
    final repeat = open();
    gate.complete(true);
    await Future.wait([pending, repeat]);
    expect(relay.starts, 1);
    expect(calls, ['prepareAirPlay', 'showAirPlayRoutes']);
  });

  test(
    'audio-only connection times out, while paused selection does not',
    () async {
      routed = true;
      await open();
      session.expectVideo(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(session.error, isNull);
      session.expectVideo(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(session.active, false);
      expect(session.error, contains('视频'));
      await emit(7, true);
      expect(session.error, isNull);
    },
  );
}
