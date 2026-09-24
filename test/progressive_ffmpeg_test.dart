import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/media_executor.dart';
import 'package:guoguo_mobile/platform/media_preparer.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _ProcessJob implements MediaExecution {
  _ProcessJob(this.process) {
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    done = process.exitCode.then((code) {
      if (code != 0) throw ProviderException('ffmpeg exited $code');
    });
    unawaited(done.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final Process process;
  @override
  late final Future<void> done;
  @override
  Future<void> cancel() async {
    process.kill();
    try {
      await done;
    } catch (_) {
      // The process was terminated intentionally.
    }
  }
}

class _ProcessExecutor implements MediaExecutor {
  _ProcessExecutor(this.ffmpeg);
  final String ffmpeg;
  @override
  Future<MediaExecution> start(List<String> arguments) async {
    final args = [...arguments];
    // Pace the synthetic local source to model a network transfer. The app
    // passes the original command unchanged to its linked FFmpeg adapter.
    args.insert(args.indexOf('-i'), '-re');
    return _ProcessJob(await Process.start(ffmpeg, args));
  }
}

Future<ProcessResult> _run(String ffmpeg, List<String> args) async {
  final result = await Process.run(ffmpeg, args);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result;
}

void main() {
  final ffmpeg = Platform.environment['GUOGUO_FFMPEG'];
  test(
    'CENC stream opens before completion and decodes to the source frames',
    () async {
      final dir = await Directory.systemTemp.createTemp('progressive-ffmpeg-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      const key = '00112233445566778899aabbccddeeff';
      final source = '${dir.path}/encrypted.mp4';
      await _run(ffmpeg!, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=180x320:rate=10',
        '-t',
        '8',
        '-c:v',
        'libx264',
        '-threads',
        '1',
        '-pix_fmt',
        'yuv420p',
        '-g',
        '20',
        '-keyint_min',
        '20',
        '-sc_threshold',
        '0',
        '-encryption_scheme',
        'cenc-aes-ctr',
        '-encryption_key',
        key,
        '-encryption_kid',
        key,
        source,
      ]);

      final preparer = MediaPreparer(
        executor: _ProcessExecutor(ffmpeg),
        temporaryDirectory: () async => dir,
        startupTimeout: const Duration(seconds: 15),
      );
      addTearDown(preparer.dispose);
      final media = ResolvedMedia.fromJson({
        'url': source,
        'remoteUrl': source,
        'contentKey': key,
      });
      final clock = Stopwatch()..start();
      final url = await preparer.prepare(media, progressive: true);
      final readyMs = clock.elapsedMilliseconds;
      expect(preparer.streaming, isTrue);
      expect(
        preparer.complete,
        isFalse,
        reason:
            'the first playable fragment must arrive while FFmpeg is running',
      );
      expect(preparer.fellBack, isFalse);

      final firstFrame = await _run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-xerror',
        '-decryption_key',
        key,
        '-i',
        source,
        '-frames:v',
        '1',
        '-f',
        'md5',
        '-',
      ]);
      final streamedFrame = await _run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-xerror',
        '-i',
        url,
        '-frames:v',
        '1',
        '-f',
        'md5',
        '-',
      ]);
      expect(streamedFrame.stdout, firstFrame.stdout);

      await preparer.finished.timeout(const Duration(seconds: 15));
      final completeMs = clock.elapsedMilliseconds;
      expect(preparer.complete, isTrue);
      expect(completeMs, greaterThan(readyMs));
      final originalFrames = await _run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-xerror',
        '-decryption_key',
        key,
        '-i',
        source,
        '-f',
        'md5',
        '-',
      ]);
      final streamedFrames = await _run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-xerror',
        '-i',
        url,
        '-f',
        'md5',
        '-',
      ]);
      expect(streamedFrames.stdout, originalFrames.stdout);
      // Retain the measurements in the test log for platform comparisons.
      // ignore: avoid_print
      print(
        'CENC 8s paced source: ready=${readyMs}ms complete=${completeMs}ms',
      );
      await preparer.dispose();
    },
    skip: ffmpeg == null
        ? 'Set GUOGUO_FFMPEG to run linked-command regression'
        : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
