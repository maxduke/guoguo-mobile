import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/casting.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

ResolvedMedia media(
  String url, {
  bool hls = false,
  Map<String, String> headers = const {},
}) => ResolvedMedia.fromJson({
  'url': url,
  'remoteUrl': url,
  'hls': hls,
  'headers': headers,
});
CastRelay relay() =>
    CastRelay(addressResolver: (_) async => InternetAddress.loopbackIPv4);
Future<({int status, HttpHeaders headers, List<int> body})> fetch(
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, url);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    return (
      status: response.statusCode,
      headers: response.headers,
      body: bytes,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  final ffmpeg = Platform.environment['GUOGUO_FFMPEG'];
  test(
    'a decoder reads real MP4 frames through the HTTP relay',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cast-relay-media-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/video.mp4';
      final generated = await Process.run(ffmpeg!, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=size=180x320:rate=10',
        '-t',
        '1',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-y',
        path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final server = relay();
      addTearDown(server.close);
      final url = await server.start(
        media('https://example.test/video.mp4'),
        path,
      );
      final decoded = await Process.run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-rw_timeout',
        '5000000',
        '-i',
        url,
        '-frames:v',
        '4',
        '-f',
        'null',
        '-',
      ]);
      expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
      expect(server.mediaRequested, true);
      expect(server.bytesSent, greaterThan(0));
      expect(server.transferError, isNull);
    },
    skip: ffmpeg == null
        ? 'Set GUOGUO_FFMPEG for real HTTP media decoding'
        : false,
  );
  test(
    'receiver can inspect the final MP4 bytes with a suffix range',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cast-relay-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/video.mp4',
      ).writeAsBytes(List.generate(32, (i) => i));
      final relay = CastRelay(
        addressResolver: (_) async => InternetAddress.loopbackIPv4,
      );
      addTearDown(relay.close);
      final url = Uri.parse(
        await relay.start(
          ResolvedMedia.fromJson({
            'url': 'https://example.test/video.mp4',
            'remoteUrl': 'https://example.test/video.mp4',
          }),
          file.path,
        ),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(url.replace(host: '127.0.0.1'));
      request.headers.set('Range', 'bytes=-8');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('Content-Range'), 'bytes 24-31/32');
      final bytes = await response.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      expect(bytes, List.generate(8, (i) => i + 24));
    },
  );
  test(
    'Wi-Fi is preferred over VPN and cellular, while a receiver route can select Ethernet',
    () {
      CastNetworkAddress address(String name, String ip) =>
          (name: name, address: InternetAddress(ip));
      final addresses = [
        address('utun2', '10.0.0.2'),
        address('pdp_ip0', '10.1.0.2'),
        address('en2', '192.168.99.2'),
        address('en0', '192.168.1.2'),
      ];
      expect(selectCastAddress(addresses).address, '192.168.1.2');
      expect(
        selectCastAddress(
          addresses,
          route: InternetAddress('192.168.99.2'),
        ).address,
        '192.168.99.2',
      );
      expect(
        selectCastAddress(
          addresses,
          route: InternetAddress('10.0.0.2'),
        ).address,
        '192.168.1.2',
      );
      expect(
        () => selectCastAddress(addresses.take(2).toList()),
        throwsA(isA<ProviderException>()),
      );
      expect(
        selectCastAddress([address('wlan0', '169.254.1.2')]).address,
        '169.254.1.2',
      );
    },
  );
  test(
    'real HTTP probes, full reads and byte ranges have consistent lengths and data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cast-relay-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/video.mp4',
      ).writeAsBytes(List.generate(32, (i) => i));
      final server = relay();
      addTearDown(server.close);
      final url = Uri.parse(
        await server.start(media('https://example.test/video.mp4'), file.path),
      );
      final head = await fetch(
        url,
        method: 'HEAD',
        headers: {'Range': 'bytes=4-7', 'getcontentFeatures.dlna.org': '1'},
      );
      expect(head.status, 200);
      expect(head.headers.contentLength, 32);
      expect(head.headers.value('Content-Range'), isNull);
      expect(head.headers.value('contentFeatures.dlna.org'), 'DLNA.ORG_OP=01');
      expect(head.headers.value('transferMode.dlna.org'), 'Streaming');
      expect(head.body, isEmpty);
      expect(server.mediaRequested, false);
      for (final entry in {
        'bytes=4-7': (4, 7),
        'bytes=28-': (28, 31),
        'bytes=-999999999999999999999999999': (0, 31),
        'bytes=0-999999999999999999999999999': (0, 31),
      }.entries) {
        final response = await fetch(url, headers: {'Range': entry.key});
        expect(response.status, 206);
        expect(
          response.headers.value('Content-Range'),
          'bytes ${entry.value.$1}-${entry.value.$2}/32',
        );
        expect(
          response.body,
          List.generate(
            entry.value.$2 - entry.value.$1 + 1,
            (i) => i + entry.value.$1,
          ),
        );
        expect(response.headers.contentLength, response.body.length);
      }
      for (final range in [
        'bytes=32-',
        'bytes=-0',
        'bytes=9-2',
        'bytes=-',
        'bytes=999999999999999999999999-',
      ]) {
        final response = await fetch(url, headers: {'Range': range});
        expect(response.status, 416);
        expect(response.headers.value('Content-Range'), 'bytes */32');
      }
      for (final range in ['bytes=0-1,3-4', 'other=1-2']) {
        final response = await fetch(url, headers: {'Range': range});
        expect(response.status, 200);
        expect(response.body, List.generate(32, (i) => i));
      }
      expect(server.mediaRequested, true);
      expect(server.bytesSent, greaterThan(0));
      expect(server.transferError, isNull);
    },
  );
  test(
    'CORS and registered resource boundary reject arbitrary URLs or filesystem paths',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cast-relay-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/video.mp4',
      ).writeAsBytes([1, 2, 3]);
      final server = relay();
      addTearDown(server.close);
      final url = Uri.parse(
        await server.start(media('https://example.test/video.mp4'), file.path),
      );
      final options = await fetch(url, method: 'OPTIONS');
      expect(options.status, 204);
      expect(options.headers.value('Access-Control-Allow-Origin'), '*');
      expect(
        options.headers.value('Access-Control-Allow-Headers'),
        contains('Range'),
      );
      expect((await fetch(url.replace(path: '/invalid/0.mp4'))).status, 404);
      expect((await fetch(url.resolve('99.mp4'))).status, 404);
      expect((await fetch(url.resolve('file/video.mp4'))).status, 404);
      expect((await fetch(url, method: 'POST')).status, 405);
      expect(server.mediaRequested, false);
    },
  );
  test('closing during address lookup rejects late server creation', () async {
    final gate = Completer<InternetAddress>();
    final server = CastRelay(addressResolver: (_) => gate.future);
    final starting = server.start(
      media('https://example.test/video.mp4'),
      null,
    );
    final cancelled = expectLater(starting, throwsStateError);
    await server.close();
    gate.complete(InternetAddress.loopbackIPv4);
    await cancelled;
  });
  test(
    'HLS variants, init, keys and segments all use relay URLs and original source headers',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final requests = <String>[];
      origin.listen((request) async {
        requests.add(request.uri.toString());
        if (request.headers.value('Authorization') != 'Fixture auth') {
          request.response.statusCode = 403;
        } else if (request.uri.path == '/master.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvariant/main.m3u8?signature=fixture\n',
          );
        } else if (request.uri.path == '/variant/main.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="../key.bin?signature=fixture"\n#EXT-X-MAP:URI="../init.mp4?signature=fixture"\n#EXTINF:2,\nsegment.m4s?signature=fixture\n#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.contentLength = 4;
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final server = relay();
      addTearDown(server.close);
      final url = Uri.parse(
        await server.start(
          media(
            'http://127.0.0.1:${origin.port}/master.m3u8?signature=fixture',
            hls: true,
            headers: {'Authorization': 'Fixture auth'},
          ),
          null,
        ),
      );
      final master = utf8.decode((await fetch(url)).body);
      expect(master, isNot(contains('signature')));
      final variant = Uri.parse(
        master.split('\n').firstWhere((line) => line.startsWith('http')),
      );
      final content = utf8.decode((await fetch(variant)).body);
      expect(content, isNot(contains('signature')));
      final references = [
        ...RegExp(
          r'URI="([^"]+)"',
        ).allMatches(content).map((m) => Uri.parse(m[1]!)),
        Uri.parse(
          content.split('\n').firstWhere((line) => line.startsWith('http')),
        ),
      ];
      for (final reference in references) {
        expect(reference.host, url.host);
        final response = await fetch(reference);
        expect(response.status, 200);
        expect(response.body, [1, 2, 3, 4]);
      }
      expect(
        requests,
        containsAll([
          '/key.bin?signature=fixture',
          '/init.mp4?signature=fixture',
          '/variant/segment.m4s?signature=fixture',
        ]),
      );
      expect(server.bytesSent, 12);
      expect(server.transferError, isNull);
    },
  );
  test(
    'remote Range requests preserve bytes, and origin rejection has a safe error',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var fail = false;
      origin.listen((request) async {
        if (fail) {
          request.response.statusCode = 403;
        } else {
          expect(request.headers.value('Range'), 'bytes=4-7');
          expect(request.headers.value('Accept-Encoding'), 'identity');
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 4-7/32');
          request.response.headers.set('Content-Type', 'video/mp4');
          request.response.contentLength = 4;
          request.response.add([4, 5, 6, 7]);
        }
        await request.response.close();
      });
      final server = relay();
      addTearDown(server.close);
      final url = Uri.parse(
        await server.start(
          media('http://127.0.0.1:${origin.port}/movie.mp4?signature=fixture'),
          null,
        ),
      );
      final response = await fetch(url, headers: {'Range': 'bytes=4-7'});
      expect(response.status, 206);
      expect(response.headers.value('Content-Range'), 'bytes 4-7/32');
      expect(response.body, [4, 5, 6, 7]);
      fail = true;
      expect((await fetch(url)).status, 403);
      expect(server.transferError, contains('403'));
      expect(server.transferError, isNot(contains('signature')));
    },
  );
}
