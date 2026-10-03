import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/media_executor.dart';
import 'package:guoguo_mobile/platform/media_preparer.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Job implements MediaExecution {
  final _result = Completer<void>();
  int cancellations = 0;
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
    if (!_result.isCompleted) {
      _result.completeError(const ProviderException('已取消准备'));
    }
  }
}

class _Executor implements MediaExecutor {
  final jobs = <_Job>[];
  final arguments = <List<String>>[];
  final started = Completer<void>();
  Completer<void>? startGate;
  Future<void> Function(List<String>, _Job)? onStart;

  @override
  Future<MediaExecution> start(List<String> args) async {
    arguments.add(args);
    if (!started.isCompleted) started.complete();
    await startGate?.future;
    final job = _Job();
    jobs.add(job);
    await onStart?.call(args, job);
    return job;
  }
}

ResolvedMedia _media({
  bool hls = false,
  String key = '00112233445566778899aabbccddeeff',
}) => ResolvedMedia.fromJson({
  'url': 'https://example.test/media.mp4',
  'remoteUrl': 'https://example.test/media.mp4',
  'contentKey': key,
  'hls': hls,
});

Future<void> _publish(String playlist) async {
  final dir = File(playlist).parent;
  await File('${dir.path}/init.mp4').writeAsBytes([1]);
  await File('${dir.path}/segment_00000.m4s').writeAsBytes([2]);
  await File('${dir.path}/segment_00001.m4s').writeAsBytes([3]);
  await File('${dir.path}/segment_00002.m4s').writeAsBytes([4]);
  await File(playlist).writeAsString('''#EXTM3U
#EXT-X-TARGETDURATION:2
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2,
segment_00000.m4s
#EXTINF:2,
segment_00001.m4s
#EXTINF:2,
segment_00002.m4s
''');
}

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('preparer-test-'),
  );
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'progressive returns while native job runs; dispose cancels then removes files',
    () async {
      final executor = _Executor()
        ..onStart = (args, job) => _publish(args.last);
      final preparer = MediaPreparer(
        executor: executor,
        temporaryDirectory: () async => root,
      );
      final url = await preparer.prepare(_media(), progressive: true);
      expect(url, startsWith('http://127.0.0.1:'));
      expect(preparer.streaming, isTrue);
      expect(preparer.complete, isFalse);
      expect(preparer.timeline?.value.duration, const Duration(seconds: 6));
      expect(preparer.timeline?.value.complete, isFalse);
      expect(preparer.fellBack, isFalse);
      expect(executor.arguments.single, contains('-hls_playlist_type'));
      final session = Directory(
        File(executor.arguments.single.last).parent.parent.path,
      );
      expect(await session.exists(), isTrue);
      await preparer.dispose();
      expect(executor.jobs.single.cancellations, 1);
      expect(await session.exists(), isFalse);
    },
  );

  test(
    'startup timeout safely cancels progressive job then remuxes complete MP4',
    () async {
      final executor = _Executor();
      executor.onStart = (args, job) async {
        if (args.last.endsWith('.mp4')) {
          await File(args.last).writeAsBytes([1, 2, 3]);
          job.finish();
        }
      };
      final preparer = MediaPreparer(
        executor: executor,
        temporaryDirectory: () async => root,
        startupTimeout: const Duration(milliseconds: 30),
      );
      final path = await preparer.prepare(_media(), progressive: true);
      expect(preparer.fellBack, isTrue);
      expect(preparer.streaming, isFalse);
      expect(preparer.complete, isTrue);
      expect(preparer.timeline, isNull);
      expect(executor.arguments.length, 2);
      expect(executor.jobs.first.cancellations, 1);
      expect(await File(path).readAsBytes(), [1, 2, 3]);
      expect(
        await Directory('${File(path).parent.path}/stream').exists(),
        isFalse,
      );
      await preparer.finished;
      await preparer.dispose();
      expect(await File(path).exists(), isFalse);
    },
  );

  test(
    'cancellation during native startup cannot publish a stale stream or fall back',
    () async {
      final executor = _Executor()..startGate = Completer<void>();
      final preparer = MediaPreparer(
        executor: executor,
        temporaryDirectory: () async => root,
      );
      final preparing = preparer.prepare(_media(), progressive: true);
      await executor.started.future;
      final cancelling = preparer.cancel();
      executor.startGate!.complete();
      await cancelling;
      await expectLater(preparing, throwsA(isA<ProviderException>()));
      expect(preparer.fellBack, isFalse);
      expect(executor.jobs.single.cancellations, 1);
      await preparer.dispose();
      expect(await Directory('${root.path}/playback').list().toList(), isEmpty);
    },
  );

  test('plain media returns its URL without a native job', () async {
    final executor = _Executor();
    final preparer = MediaPreparer(
      executor: executor,
      temporaryDirectory: () async => root,
    );
    expect(
      await preparer.prepare(_media(key: ''), progressive: true),
      _media(key: '').url,
    );
    expect(executor.arguments, isEmpty);
    expect(preparer.timeline, isNull);
    await preparer.dispose();
  });

  test(
    'finished exposes the final playlist timeline before resolving',
    () async {
      final executor = _Executor()
        ..onStart = (args, job) => _publish(args.last);
      final preparer = MediaPreparer(
        executor: executor,
        temporaryDirectory: () async => root,
      );
      await preparer.prepare(_media(), progressive: true);
      final timeline = preparer.timeline!;
      expect(timeline.value.duration, const Duration(seconds: 6));
      expect(timeline.value.complete, isFalse);
      await File(executor.arguments.single.last).writeAsString('''#EXTM3U
#EXT-X-TARGETDURATION:2
#EXT-X-MAP:URI="init.mp4"
#EXTINF:2,
segment_00000.m4s
#EXTINF:2,
segment_00001.m4s
#EXTINF:2,
segment_00002.m4s
#EXT-X-ENDLIST
''');
      executor.jobs.single.finish();
      await preparer.finished;
      expect(timeline.value.duration, const Duration(seconds: 6));
      expect(timeline.value.complete, isTrue);
      expect(preparer.complete, isTrue);
      await preparer.dispose();
    },
  );
}
