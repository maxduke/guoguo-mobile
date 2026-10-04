import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:http/http.dart' as http;

import 'cast_session.dart';
import 'casting.dart';
import 'provider_client.dart';

Duration? parseDlnaTime(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^(\d{1,4}):([0-5]\d):([0-5]\d)(?:\.(\d{1,3}))?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  return Duration(
    hours: int.parse(match[1]!),
    minutes: int.parse(match[2]!),
    seconds: int.parse(match[3]!),
    milliseconds: int.parse((match[4] ?? '0').padRight(3, '0')),
  );
}

String formatDlnaTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 35999999);
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
}

class DlnaCastReceiver implements CastReceiver {
  DlnaCastReceiver(DlnaDevice device, {http.Client? client})
    : _client = client ?? http.Client() {
    _device = DlnaDevice(
      device.name,
      device.control,
      device.serviceType,
      client: _client,
    );
  }
  final http.Client _client;
  late final DlnaDevice _device;
  String? _url;
  bool _closed = false;
  Future<void>? _stopping;
  bool _stopped = false;
  @override
  String get name => _device.name;
  void _check() {
    if (_closed) throw const CastCancelled();
  }

  @override
  Future<void> connect() async => _check();
  @override
  Future<void> load(String url, CastSource source) async {
    _check();
    _url = url;
    await _device.command('SetAVTransportURI', {
      'CurrentURI': url,
      'CurrentURIMetaData': '',
    });
    _check();
    // Most renderers cannot seek until the media has entered playback.
    await _device.command('Play', {'Speed': '1'});
    _check();
    if (source.position > Duration.zero) {
      await _device.command('Seek', {
        'Unit': 'REL_TIME',
        'Target': formatDlnaTime(source.position),
      });
      _check();
    }
    if (!source.playing) await pause();
  }

  @override
  Future<CastPlayback> status() async {
    _check();
    final position = await _device.command('GetPositionInfo', {});
    _check();
    final uri = position['TrackURI'];
    if (uri != null &&
        uri.isNotEmpty &&
        uri != 'NOT_IMPLEMENTED' &&
        uri != _url) {
      throw const ProviderException('电视已切换到其他媒体');
    }
    // Without a matching media identity, a time from another item is unsafe.
    final knownPosition = uri == _url
        ? parseDlnaTime(position['RelTime'])
        : null;
    final knownDuration = uri == _url
        ? parseDlnaTime(position['TrackDuration'])
        : null;
    var state = CastPlaybackState.unknown;
    try {
      final transport = await _device.command('GetTransportInfo', {});
      _check();
      state = switch (transport['CurrentTransportState']) {
        'PLAYING' => CastPlaybackState.playing,
        'PAUSED_PLAYBACK' => CastPlaybackState.paused,
        'TRANSITIONING' => CastPlaybackState.buffering,
        'STOPPED' || 'NO_MEDIA_PRESENT' => CastPlaybackState.stopped,
        _ => CastPlaybackState.unknown,
      };
    } on CastCancelled {
      rethrow;
    } catch (_) {
      // Keep a supported position even if this renderer lacks transport state.
    }
    return CastPlayback(
      position: knownPosition,
      duration: knownDuration,
      state: state,
    );
  }

  @override
  Future<void> pause() async {
    _check();
    await _checkMedia();
    _check();
    await _device.command('Pause', {});
  }

  @override
  Future<void> play() async {
    _check();
    await _checkMedia();
    _check();
    await _device.command('Play', {'Speed': '1'});
  }

  Future<bool> _hasOtherMedia() async {
    try {
      final position = await _device.command('GetPositionInfo', {});
      final uri = position['TrackURI'];
      return uri != null &&
          uri.isNotEmpty &&
          uri != 'NOT_IMPLEMENTED' &&
          uri != _url;
    } catch (_) {
      // A renderer without status support may still acknowledge controls.
      return false;
    }
  }

  Future<void> _checkMedia() async {
    if (await _hasOtherMedia()) {
      throw const ProviderException('电视已切换到其他媒体');
    }
  }

  @override
  Future<void> stop() {
    if (_url == null || _stopped) return Future.value();
    if (_stopping != null) return _stopping!;
    return _stopping = (() async {
      // Do not stop media another sender has installed in the meantime.
      if (!await _hasOtherMedia()) await _device.command('Stop', {});
      _stopped = true;
    })().whenComplete(() => _stopping = null);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _client.close();
  }
}

