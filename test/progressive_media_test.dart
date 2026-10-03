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
#EXT-X-TARGETDURATION:2
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2.000000,
segment_00000.m4s
#EXTINF:2.000000,
segment_00001.m4s
#EXTINF:2.000000,
segment_00002.m4s
''';

String _bufferPlaylist(int segments, int target, {bool ended = false}) =>
    '#EXTM3U\n#EXT-X-TARGETDURATION:$target\n#EXT-X-MAP:URI="init.mp4"\n'
    '${List.generate(segments, (index) => '#EXTINF:$target,\nsegment_${index.toString().padLeft(5, '0')}.m4s\n').join()}'
    '${ended ? '#EXT-X-ENDLIST\n' : ''}';

Future<void> _writeReady(Directory dir, {bool ended = false}) async {
  await File('${dir.path}/init.mp4').writeAsBytes([1, 2, 3, 4]);
  await File('${dir.path}/segment_00000.m4s').writeAsBytes([5, 6, 7, 8]);
  await File('${dir.path}/segment_00001.m4s').writeAsBytes([9]);
  await File('${dir.path}/segment_00002.m4s').writeAsBytes([10]);
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

Future<void> _waitForDuration(ProgressiveMedia media, Duration target) async {
  if (media.timeline.value.duration >= target) return;
  final reached = Completer<void>();
  void check() {
    if (media.timeline.value.duration >= target && !reached.isCompleted) {
      reached.complete();
    }
  }

  media.timeline.addListener(check);
  try {
    await reached.future.timeout(const Duration(seconds: 3));
  } finally {
    media.timeline.removeListener(check);
  }
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

  for (final target in [2, 4]) {
    test(
      'waits for three target durations of $target seconds before opening',
      () async {
        await _writeReady(dir);
        await File(
          '${dir.path}/index.m3u8',
        ).writeAsString(_bufferPlaylist(1, target));
        final job = _Job();
        final media = ProgressiveMedia(dir, job);
        addTearDown(media.close);
        var opened = false;
        final opening = media.start().then((url) {
          opened = true;
          return url;
        });
        await _waitForDuration(media, Duration(seconds: target));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(opened, isFalse);
        await File(
          '${dir.path}/index.m3u8',
        ).writeAsString(_bufferPlaylist(2, target));
        await _waitForDuration(media, Duration(seconds: target * 2));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(opened, isFalse);
        await File(
          '${dir.path}/index.m3u8',
        ).writeAsString(_bufferPlaylist(3, target));
        expect(await opening, startsWith('http://127.0.0.1:'));
        expect(media.timeline.value.duration, Duration(seconds: target * 3));
        expect(media.complete, isFalse);
      },
    );
  }

  test(
    'finished short episode opens without waiting for startup headroom',
    () async {
      await _writeReady(dir);
      await File(
        '${dir.path}/index.m3u8',
      ).writeAsString(_bufferPlaylist(1, 2, ended: true));
      final job = _Job()..finish();
      final media = ProgressiveMedia(dir, job);
      addTearDown(media.close);
      expect(await media.start(), startsWith('http://127.0.0.1:'));
      expect(media.timeline.value.duration, const Duration(seconds: 2));
      expect(media.complete, isTrue);
    },
  );

  test(
    'cancelling while waiting for startup headroom closes the writer',
    () async {
      await _writeReady(dir);
      await File('${dir.path}/index.m3u8').writeAsString(_bufferPlaylist(1, 2));
      final job = _Job();
      final media = ProgressiveMedia(dir, job);
      final opening = media.start();
      final cancelled = expectLater(opening, throwsA(isA<ProviderException>()));
      await _waitForDuration(media, const Duration(seconds: 2));
      await media.close();
      await cancelled;
      expect(job.cancellations, 1);
    },
  );

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
      expect(media.timeline.value.duration, const Duration(seconds: 6));
      expect(media.timeline.value.complete, isFalse);
      expect(url.host, '127.0.0.1');

      final playlist = await _request(url);
      expect(playlist.statusCode, HttpStatus.ok);
      final content = await playlist.transform(SystemEncoding().decoder).join();
      expect(
        content,
        startsWith('#EXTM3U\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n'),
      );
      expect(content, contains('segment_00000.m4s'));
      final playlistHead = await _request(url, method: 'HEAD');
      expect(playlistHead.contentLength, playlist.contentLength);
      expect(await playlistHead.toList(), isEmpty);
      // The writer's atomic snapshot is unchanged by the served start hint.
      expect(
        await File('${dir.path}/index.m3u8').readAsString(),
        _openPlaylist,
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
        '${dir.path}/segment_99999.m4s',
      ).create('${dir.path}/init.mp4');
      expect(
        (await _request(url.resolve('segment_99999.m4s'))).statusCode,
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
      await media.finished;
      expect(media.complete, isTrue);
      expect(media.timeline.value.complete, isTrue);
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
    await expectLater(media.finished, throwsA(isA<ProviderException>()));
    expect(media.timeline.value.complete, isFalse);
    await media.close();
  });

  test(
    'timeline grows from published EXTINF pairs and finalizes after ENDLIST',
    () async {
      final job = _Job();
      final media = ProgressiveMedia(dir, job);
      await _writeReady(dir);
      await media.start();
      expect(media.timeline.value.duration, const Duration(seconds: 6));

      final updates = <ProgressiveTimeline>[];
      void record() => updates.add(media.timeline.value);
      media.timeline.addListener(record);
      await File('${dir.path}/segment_00003.m4s').writeAsBytes([11]);
      await File('${dir.path}/index.m3u8').writeAsString(
        '''$_openPlaylist#EXTINF:1.500000,
