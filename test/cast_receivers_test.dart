import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:guoguo_mobile/platform/cast_receivers.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/platform/casting.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';

import 'support/cast_fakes.dart';

const url = 'http://192.168.1.2:8080/token/0.mp4';
const service = 'urn:schemas-upnp-org:service:AVTransport:1';
String reply(String action, [String body = '']) =>
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="$service">$body</u:${action}Response></s:Body></s:Envelope>';
String action(http.Request request) =>
    request.headers['SOAPAction']!.split('#').last.replaceAll('"', '');
String positionReply([String uri = url, String time = '00:00:42.250']) => reply(
  'GetPositionInfo',
  '<TrackURI>$uri</TrackURI><RelTime>$time</RelTime><TrackDuration>00:02:00</TrackDuration>',
);
DlnaCastReceiver dlna(http.Client client) => DlnaCastReceiver(
  DlnaDevice('电视', Uri.parse('http://192.168.1.3/control'), service),
  client: client,
);

class FakeRemote implements GoogleCastRemoteMediaClientPlatformInterface {
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  GoggleCastMediaStatus? mediaStatus;
  @override
  Stream<Duration> get playerPositionStream => positions.stream;
  final calls = <String>[];
  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> play() async {
    calls.add('play');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSession extends GoogleCastSession {
  FakeSession(GoogleCastDevice device)
    : super(
        device: device,
        sessionID: 'our-session',
        connectionState: GoogleCastConnectState.connected,
        currentDeviceMuted: false,
        currentDeviceVolume: 1,
        deviceStatusText: '',
      );
}

class FakeManager implements GoogleCastSessionManagerPlatformInterface {
  FakeManager(GoogleCastDevice device) : currentSession = FakeSession(device);
  @override
  GoogleCastSession? currentSession;
  @override
  GoogleCastConnectState get connectionState =>
      currentSession?.connectionState ?? GoogleCastConnectState.disconnected;
  int stops = 0;
  @override
  Future<bool> startSessionWithDevice(GoogleCastDevice device) async {
    currentSession = FakeSession(device);
    return true;
  }

  @override
  Future<bool> endSessionAndStopCasting() async {
    stops++;
    currentSession = null;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeGoogleDiscovery
    implements GoogleCastDiscoveryManagerPlatformInterface {
  final updates = StreamController<List<GoogleCastDevice>>.broadcast(
    sync: true,
  );
  Completer<void>? startGate;
  int starts = 0, stops = 0;
  @override
  List<GoogleCastDevice> get devices => [device];
  @override
  Stream<List<GoogleCastDevice>> get devicesStream => updates.stream;
  @override
  Future<void> startDiscovery() async {
    starts++;
    await startGate?.future;
  }

  @override
  Future<void> stopDiscovery() async {
    stops++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final device = GoogleCastDevice(
  deviceID: 'tv',
  friendlyName: '电视',
  modelName: null,
  statusText: null,
  deviceVersion: '',
  isOnLocalNetwork: true,
  category: '',
  uniqueID: 'tv',
);
GoggleCastMediaStatus mediaStatus(
  int id,
  String uri, {
  CastMediaPlayerState state = CastMediaPlayerState.playing,
}) => GoggleCastMediaStatus(
  mediaSessionID: id,
  playerState: state,
  playbackRate: 1,
  volume: 1,
  isMuted: false,
  repeatMode: GoogleCastMediaRepeatMode.off,
  mediaInformation: GoogleCastMediaInformation(
    contentId: uri,
    streamType: CastMediaStreamType.buffered,
    contentType: 'video/mp4',
    duration: const Duration(seconds: 120),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'DLNA metadata provides escaped video title, media type and URL including local MP4',
    () {
      final original = castSource();
      final source = CastSource(
        media: original.media,
        title: '作品 <一> & "二"',
        position: original.position,
        duration: original.duration,
        playing: true,
      );
      final metadata = XmlDocument.parse(
        dlnaMediaMetadata('$url?one=1&two=2', source),
      );
      final elements = metadata.descendants.whereType<XmlElement>();
      expect(
        elements.firstWhere((e) => e.name.local == 'title').innerText,
        source.title,
      );
      expect(
        elements.firstWhere((e) => e.name.local == 'class').innerText,
        'object.item.videoItem',
      );
      final resource = elements.firstWhere((e) => e.name.local == 'res');
      expect(resource.innerText, '$url?one=1&two=2');
      expect(resource.getAttribute('protocolInfo'), 'http-get:*:video/mp4:*');
      final hls = CastSource(
        media: ResolvedMedia.fromJson({
          'url': url,
          'remoteUrl': url,
          'hls': true,
        }),
        title: source.title,
        position: source.position,
        duration: source.duration,
        playing: true,
      );
      expect(
        dlnaMediaMetadata(url, hls),
        contains('application/vnd.apple.mpegurl'),
      );
      final local = CastSource(
        media: hls.media,
        localPath: '/fixture/complete.mp4',
        title: source.title,
        position: source.position,
        duration: source.duration,
        playing: true,
      );
      expect(dlnaMediaMetadata(url, local), contains('video/mp4'));
    },
  );
  test(
    'DLNA waits for renderer readiness and retries only a transient seek transition',
    () async {
      var transports = 0, seeks = 0;
      final calls = <String>[];
      final receiver = DlnaCastReceiver(
        DlnaDevice('电视', Uri.parse('http://192.168.1.3/control'), service),
        delay: (_) async {},
        client: MockClient((request) async {
          final name = action(request);
          calls.add(name);
          if (name == 'GetTransportInfo') {
            transports++;
            return http.Response(
              reply(
                name,
                '<CurrentTransportState>${transports < 3 ? 'TRANSITIONING' : 'PLAYING'}</CurrentTransportState>',
              ),
              200,
            );
          }
          if (name == 'Seek' && ++seeks < 3) {
            return http.Response(
              '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
              500,
            );
          }
          if (name == 'SetAVTransportURI') {
            final soap = XmlDocument.parse(request.body);
            final metadata = soap
                .findAllElements('CurrentURIMetaData')
                .single
                .innerText;
            expect(
              XmlDocument.parse(
                metadata,
              ).findAllElements('res').single.innerText,
              url,
            );
          }
          return http.Response(reply(name), 200);
        }),
      );
      await receiver.load(url, castSource(position: 37));
      expect(transports, 3);
      expect(seeks, 3);
      expect(
        calls.indexOf('Seek'),
        greaterThan(calls.lastIndexOf('GetTransportInfo')),
      );
      await receiver.close();
    },
  );
  test(
    'DLNA permanently stopped renderer cannot be reported as playing',
    () async {
      var transports = 0;
      final receiver = DlnaCastReceiver(
        DlnaDevice('电视', Uri.parse('http://192.168.1.3/control'), service),
        delay: (_) async {},
        client: MockClient((request) async {
          if (action(request) == 'GetTransportInfo') {
            transports++;
            return http.Response(
              reply(
                'GetTransportInfo',
                '<CurrentTransportState>STOPPED</CurrentTransportState>',
              ),
              200,
            );
          }
          return http.Response(reply(action(request)), 200);
        }),
      );
      await expectLater(
        receiver.load(url, castSource(position: 37)),
        throwsA(isA<ProviderException>()),
      );
      expect(transports, 16);
      await receiver.close();
    },
  );
  test(
    'DLNA cancels a transient Play retry before it can restart TV after stop',
    () async {
      var plays = 0;
      final retry = Completer<void>(), waiting = Completer<void>();
      final receiver = DlnaCastReceiver(
        DlnaDevice('电视', Uri.parse('http://192.168.1.3/control'), service),
        delay: (_) {
          waiting.complete();
          return retry.future;
        },
        client: MockClient((request) async {
          if (action(request) == 'Play') {
            plays++;
            return http.Response(
              '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
              500,
            );
          }
          return http.Response(
            action(request) == 'GetPositionInfo'
                ? positionReply()
                : reply(action(request)),
            200,
          );
        }),
      );
      final loading = receiver.load(url, castSource());
      final cancelled = expectLater(loading, throwsA(isA<CastCancelled>()));
      await waiting.future;
      receiver.cancelLoad();
      await receiver.stop();
      retry.complete();
      await cancelled;
      expect(plays, 1);
      await receiver.close();
    },
  );
  test(
    'DLNA unsupported seek is not retried and native HTTP 500 fault preserves code',
    () async {
      var seeks = 0;
      final receiver = DlnaCastReceiver(
        DlnaDevice('电视', Uri.parse('http://192.168.1.3/control'), service),
        delay: (_) async {},
        client: MockClient((request) async {
          if (action(request) == 'Seek') {
            seeks++;
            return http.Response(
              '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>710</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
              500,
            );
          }
          return http.Response(reply(action(request)), 200);
        }),
      );
      await expectLater(
        receiver.load(url, castSource()),
        throwsA(isA<DlnaCommandException>().having((e) => e.code, 'code', 710)),
      );
      expect(seeks, 1);
      await receiver.close();
    },
  );
  test(
    'DLNA times preserve actual fractional seconds and reject unsupported/invalid values',
    () {
      expect(
        parseDlnaTime('01:02:03.5'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
      for (final value in [
        'NOT_IMPLEMENTED',
        '00:99:00',
        '-1:00:00',
        'NaN',
        '00:00:01.1234',
      ]) {
        expect(parseDlnaTime(value), isNull);
      }
      expect(
        formatDlnaTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '01:02:03',
      );
    },
  );
  test(
    'DLNA loads, seeks using REL_TIME and keeps paused phone intent',
    () async {
      final calls = <String>[], bodies = <String>[];
      final receiver = dlna(
        MockClient((request) async {
          calls.add(action(request));
          bodies.add(request.body);
          return http.Response(
            action(request) == 'GetPositionInfo'
                ? positionReply()
                : reply(action(request)),
            200,
          );
        }),
      );
      await receiver.load(url, castSource(position: 37, playing: false));
      expect(calls, [
        'SetAVTransportURI',
        'Play',
        'GetTransportInfo',
        'Seek',
        'GetPositionInfo',
        'Pause',
      ]);
      final seek = XmlDocument.parse(bodies[3]);
      expect(seek.findAllElements('Unit').single.innerText, 'REL_TIME');
      expect(seek.findAllElements('Target').single.innerText, '00:00:37');
      await receiver.close();
    },
  );
  test(
    'DLNA status reads position and pause state and refuses another media identity',
    () async {
      var foreign = false, paused = false;
      final receiver = dlna(
        MockClient(
          (request) async => http.Response(
            action(request) == 'GetPositionInfo'
                ? positionReply(foreign ? 'http://192.168.1.9/other' : url)
                : action(request) == 'GetTransportInfo'
                ? reply(
                    'GetTransportInfo',
                    '<CurrentTransportState>${paused ? 'PAUSED_PLAYBACK' : 'PLAYING'}</CurrentTransportState>',
                  )
                : reply(action(request)),
            200,
          ),
        ),
      );
      await receiver.load(url, castSource());
      paused = true;
      final status = await receiver.status();
      expect(status.position, const Duration(seconds: 42, milliseconds: 250));
      expect(status.duration, const Duration(seconds: 120));
      expect(status.playing, false);
      foreign = true;
      await expectLater(receiver.status(), throwsException);
      await receiver.close();
    },
  );
  test('SOAP faults on HTTP 200 cannot be treated as successful seek', () async {
    final receiver = dlna(
      MockClient(
        (request) async => http.Response(
          action(request) == 'Seek'
              ? '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>714</faultcode></s:Fault></s:Body></s:Envelope>'
              : reply(action(request)),
          200,
        ),
      ),
    );
    await expectLater(
      receiver.load(url, castSource(position: 10)),
      throwsException,
    );
    await receiver.close();
  });
  test(
    'missing or malformed SOAP response cannot confirm a control command',
    () async {
      for (final body in ['', reply('OtherAction'), '<not-xml']) {
        final receiver = dlna(
          MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(receiver.load(url, castSource()), throwsException);
        await receiver.close();
      }
    },
  );
  test(
    'unsupported DLNA time remains unknown and does not become zero',
    () async {
      final receiver = dlna(
        MockClient(
          (request) async => http.Response(
            action(request) == 'GetPositionInfo'
                ? positionReply('NOT_IMPLEMENTED', 'NOT_IMPLEMENTED')
                : reply(action(request)),
            200,
          ),
        ),
      );
      await receiver.load(url, castSource(position: 0));
      expect((await receiver.status()).position, isNull);
      await receiver.close();
    },
  );
  test('DLNA stop protects media loaded by another sender', () async {
    final calls = <String>[];
    final receiver = dlna(
      MockClient((request) async {
        calls.add(action(request));
        return http.Response(
          action(request) == 'GetPositionInfo'
              ? positionReply('http://192.168.1.4/other')
              : reply(action(request)),
          200,
        );
      }),
    );
    await receiver.load(url, castSource(position: 0));
    await receiver.stop();
    expect(calls, isNot(contains('Stop')));
    await receiver.close();
  });
  test('DLNA controls cannot pause or resume another sender media', () async {
    var foreign = false;
    final calls = <String>[];
    final receiver = dlna(
      MockClient((request) async {
        calls.add(action(request));
        return http.Response(
          action(request) == 'GetPositionInfo'
              ? positionReply(foreign ? 'http://192.168.1.4/other' : url)
              : reply(action(request)),
          200,
        );
      }),
    );
    await receiver.load(url, castSource(position: 0));
    foreign = true;
    calls.clear();
    await expectLater(receiver.pause(), throwsException);
    await expectLater(receiver.play(), throwsException);
    expect(calls, ['GetPositionInfo', 'GetPositionInfo']);
    await receiver.close();
  });
  test(
    'DLNA concurrent stop is idempotent and a failed stop can retry',
    () async {
      var fail = true;
      var stops = 0;
      final gate = Completer<void>();
      final receiver = dlna(
        MockClient((request) async {
          if (action(request) == 'Stop') {
            stops++;
            await gate.future;
            if (fail) return http.Response('failed', 500);
          }
          return http.Response(
            action(request) == 'GetPositionInfo'
                ? positionReply()
                : reply(action(request)),
            200,
          );
        }),
      );
      await receiver.load(url, castSource(position: 0));
      final first = receiver.stop(), second = receiver.stop();
      final failed = expectLater(first, throwsException);
      final alsoFailed = expectLater(second, throwsException);
      gate.complete();
      await Future.wait([failed, alsoFailed]);
      expect(stops, 1);
      fail = false;
      await receiver.stop();
      await receiver.stop();
      expect(stops, 2);
      await receiver.close();
    },
  );
  test(
    'Google Cast awaits native load errors and passes actual pause and start position',
    () async {
      final remote = FakeRemote(), manager = FakeManager(device);
      const channel = MethodChannel('test.cast.load');
      Map? arguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            arguments = call.arguments as Map;
            throw PlatformException(code: 'load-failed');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final receiver = GoogleCastReceiver(
        device,
        remote: remote,
        manager: manager,
        channel: channel,
      );
      await receiver.connect();
      await expectLater(
        receiver.load(url, castSource(position: 37, playing: false)),
        throwsA(isA<PlatformException>()),
      );
      expect(arguments!['playPosition'], 37);
      expect(arguments!['autoPlay'], false);
      await receiver.close();
      await remote.positions.close();
    },
  );
  test(
    'Google Cast ignores stale media and initial stale position ticks, then preserves backward seek',
    () async {
      final remote = FakeRemote()..mediaStatus = mediaStatus(1, 'old');
      final manager = FakeManager(device);
      const channel = MethodChannel('test.cast.positions');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            remote.positions.add(const Duration(seconds: 90));
            remote.mediaStatus = mediaStatus(
              2,
              url,
              state: CastMediaPlayerState.paused,
            );
            remote.positions.add(const Duration(seconds: 90));
            remote.positions.add(const Duration(seconds: 37));
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final receiver = GoogleCastReceiver(
        device,
        remote: remote,
        manager: manager,
        channel: channel,
      );
      await receiver.connect();
      await receiver.load(url, castSource(position: 37, playing: false));
      expect((await receiver.status()).position, const Duration(seconds: 37));
      expect((await receiver.status()).playing, false);
      remote.positions.add(const Duration(seconds: 12));
      expect((await receiver.status()).position, const Duration(seconds: 12));
      remote.mediaStatus = mediaStatus(3, 'other');
      remote.positions.add(const Duration(seconds: 100));
      await expectLater(receiver.status(), throwsException);
      await expectLater(receiver.pause(), throwsException);
      await expectLater(receiver.play(), throwsException);
      expect(remote.calls, isEmpty);
      await receiver.stop();
      expect(manager.stops, 0);
      await receiver.close();
      await remote.positions.close();
    },
  );
  test(
    'Google Cast closes a pending load even while its previous media is reported',
    () async {
      final remote = FakeRemote()..mediaStatus = mediaStatus(1, 'old');
      final manager = FakeManager(device);
      const channel = MethodChannel('test.cast.pending');
      final called = Completer<void>(), gate = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            called.complete();
            await gate.future;
            remote.mediaStatus = mediaStatus(2, url);
            remote.positions.add(const Duration(seconds: 37));
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final receiver = GoogleCastReceiver(
        device,
        remote: remote,
        manager: manager,
        channel: channel,
      );
      await receiver.connect();
      final loading = receiver.load(url, castSource(position: 37));
      final cancelled = expectLater(loading, throwsA(isA<CastCancelled>()));
      await called.future;
      await Future.wait([receiver.stop(), receiver.stop()]);
      expect(manager.stops, 1);
      await receiver.close();
      gate.complete();
      await cancelled;
      await remote.positions.close();
    },
  );
  test(
    'closing discovery during initialization cannot affect a newer sheet',
    () async {
      final google = FakeGoogleDiscovery(), gate = Completer<void>();
      var dlnaSearches = 0;
      DeviceCastDiscovery create() => DeviceCastDiscovery(
        google: google,
        initialize: () => gate.future,
        findDlna: () async {
          dlnaSearches++;
          return [];
        },
      );
      final old = create(), current = create();
      final oldRefresh = old.refresh();
      old.dispose();
      final currentRefresh = current.refresh();
      gate.complete();
      await Future.wait([oldRefresh, currentRefresh]);
      expect(google.starts, 1);
      expect(google.stops, 0);
      expect(dlnaSearches, 1);
      expect(current.devices.single.id, 'cast:tv');
      current.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(google.stops, 1);
      await google.updates.close();
    },
  );
  test(
    'late discovery start from a closed sheet does not stop a newer search',
    () async {
      final google = FakeGoogleDiscovery()..startGate = Completer<void>();
      DeviceCastDiscovery create() => DeviceCastDiscovery(
        google: google,
        initialize: () async {},
        findDlna: () async => [],
      );
      final old = create(), current = create();
      final oldRefresh = old.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(google.starts, 1);
      old.dispose();
      final currentRefresh = current.refresh();
      await Future<void>.delayed(Duration.zero);
      google.startGate!.complete();
      await Future.wait([oldRefresh, currentRefresh]);
      expect(google.starts, 2);
      expect(google.stops, 0);
      current.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(google.stops, 1);
      await google.updates.close();
    },
  );
  test(
    'relay closed before or during start cannot create a late server',
    () async {
      final relay = CastRelay();
      final starting = relay.start(castSource().media, null);
      final expected = expectLater(starting, throwsStateError);
      await relay.close();
      await expected;
      await expectLater(
        relay.start(castSource().media, null),
        throwsStateError,
      );
      await relay.close();
    },
  );
}