class GoogleCastReceiver implements CastReceiver {
  GoogleCastReceiver(
    this.device, {
    GoogleCastRemoteMediaClientPlatformInterface? remote,
    GoogleCastSessionManagerPlatformInterface? manager,
    MethodChannel channel = const MethodChannel(
      'google_cast.remote_media_client',
    ),
  }) : _remote = remote ?? GoogleCastRemoteMediaClient.instance,
       _manager = manager ?? GoogleCastSessionManager.instance,
       _channel = channel {
    _positions = _remote.playerPositionStream.listen((position) {
      final status = _remote.mediaStatus;
      if (_closed || !_matches(status)) return;
      if (status?.mediaSessionID == _previousMediaId) return;
      if (!_converged &&
          (position - _expected).abs() > const Duration(seconds: 5)) {
        return;
      }
      _converged = true;
      _sessionId ??= status?.mediaSessionID;
      if (status?.mediaSessionID == _sessionId && position >= Duration.zero) {
        _position = position;
      }
    });
  }
  final GoogleCastDevice device;
  final GoogleCastRemoteMediaClientPlatformInterface _remote;
  final GoogleCastSessionManagerPlatformInterface _manager;
  final MethodChannel _channel;
  late final StreamSubscription<Duration> _positions;
  String? _url;
  int? _previousMediaId, _sessionId;
  Duration _expected = Duration.zero;
  Duration? _position;
  bool _closed = false, _converged = false;
  Future<void>? _stopping;
  bool _stopped = false;
  @override
  String get name => device.friendlyName;
  bool get _ownsDevice =>
      _manager.currentSession?.device?.deviceID == device.deviceID;
  bool _matches(GoggleCastMediaStatus? status) =>
      _url != null &&
      (status?.mediaInformation?.contentId == _url ||
          status?.mediaInformation?.contentUrl?.toString() == _url);
  void _check() {
    if (_closed) throw const CastCancelled();
  }

