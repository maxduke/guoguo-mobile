import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_full/log_redirection_strategy.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import 'provider_client.dart';
import 'media_commands.dart';

/// Uses linked native FFmpeg libraries. No subprocess or executable download.
class MediaPreparer {
  int? _session;
  bool _cancelled = false;
  Directory? _temporary;
  String? _ownedFile;
  Future<void>? _operation;
  Future<void>? _disposal;
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
      hls: media.hls,
    );
    return target;
  }

  Future<void> remux({
    required String input,
    required String output,
    String contentKey = '',
    Map<String, String> headers = const {},
    bool hls = false,
  }) => _operation = _remux(
    input: input,
    output: output,
    contentKey: contentKey,
    headers: headers,
    hls: hls,
  );

  Future<void> _remux({
    required String input,
    required String output,
    required String contentKey,
    required Map<String, String> headers,
    required bool hls,
  }) async {
    if (_cancelled) throw const ProviderException('已取消准备');
    FFmpegKitConfig.setLogRedirectionStrategy(
      LogRedirectionStrategy.neverPrintLogs,
    );
    await FFmpegKitConfig.enableLogs();
    if (_cancelled) throw const ProviderException('已取消准备');
    final done = Completer<void>();
    // Native completion can arrive before executeWithArgumentsAsync returns.
    unawaited(
      done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final session = await FFmpegKit.executeWithArgumentsAsync(
      remuxArguments(
        input: input,
        output: output,
        contentKey: contentKey,
        headers: headers,
        hls: hls,
      ),
      (session) async {
        try {
          final code = await session.getReturnCode();
          if (done.isCompleted) return;
          if (ReturnCode.isSuccess(code)) {
            done.complete();
          } else {
            final log = await session.getAllLogsAsString() ?? '';
            done.completeError(
              ProviderException(
                _cancelled
                    ? '已取消准备'
                    : mediaFailureMessage(log, code?.getValue()),
              ),
            );
          }
        } catch (_) {
          if (!done.isCompleted) {
            done.completeError(const ProviderException('无法读取视频处理结果，请重试'));
          }
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

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await cancel();
    try {
      await _operation;
    } catch (_) {
      /* Cleanup failed or cancelled output. */
    }
    final path = _ownedFile;
    _ownedFile = null;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}