segment_00003.m4s
''',
      );
      await _waitForDuration(media, const Duration(milliseconds: 7500));
      expect(media.timeline.value.complete, isFalse);
      expect(updates.single.duration, const Duration(milliseconds: 7500));

      await File('${dir.path}/index.m3u8').writeAsString(
        '''$_openPlaylist#EXTINF:1.500000,
segment_00003.m4s
#EXT-X-ENDLIST
''',
      );
      job.finish();
      await media.finished;
      expect(media.timeline.value.duration, const Duration(milliseconds: 7500));
      expect(media.timeline.value.complete, isTrue);
      expect(updates.last.complete, isTrue);
      media.timeline.removeListener(record);
      await media.close();
    },
  );

  test('invalid or incomplete playlists never invent a duration', () async {
    final invalid = <String>[
      _openPlaylist.replaceFirst('#EXT-X-TARGETDURATION:2\n', ''),
      _openPlaylist.replaceFirst('TARGETDURATION:2', 'TARGETDURATION:0'),
      _openPlaylist.replaceFirst('TARGETDURATION:2', 'TARGETDURATION:NaN'),
      _openPlaylist.replaceFirst('TARGETDURATION:2', 'TARGETDURATION:1.5'),
      _openPlaylist.replaceFirst(
        'TARGETDURATION:2',
        'TARGETDURATION:99999999999',
      ),
      _openPlaylist.replaceFirst(
        '#EXT-X-TARGETDURATION:2',
        '#EXT-X-TARGETDURATION:2\n#EXT-X-TARGETDURATION:2',
      ),
      _openPlaylist.replaceFirst('2.000000', 'NaN'),
      _openPlaylist.replaceFirst('2.000000', 'Infinity'),
      _openPlaylist.replaceFirst('2.000000', '0'),
      _openPlaylist.replaceFirst('2.000000,', '2.000000'),
      _openPlaylist.replaceFirst('segment_00000.m4s\n', ''),
      _openPlaylist.trimRight(),
      _openPlaylist.replaceFirst('segment_00000.m4s', 'segment_00001.m4s'),
    ];
    for (var i = 0; i < invalid.length; i++) {
      final caseDir = await Directory('${dir.path}/case-$i').create();
      await _writeReady(caseDir);
      await File('${caseDir.path}/index.m3u8').writeAsString(invalid[i]);
      final job = _Job()..finish();
      final media = ProgressiveMedia(caseDir, job);
      await expectLater(media.start(), throwsA(isA<ProviderException>()));
      await expectLater(media.finished, throwsA(isA<ProviderException>()));
      expect(media.timeline.value.duration, Duration.zero, reason: 'case $i');
      await media.close();
    }
  });

  test(
    'malformed update preserves the last valid range and fails finalization',
    () async {
      await _writeReady(dir);
      final job = _Job();
      final media = ProgressiveMedia(dir, job);
      await media.start();
      await File('${dir.path}/segment_00003.m4s').writeAsBytes([11]);
      await File('${dir.path}/index.m3u8').writeAsString(
        '''$_openPlaylist#EXTINF:Infinity,
segment_00003.m4s
#EXT-X-ENDLIST
''',
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(media.timeline.value.duration, const Duration(seconds: 6));
      expect(media.timeline.value.complete, isFalse);
      job.finish();
      await expectLater(media.finished, throwsA(isA<ProviderException>()));
      expect(media.timeline.value.duration, const Duration(seconds: 6));
      expect(media.timeline.value.complete, isFalse);
      await media.close();
    },
  );

  test('cancel stops observation before notifier disposal', () async {
    await _writeReady(dir);
    final job = _Job();
    final media = ProgressiveMedia(dir, job);
    await media.start();
    var notifications = 0;
    void record() => notifications++;
    media.timeline.addListener(record);
    media.timeline.removeListener(record);
    await media.close();
    await File('${dir.path}/segment_00003.m4s').writeAsBytes([11]);
    await File('${dir.path}/index.m3u8').writeAsString(
      '''$_openPlaylist#EXTINF:2,
segment_00003.m4s
''',
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(notifications, 0);
    expect(media.timeline.value.duration, const Duration(seconds: 6));
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