  @override
  Future<void> connect() async {
    _check();
    if (!_ownsDevice ||
        _manager.connectionState != GoogleCastConnectState.connected) {
      if (!await _manager.startSessionWithDevice(device)) {
        throw const ProviderException('电视连接未启动');
      }
    }
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!_ownsDevice ||
        _manager.connectionState != GoogleCastConnectState.connected) {
      _check();
      if (DateTime.now().isAfter(deadline)) {
        throw const ProviderException('连接电视超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_closed) {
      await stop();
      throw const CastCancelled();
    }
  }

  @override
  Future<void> load(String url, CastSource source) async {
    _check();
    _previousMediaId = _remote.mediaStatus?.mediaSessionID;
    _expected = source.position;
    _url = url;
    final info = GoogleCastMediaInformation(
      contentId: url,
      contentUrl: Uri.parse(url),
      streamType: CastMediaStreamType.buffered,
      contentType: source.localPath == null && source.media.hls
          ? 'application/x-mpegURL'
          : 'video/mp4',
      metadata: GoogleCastMovieMediaMetadata(title: source.title),
    );
    // 1.4.8's Dart loadMedia drops the platform Future. Await the same verified
    // channel contract so errors are caught; receiver status confirms the load.
    await _channel.invokeMethod<void>('loadMedia', {
      ...info.toMap(),
      'autoPlay': source.playing,
      'playPosition': source.position.inSeconds,
      'playbackRate': 1.0,
    });
    final deadline = DateTime.now().add(const Duration(seconds: 18));
    while (!_matches(_remote.mediaStatus) ||
        !_converged ||
        !{
          CastMediaPlayerState.playing,
          CastMediaPlayerState.paused,
        }.contains(_remote.mediaStatus?.playerState)) {
      _check();
      if (_remote.mediaStatus?.idleReason == GoogleCastMediaIdleReason.error &&
          _matches(_remote.mediaStatus)) {
        throw const ProviderException('电视无法播放此视频');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const ProviderException('电视未确认播放位置，请重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _check();
  }

  @override
  Future<CastPlayback> status() async {
    _check();
    final status = _remote.mediaStatus;
    if (!_ownsDevice ||
        _manager.connectionState != GoogleCastConnectState.connected) {
      throw const ProviderException('与电视的连接已断开');
    }
    if (status == null ||
        !_matches(status) ||
        status.mediaSessionID != _sessionId) {
      throw const ProviderException('电视媒体状态已变化');
    }
    return CastPlayback(
      position: status.playerState == CastMediaPlayerState.idle
          ? null
          : _position,
      duration: status.mediaInformation?.duration,
      state: switch (status.playerState) {
        CastMediaPlayerState.playing => CastPlaybackState.playing,
        CastMediaPlayerState.paused => CastPlaybackState.paused,
        CastMediaPlayerState.buffering ||
        CastMediaPlayerState.loading => CastPlaybackState.buffering,
        CastMediaPlayerState.idle => CastPlaybackState.stopped,
        _ => CastPlaybackState.unknown,
      },
    );
  }

  @override
  Future<void> pause() async {
    await status();
    await _remote.pause();
  }

  @override
  Future<void> play() async {
    await status();
    await _remote.play();
  }

  @override
  Future<void> stop() {
    if (_stopped) return Future.value();
    if (_stopping != null) return _stopping!;
    return _stopping = _stop()
        .then((_) {
          _stopped = true;
        })
        .whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    if (!_ownsDevice) return;
    final status = _remote.mediaStatus;
    if (status != null &&
        _url != null &&
        (_sessionId != null
            ? !_matches(status) || status.mediaSessionID != _sessionId
            : status.mediaSessionID != _previousMediaId && !_matches(status))) {
      return;
    }
    // While our load is pending the receiver can still report its previous
    // media. End that session too, preventing the late load from starting.
    await _manager.endSessionAndStopCasting();
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (_ownsDevice &&
        _manager.connectionState == GoogleCastConnectState.connected) {
      if (DateTime.now().isAfter(deadline)) {
        throw const ProviderException('电视未确认结束');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _positions.cancel();
  }
}

abstract class CastDiscovery extends ChangeNotifier {
  List<CastTarget> get devices;
  bool get loading;
  String? get error;
  Future<void> refresh();
}

class DeviceCastDiscovery extends CastDiscovery {
  DeviceCastDiscovery({
    GoogleCastDiscoveryManagerPlatformInterface? google,
    Future<void> Function()? initialize,
    Future<List<DlnaDevice>> Function()? findDlna,
  }) : _google = google ?? GoogleCastDiscoveryManager.instance,
       _initialize = initialize ?? _initializeSdk,
       _findDlna = findDlna ?? discoverDlna;

  static Future<void>? _initialization;
  static Future<void> _discoveryCommands = Future.value();
  static final Set<DeviceCastDiscovery> _active = {};
  final GoogleCastDiscoveryManagerPlatformInterface _google;
  final Future<void> Function() _initialize;
  final Future<List<DlnaDevice>> Function() _findDlna;

  static Future<void> _initializeSdk() => _initialization ??= (() async {
    const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
    try {
      await GoogleCastContext.instance.setSharedInstanceWithOptions(
        Platform.isIOS
            ? IOSGoogleCastOptions(
                GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
                  appId,
                ),
                stopCastingOnAppTerminated: true,
              )
            : GoogleCastOptionsAndroid(
                appId: appId,
                stopCastingOnAppTerminated: true,
              ),
      );
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  })();

  static Future<void> _queueDiscovery(Future<void> Function() command) {
    final next = _discoveryCommands
        .catchError((Object _) {})
        .then((_) => command());
    _discoveryCommands = next;
    return next;
  }

  StreamSubscription<List<GoogleCastDevice>>? _subscription;
  final Map<String, CastTarget> _devices = {};
  bool _closed = false;
  @override
  bool loading = false;
  @override
  String? error;
  @override
  List<CastTarget> get devices => List.unmodifiable(_devices.values);
  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> refresh() async {
    if (_closed || loading) return;
    loading = true;
    error = null;
    _notify();
    try {
      await _initialize();
      if (_closed) return;
      _active.add(this);
      void receive(List<GoogleCastDevice> devices) {
        if (_closed) return;
        _devices.removeWhere((key, _) => key.startsWith('cast:'));
        for (final device in devices) {
          _devices['cast:${device.deviceID}'] = CastTarget(
            'cast:${device.deviceID}',
            device.friendlyName,
            'Google Cast',
            () => GoogleCastReceiver(device),
          );
        }
        _notify();
      }

      _subscription ??= _google.devicesStream.listen(receive);
      // The SDK discovery manager is global. Serialize start/stop and retain
      // leases so an old sheet cannot stop discovery in a newly opened sheet.
      await _queueDiscovery(() async {
        if (!_closed) await _google.startDiscovery();
      });
      if (_closed) return;
      receive(_google.devices);
    } catch (_) {
      error = 'Google Cast 搜索未启动，请检查本地网络权限';
    }
    try {
      if (_closed) return;
      final devices = await _findDlna();
      if (_closed) return;
      _devices.removeWhere((key, _) => key.startsWith('dlna:'));
      for (final device in devices) {
        final id = 'dlna:${device.control}';
        _devices[id] = CastTarget(
          id,
          device.name,
          'DLNA',
          () => DlnaCastReceiver(device),
        );
      }
    } catch (_) {
      error = '请允许本地网络访问，并确认电视已打开投屏接收';
    } finally {
      loading = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_subscription?.cancel());
    if (_active.remove(this)) {
      unawaited(
        _queueDiscovery(() async {
          if (_active.isEmpty) await _google.stopDiscovery();
        }).catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
