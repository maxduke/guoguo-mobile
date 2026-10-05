import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';

import 'support/cast_fakes.dart';

class DiagnosticRelay extends FakeCastRelay implements CastRelayDiagnostics {
  @override
  bool mediaRequested = false;
  @override
  int bytesSent = 0;
  @override
  String? transferError;
}

class CancellableReceiver extends FakeCastReceiver
    implements CastLoadCancellation {
  int cancellations = 0;
  @override
  void cancelLoad() {
    cancellations++;
    if (connectGate?.isCompleted == false) connectGate!.complete();
  }
}

void main() {
  late FakeCastReceiver receiver;
  late FakeCastRelay relay;
  late CastSessionController session;
  late List<CastHandoff> returns;
  late CastSource source;
  late int pauses;
  setUp(() {
    receiver = FakeCastReceiver();
    relay = FakeCastRelay();
    returns = [];
    pauses = 0;
    source = castSource();
    session = CastSessionController(
      captureSource: () => source,
      pauseLocal: () async {
        pauses++;
      },
      returnLocal: (value) async {
        returns.add(value);
      },
      relayFactory: () => relay,
    );
  });
  tearDown(() => session.dispose());
  test(
    'cancel request interrupts a receiver load rather than waiting for timeout',
    () async {
      final cancellable = CancellableReceiver()
        ..connectGate = Completer<void>();
      receiver = cancellable;
      final starting = session.start(receiver.target);
      await Future<void>.delayed(Duration.zero);
      final stopping = session.stop();
      await Future.wait([starting, stopping]);
      expect(cancellable.cancellations, greaterThan(0));
      expect(receiver.calls, isNot(contains('load')));
      expect(returns, hasLength(1));
    },
  );

  test(
    'receiver endpoint reaches address selection and a no-fetch failure is actionable',
    () async {
      relay = DiagnosticRelay();
      receiver.failLoad = true;
      final endpoint = Uri.parse('http://192.168.1.3/control');
      await session.start(
        CastTarget('tv', '电视', 'DLNA', () => receiver, receiver: endpoint),
      );
      expect(relay.receiverAddress, endpoint);
      expect(session.error, contains('电视尚未读取视频'));
      expect(session.error, contains('本地网络权限'));
      expect(returns, hasLength(1));
    },
  );
  test(
    'transport failure is retained after cleanup and differs from receiver decoding failure',
    () async {
      final diagnostic = DiagnosticRelay()
        ..mediaRequested = true
        ..transferError = '视频源返回 403';
      relay = diagnostic;
      receiver.failLoad = true;
      await session.start(receiver.target);
      expect(session.error, contains('视频源返回 403'));
      expect(relay.closes, 1);
      diagnostic.transferError = null;
      diagnostic.bytesSent = 1024;
      await session.start(receiver.target);
      expect(session.error, contains('电视已读取视频，但未确认播放'));
      expect(returns, hasLength(2));
    },
  );

  test(
    'source is captured at device choice and TV receives actual position and pause intent',
    () async {
      source = castSource(position: 42, playing: false);
      receiver.playback = const CastPlayback(
        position: Duration(seconds: 42),
        state: CastPlaybackState.paused,
      );
      await session.start(receiver.target);
      expect(receiver.loadedSource!.position, const Duration(seconds: 42));
      expect(receiver.loadedSource!.playing, false);
      expect(pauses, 1);
      expect(session.phase, CastPhase.connected);
      expect(session.blocksLocal, true);
      expect(returns, isEmpty);
    },
  );
  test(
    'stop samples final TV progress before stop resets it and preserves paused state',
    () async {
      await session.start(receiver.target);
      receiver.playback = const CastPlayback(
        position: Duration(seconds: 57),
        duration: Duration(seconds: 120),
        state: CastPlaybackState.paused,
      );
      await session.stop();
      expect(returns.single.position, const Duration(seconds: 57));
      expect(returns.single.playing, false);
      expect(session.blocksLocal, false);
      expect(receiver.calls.sublist(receiver.calls.length - 2), [
        'status',
        'stop',
      ]);
      expect(receiver.closes, 1);
      expect(relay.closes, 1);
    },
  );
  test(
    'receiver without time support returns original position without inventing progress',
    () async {
      receiver.playback = const CastPlayback();
      await session.start(receiver.target);
      expect(session.reportedPosition, isNull);
      await session.stop();
      expect(returns.single.position, const Duration(seconds: 10));
      expect(returns.single.playing, true);
    },
  );
  test(
    'read failures preserve last real progress and do not start phone automatically',
    () async {
      await session.start(receiver.target);
      receiver.failStatus = true;
      await session.refresh();
      expect(session.error, isNotNull);
      expect(session.reportedPosition, const Duration(seconds: 12));
      expect(returns, isEmpty);
      await session.stop();
      expect(returns.single.position, const Duration(seconds: 12));
    },
  );
  test(
    'a failed stop retains relay and local hold, allowing a single retry',
    () async {
      await session.start(receiver.target);
      receiver.failStop = true;
      await session.stop();
      expect(session.phase, CastPhase.failed);
      expect(session.blocksLocal, true);
      expect(relay.closes, 0);
      expect(returns, isEmpty);
      receiver.failStop = false;
      await session.stop();
      expect(returns, hasLength(1));
      expect(relay.closes, 1);
      expect(session.blocksLocal, false);
    },
  );
  test(
    'load failure restores the original phone position only after acknowledged stop',
    () async {
      receiver.failLoad = true;
      await session.start(receiver.target);
      expect(receiver.calls, contains('stop'));
      expect(returns.single.position, const Duration(seconds: 10));
      expect(session.error, contains('投屏未成功'));
      expect(session.phase, CastPhase.idle);
    },
  );
  test(
    'ambiguous failed load and stop keep phone paused until stop succeeds',
    () async {
      receiver
        ..failLoad = true
        ..failStop = true;
      await session.start(receiver.target);
      expect(returns, isEmpty);
      expect(session.phase, CastPhase.failed);
      expect(relay.closes, 0);
      receiver.failStop = false;
      await session.stop();
      expect(returns, hasLength(1));
    },
  );
  test('cancel pending connection skips media load and returns once', () async {
    receiver.connectGate = Completer();
    final starting = session.start(receiver.target);
    await Future<void>.delayed(Duration.zero);
    final stopping = session.stop();
    receiver.connectGate!.complete();
    await Future.wait([starting, stopping]);
    expect(receiver.calls, isNot(contains('load')));
    expect(returns, hasLength(1));
    expect(session.blocksLocal, false);
  });
  test(
    'dispose during relay start releases resources and rejects late playback takeover',
    () async {
      relay.startGate = Completer();
      final starting = session.start(receiver.target);
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      relay.startGate!.complete('http://192.168.1.2/late');
      await starting;
      expect(receiver.calls, isNot(contains('load')));
      expect(returns, isEmpty);
      expect(relay.closes, 1);
      expect(receiver.closes, 1);
    },
  );
  test(
    'late status after disposal cannot overwrite progress or return to phone',
    () async {
      await session.start(receiver.target);
      receiver.statusGate = Completer();
      final refreshing = session.refresh();
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      receiver.statusGate!.complete(
        const CastPlayback(position: Duration(seconds: 90)),
      );
      await refreshing;
      expect(session.reportedPosition, const Duration(seconds: 12));
      expect(returns, isEmpty);
    },
  );
  test('polls do not overlap and stop waits for one in flight', () async {
    await session.start(receiver.target);
    receiver.statusGate = Completer();
    final refreshing = session.refresh();
    await Future<void>.delayed(Duration.zero);
    await session.refresh();
    final stopping = session.stop();
    receiver.statusGate!.complete(
      const CastPlayback(
        position: Duration(seconds: 60),
        state: CastPlaybackState.playing,
      ),
    );
    await Future.wait([refreshing, stopping]);
    expect(receiver.maxPolls, 1);
    expect(returns.single.position, const Duration(seconds: 60));
  });
  test(
    'commands serialize behind status and repeat stop shares one completion',
    () async {
      await session.start(receiver.target);
      receiver.pauseGate = Completer();
      final pausing = session.setPlaying(false);
      await Future<void>.delayed(Duration.zero);
      final firstStop = session.stop(), secondStop = session.stop();
      receiver.pauseGate!.complete();
      await Future.wait([pausing, firstStop, secondStop]);
      expect(receiver.calls.where((call) => call == 'stop'), hasLength(1));
      expect(returns, hasLength(1));
    },
  );
  test(
    'background stops polling and foreground reads actual updated TV position',
    () async {
      await session.start(receiver.target);
      final polls = receiver.polls;
      session.setForeground(false);
      await session.refresh();
      expect(receiver.polls, polls);
      receiver.playback = const CastPlayback(position: Duration(seconds: 24));
      session.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.reportedPosition, const Duration(seconds: 24));
      expect(returns, isEmpty);
    },
  );
  test(
    'handoff clamps a receiver position beyond confirmed duration',
    () async {
      receiver.playback = const CastPlayback(
        position: Duration(seconds: 500),
        duration: Duration(seconds: 120),
        state: CastPlaybackState.stopped,
      );
      await session.start(receiver.target);
      await session.stop();
      expect(returns.single.position, const Duration(seconds: 120));
      expect(returns.single.playing, false);
    },
  );
}
