import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/airplay_session.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';

import 'support/cast_fakes.dart';

class DelayedCloseRelay extends FakeCastRelay {
  Completer<void>? closeGate;
  @override
  Future<void> close() async {
    await closeGate?.future;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('guoguo/airplay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AirPlaySession session;
  late List<MethodCall> calls;
  late List<FakeCastRelay> relays;
  late List<int> loads;
  late List<Set<int>> retained;
  bool advance = true, route = false, failClose = false, failNext = false;
  Completer<CastSource>? sourceGate;
  Completer<void>? nativeGate;
  int sequence = 0;
  String? identity;

  Future<void> emit({
    int index = 0,
    bool closed = false,
    bool ended = false,
    bool needsNext = false,
    String? id,
    int? revision,
  }) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('state', {
          'sessionId': id ?? identity,
          'sequence': revision ?? ++sequence,
          'itemId': '$index',
          'positionMs': ended ? 120000 : 42000,
          'durationMs': 120000,
          'playing': !closed && !ended,
          'active': route && !closed,
          'routed': route,
          'closed': closed,
          'ended': ended,
          'needsNext': needsNext,
        }),
      ),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> open({bool playing = true}) => session.start(
    initialIndex: 0,
    initialPosition: const Duration(seconds: 10),
    initialPlaying: playing,
    speed: 1.5,
  );

  setUp(() {
    calls = [];
    relays = [];
    loads = [];
    retained = [];
    advance = true;
    route = failClose = failNext = false;
    sourceGate = null;
    nativeGate = null;
    identity = null;
    sequence = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getState') return {'routed': route};
      if (call.method == 'open') {
        identity = (call.arguments as Map)['sessionId'] as String;
        await nativeGate?.future;
      }
      if (call.method == 'close') {
        await nativeGate?.future;
        if (failClose) throw PlatformException(code: 'stop_failed');
      }
      return null;
    });
    session = AirPlaySession(
      loadSource: (index) async {
        loads.add(index);
        if (index == 1 && failNext) throw StateError('source failed');
        return await sourceGate?.future ?? castSource();
      },
      retainSources: (indices) => retained.add(indices),
      episodeCount: 3,
      autoAdvance: () => advance,
      relayFactory: () {
        final relay = DelayedCloseRelay();
        relays.add(relay);
        return relay;
      },
    );
  });
  tearDown(() async {
    failClose = false;
    nativeGate = null;
    await session.close();
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'independent native player receives current and upcoming item without a texture',
    () async {
      await open(playing: false);
      await Future<void>.delayed(Duration.zero);
      expect(loads, [0, 1]);
      expect(calls.map((c) => c.method), ['open', 'append']);
      final args = calls.first.arguments as Map;
      expect(args.containsKey('textureId'), false);
      expect(args['positionMs'], 10000);
      expect(args['playing'], false);
      expect(args['speed'], 1.5);
      expect(session.index, 0);
      expect(relays[0].closes, 0);
      expect(relays[1].closes, 0);
      route = true;
      await emit(index: 1, needsNext: true);
      expect(session.index, 1);
      expect(loads, [0, 1, 2]);
      expect(relays[0].closes, 1);
      expect(relays[1].closes, 0);
      expect(retained.last, {1, 2});
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
    },
  );

  test(
    'real end before next preparation finishes keeps predecessor and appends once',
    () async {
      advance = false;
      await open();
      advance = true;
      sourceGate = Completer();
      await emit(ended: true, needsNext: true);
      await emit(ended: true, needsNext: true);
      expect(loads, [0, 1]);
      expect(relays.single.closes, 0);
      expect(retained.last, {0, 1});
      sourceGate!.complete(castSource());
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'append'), hasLength(1));
      expect((calls.last.arguments as Map)['afterId'], '0');
      expect(
        session.index,
        0,
      ); // Only the native item-change event advances it.
    },
  );

  test(
    'auto advance disabled and final episode do not load another source',
    () async {
      advance = false;
      await open();
      await emit(ended: true, needsNext: true);
      expect(loads, [0]);
      advance = true;
      await emit(index: 2, ended: true, needsNext: true);
      expect(loads, [0]);
    },
  );

  test('manual next overrides auto advance off', () async {
    advance = false;
    await open();
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('requestNext', {'sessionId': identity, 'afterId': '0'}),
      ),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
    expect(loads, [0, 1]);
    expect(calls.last.method, 'append');
  });

  test(
    'old sessions and out of order native state cannot change the current episode',
    () async {
      advance = false;
      await open();
      route = true;
      await emit(index: 1, revision: 5);
      await emit(index: 0, revision: 4);
      await emit(index: 2, id: 'previous-page', revision: 99);
      expect(session.index, 1);
      expect(session.active, true);
    },
  );

  test(
    'close waits for submitted open before closing receiver media',
    () async {
      advance = false;
      nativeGate = Completer();
      final pending = open();
      await Future<void>.delayed(Duration.zero);
      final failure = expectLater(pending, throwsA(isA<CastCancelled>()));
      final closing = session.close();
      expect(relays.single.closes, 0);
      nativeGate!.complete();
      await failure;
      await closing;
      expect(calls.map((c) => c.method), ['open', 'close']);
      expect(relays.single.closes, 1);
      expect(retained.last, isEmpty);
    },
  );

  test('cancelled preparation never submits native open or append', () async {
    sourceGate = Completer();
    final pending = open();
    await Future<void>.delayed(Duration.zero);
    final failure = expectLater(pending, throwsA(isA<CastCancelled>()));
    await session.close();
    sourceGate!.complete(castSource());
    await failure;
    expect(relays, isEmpty);
    expect(calls.where((c) => c.method == 'open'), isEmpty);
  });

  test(
    'a late cancelled startup cannot remove a new session media lease',
    () async {
      advance = false;
      sourceGate = Completer();
      final oldSource = sourceGate!;
      final old = open();
      await Future<void>.delayed(Duration.zero);
      final failure = expectLater(old, throwsA(isA<CastCancelled>()));
      await session.close();
      sourceGate = null;
      await open();
      oldSource.complete(castSource());
      await failure;
      expect(relays.single.closes, 0);
      await session.close();
      expect(relays.single.closes, 1);
    },
  );

  test('slow outgoing cleanup cannot evict the newer current video', () async {
    await open();
    await Future<void>.delayed(Duration.zero);
    final outgoing = relays.first as DelayedCloseRelay;
    outgoing.closeGate = Completer();
    await emit(index: 1, needsNext: true);
    await emit(index: 2);
    expect(retained.last, {2});
    outgoing.closeGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(retained.last, {2});
    expect(relays[2].closes, 0);
  });

  test('failed native stop retains receiver URLs and permits retry', () async {
    advance = false;
    await open();
    failClose = true;
    await expectLater(session.close(), throwsA(isA<PlatformException>()));
    expect(relays.single.closes, 0);
    expect(session.blocksLocal, true);
    failClose = false;
    await session.close();
    expect(relays.single.closes, 1);
  });

  test(
    'next-source failure reports once instead of endlessly retrying progress events',
    () async {
      failNext = true;
      await open();
      await Future<void>.delayed(Duration.zero);
      await emit(needsNext: true);
      await emit(needsNext: true);
      expect(loads, [0, 1]);
      expect(session.error, contains('下一集准备失败'));
      expect(calls.where((c) => c.method == 'reportError'), hasLength(1));
      expect(relays.single.closes, 0);
    },
  );

  test(
    'route remains separate from native closure and a new page keeps channel ownership',
    () async {
      advance = false;
      await open();
      route = true;
      await emit(closed: true);
      expect(session.engaged, false);
      expect(session.routed, true);
      expect(session.blocksLocal, true);
      expect(session.position.inSeconds, 42);
      final next = AirPlaySession(
        loadSource: (_) async => castSource(),
        retainSources: (_) {},
        episodeCount: 1,
        autoAdvance: () => false,
        relayFactory: FakeCastRelay.new,
      );
      await session.close();
      session.dispose();
      final done = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('state', {'sessionId': '', 'routed': true}),
        ),
        (_) => done.complete(),
      );
      await done.future;
      expect(next.routed, true);
      await next.close();
      next.dispose();
    },
  );
}
