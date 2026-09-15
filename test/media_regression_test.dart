import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/media_commands.dart';

void main() {
  test('native errors are useful without leaking media credentials', () {
    expect(
      mediaFailureMessage('HTTP 403 https://example.test/?token=secret', 1),
      contains('访问被拒绝'),
    );
    expect(
      mediaFailureMessage('No space left on device', 1),
      contains('存储空间不足'),
    );
    expect(
      mediaFailureMessage('unknown error with key secret', 2),
      isNot(contains('secret')),
    );
  });

  final ffmpeg = Platform.environment['GUOGUO_FFMPEG'];
  final nativeSkip = ffmpeg == null
      ? 'Set GUOGUO_FFMPEG to run native media regression'
      : false;
  Future<ProcessResult> run(List<String> args) => Process.run(ffmpeg!, args);
  Future<void> succeeds(List<String> args) async {
    final result = await run(args);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  test('CENC MP4 prepares and decodes', () async {
    final dir = await Directory.systemTemp.createTemp(
      'guoguo-media-regression-',
    );
    addTearDown(() => dir.delete(recursive: true));

    const key = '00112233445566778899aabbccddeeff';
    final encrypted = '${dir.path}/encrypted.mp4';
    final output = '${dir.path}/ready.mp4';
    await succeeds([
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
      '-threads',
      '1',
      '-pix_fmt',
      'yuv420p',
      '-encryption_scheme',
      'cenc-aes-ctr',
      '-encryption_key',
      key,
      '-encryption_kid',
      key,
      encrypted,
    ]);
    // Reproduce the exact previous failure before checking the repaired path.
    final old = await run([
      '-allowed_extensions',
      'ALL',
      ...remuxArguments(input: encrypted, output: output, contentKey: key),
    ]);
    expect(old.exitCode, isNot(0));
    expect('${old.stderr}', contains('allowed_extensions'));
    await succeeds(
      remuxArguments(input: encrypted, output: output, contentKey: key),
    );
    await succeeds(['-v', 'error', '-xerror', '-i', output, '-f', 'null', '-']);
  }, skip: nativeSkip);
  test(
    'downloaded HLS with opaque segment names remuxes and decodes',
    () async {
      final help = await run(['-hide_banner', '-h', 'demuxer=hls']);
      if (!'${help.stdout}${help.stderr}'.contains('extension_picky')) {
        markTestSkipped('Requires modern FFmpeg HLS demuxer, as linked on iOS');
        return;
      }
      final dir = await Directory.systemTemp.createTemp(
        'guoguo-hls-regression-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final playlist = '${dir.path}/index.m3u8';
      await succeeds([
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=size=180x320:rate=10',
        '-t',
        '1',
        '-c:v',
        'libx264',
        '-threads',
        '1',
        '-f',
        'hls',
        playlist,
      ]);
      // The download planner deliberately stores segment resources as .bin.
      final manifest = File(playlist);
      await File('${dir.path}/index0.ts').rename('${dir.path}/asset_0001.bin');
      await manifest.writeAsString(
        (await manifest.readAsString()).replaceAll(
          'index0.ts',
          'asset_0001.bin',
        ),
      );
      await succeeds(
        remuxArguments(
          input: playlist,
          output: '${dir.path}/offline.mp4',
          hls: true,
        ),
      );
      await succeeds([
        '-v',
        'error',
        '-xerror',
        '-i',
        '${dir.path}/offline.mp4',
        '-f',
        'null',
        '-',
      ]);
    },
    skip: nativeSkip,
  );
}
