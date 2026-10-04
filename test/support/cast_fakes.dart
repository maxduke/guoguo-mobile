import 'dart:async';

import 'package:guoguo_mobile/platform/cast_session.dart';
import 'package:guoguo_mobile/platform/cast_receivers.dart';
import 'package:guoguo_mobile/domain/models.dart';

class FakeCastRelay implements CastRelayHandle {
  int starts = 0, closes = 0;
  Completer<String>? startGate;
  @override
  Future<String> start(ResolvedMedia media, String? localPath) async {
    starts++;
    return await startGate?.future ?? 'http://192.168.1.2:8080/token/0.mp4';
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

class FakeCastReceiver implements CastReceiver {
  @override
  String get name => '客厅电视';
  CastPlayback playback = const CastPlayback(
    position: Duration(seconds: 12),
    duration: Duration(seconds: 120),
    state: CastPlaybackState.playing,
  );
  final calls = <String>[];
  Completer<void>? connectGate, loadGate, pauseGate;
  Completer<CastPlayback>? statusGate;
  bool failLoad = false, failStop = false, failStatus = false;
  CastSource? loadedSource;
  String? loadedUrl;
  int polls = 0, activePolls = 0, maxPolls = 0, closes = 0;
  @override
  Future<void> connect() async {
    calls.add('connect');
    await connectGate?.future;
  }

  @override
  Future<void> load(String url, CastSource source) async {
    calls.add('load');
    loadedSource = source;
    loadedUrl = url;
    await loadGate?.future;
    if (failLoad) throw StateError('load rejected');
  }

  @override
  Future<CastPlayback> status() async {
    calls.add('status');
    polls++;
    activePolls++;
    if (activePolls > maxPolls) maxPolls = activePolls;
    try {
      if (failStatus) throw StateError('status unsupported');
      return await statusGate?.future ?? playback;
    } finally {
      activePolls--;
    }
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    await pauseGate?.future;
    playback = CastPlayback(
      position: playback.position,
      duration: playback.duration,
      state: CastPlaybackState.paused,
    );
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playback = CastPlayback(
      position: playback.position,
      duration: playback.duration,
      state: CastPlaybackState.playing,
    );
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failStop) throw StateError('stop rejected');
  }

  @override
  Future<void> close() async {
    closes++;
  }

  CastTarget get target => CastTarget('fake:tv', name, '测试接收端', () => this);
}

class FakeCastDiscovery extends CastDiscovery {
  FakeCastDiscovery(this.receiver);
  final FakeCastReceiver receiver;
  int searches = 0;
  bool disposed = false;
  @override
  List<CastTarget> get devices => [receiver.target];
  @override
  bool get loading => false;
  @override
  String? get error => null;
  @override
  Future<void> refresh() async {
    searches++;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

CastSource castSource({bool playing = true, int position = 10}) => CastSource(
  media: ResolvedMedia.fromJson({
    'url': 'https://example.test/video.mp4',
    'remoteUrl': 'https://example.test/video.mp4',
  }),
  title: '测试作品 · 第 1 集',
  position: Duration(seconds: position),
  duration: const Duration(seconds: 120),
  playing: playing,
);
