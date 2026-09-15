import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import 'provider_client.dart';

/// Uses linked native FFmpeg libraries. No subprocess or executable download.
class MediaPreparer {
  int? _session;
  bool _cancelled = false;
  Directory? _temporary;
  String? _ownedFile;
  Future<String> prepare(ResolvedMedia media) async {
    if (media.contentKey.isEmpty) return media.url;
    final root = await getTemporaryDirectory();
    _temporary = await Directory(
      '${root.path}/playback',
    ).create(recursive: true);
    final target =
        '${_temporary!.path}/${DateTime.now().microsecondsSinceEpoch}.mp4';
    _ownedFile = target;
    await remux(
      input: media.url,
      output: target,
      contentKey: media.contentKey,
      headers: media.headers,
    );
    return target;
  }

  Future<void> remux({
    required String input,
    required String output,
    String contentKey = '',
    Map<String, String> headers = const {},
  }) async {
    if (_cancelled) throw const ProviderException('已取消准备');
    await FFmpegKitConfig.disableLogs();
    final done = Completer<void>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-y',
        if (input.startsWith('http')) ...[
          '-rw_timeout',
          '20000000',
          '-headers',
          headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join(),
        ],
        if (contentKey.isNotEmpty) ...['-decryption_key', contentKey],
        '-allowed_extensions',
        'ALL',
        '-protocol_whitelist',
        'file,http,https,tcp,tls,crypto,data',
        '-i',
        input,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        output,
      ],
      (session) async {
        final code = await session.getReturnCode();
        if (done.isCompleted) return;
        if (ReturnCode.isSuccess(code)) {
          done.complete();
        } else {
          done.completeError(const ProviderException('视频准备未完成，请检查网络后重试'));
        }
      },
    );
    _session = session.getSessionId();
    if (_cancelled) await FFmpegKit.cancel(_session);
    try {
      await done.future.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      await FFmpegKit.cancel(_session);
      throw const ProviderException('视频准备超时，请重试');
    } finally {
      _session = null;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    final session = _session;
    if (session != null) await FFmpegKit.cancel(session);
  }

  Future<void> dispose() async {
    await cancel();
    final path = _ownedFile;
    _ownedFile = null;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}
