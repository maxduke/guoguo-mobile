import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/media_executor.dart';
import 'package:guoguo_mobile/platform/progressive_media.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Job implements MediaExecution {
  final _result = Completer<void>();
  int cancellations = 0;
  bool failCancellation = false;

  _Job() {
    unawaited(
      _result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  @override
  Future<void> get done => _result.future;

  void finish() {
    if (!_result.isCompleted) _result.complete();
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    if (failCancellation) throw StateError('cancel failed');
    if (!_result.isCompleted) {
      _result.completeError(const ProviderException('已取消准备'));
    }
  }
}

const _openPlaylist = '''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2.000000,
segment_00000.m4s
''';

Future<void> _writeReady(Directory dir, {bool ended = false}) async {
  await File('${dir.path}/init.mp4').writeAsBytes([1, 2, 3, 4]);
  await File('${dir.path}/segment_00000.m4s').writeAsBytes([5, 6, 7, 8]);
  await File(
    '${dir.path}/index.m3u8',
  ).writeAsString('$_openPlaylist${ended ? '#EXT-X-ENDLIST\n' : ''}');
}

Future<HttpClientResponse> _request(
  Uri url, {
  String method = 'GET',
  String? range,
}) async {
  final client = HttpClient();
  addTearDown(client.close);
  final request = await client.openUrl(method, url);
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  return request.close();
}

void main() {
  late Directory dir;
  setUp(
    () async =>
        dir = await Directory.systemTemp.createTemp('progressive-test-'),
  );
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'becomes ready before completion and serves only token-scoped completed assets',
    () async {
      final job = _Job();
      final media = ProgressiveMedia(dir, job);
      final opening = media.start(startupTimeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await _writeReady(dir);
      final url = Uri.parse(await opening);
      expect(media.complete, isFalse);
      expect(url.host, '127.0.0.1');

      final playlist = await _request(url);
      expect(playlist.statusCode, HttpStatus.ok);
      expect(
        await playlist.transform(SystemEncoding().decoder).join(),
        contains('segment_00000.m4s'),
      );

      final segment = url.resolve('segment_00000.m4s');
      final partial = await _request(segment, range: 'bytes=1-2');
      expect(partial.statusCode, HttpStatus.partialContent);
      expect(
        partial.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1-2/4',
      );
      expect(await partial.toList(), [
        [6, 7],
      ]);
      final suffix = await _request(segment, range: 'bytes=-2');
      expect(suffix.statusCode, HttpStatus.partialContent);
      expect(await suffix.toList(), [
        [7, 8],
      ]);
      final head = await _request(segment, method: 'HEAD', range: 'bytes=0-0');
      expect(head.statusCode, HttpStatus.partialContent);
      expect(head.contentLength, 1);
      final invalid = await _request(segment, range: 'bytes=99-');
      expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      await invalid.drain<void>();

      expect(
        (await _request(url.replace(path: '/wrong/index.m3u8'))).statusCode,
        HttpStatus.notFound,
      );
      expect(
        (await _request(url.resolve('segment_00000.m4s.tmp'))).statusCode,
        HttpStatus.notFound,
      );
      expect(
        (await _request(url.resolve('%2e%2e/index.m3u8'))).statusCode,
        HttpStatus.notFound,
      );
      expect(
        (await _request(url, method: 'POST')).statusCode,
        HttpStatus.methodNotAllowed,
      );

      await Link(
        '${dir.path}/segment_00001.m4s',
      ).create('${dir.path}/init.mp4');
      expect(
        (await _request(url.resolve('segment_00001.m4s'))).statusCode,
        HttpStatus.notFound,
      );
      media.failure = const ProviderException('synthetic failure');
      final failed = await _request(url);
      expect(failed.statusCode, HttpStatus.serviceUnavailable);
      expect(
        await failed.transform(SystemEncoding().decoder).join(),
        isNotEmpty,
      );
      media.failure = null;
      await _writeReady(dir, ended: true);
      job.finish();
      await job.done;
      await Future<void>.delayed(Duration.zero);
      expect(media.complete, isTrue);
      await media.close();
      expect(job.cancellations, 0);
    },
  );

  test('finished job without ENDLIST is rejected', () async {
    await _writeReady(dir);
    final job = _Job()..finish();
    final media = ProgressiveMedia(dir, job);
    await expectLater(
      media.start(startupTimeout: const Duration(milliseconds: 200)),
      throwsA(isA<ProviderException>()),
    );
    await media.close();
  });

  test(
    'resource budget cancels the writer and exposes a safe failure',
    () async {
      await _writeReady(dir);
      final job = _Job();
      final media = ProgressiveMedia(dir, job, maxBytes: 1);
      await expectLater(media.start(), throwsA(isA<ProviderException>()));
      expect(job.cancellations, 1);
      expect(media.failure?.message, contains('资源限制'));
      await media.close();
    },
  );

  test(
    'failed budget cancellation is contained and close reports unsafe cleanup',
    () async {
      await _writeReady(dir);
      final job = _Job()..failCancellation = true;
      final media = ProgressiveMedia(dir, job, maxBytes: 1);
      await expectLater(media.start(), throwsA(isA<ProviderException>()));
      expect(media.failure, isNotNull);
      await expectLater(media.close(), throwsA(isA<StateError>()));
      job.finish();
      await job.done;
    },
  );
}
