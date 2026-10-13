import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_full/log_redirection_strategy.dart';

import 'media_commands.dart';
import 'provider_client.dart';

abstract interface class MediaExecution {
  Future<void> get done;

  Future<void> cancel();
}

abstract interface class MediaExecutor {
  Future<MediaExecution> start(List<String> arguments);
}

/// The native boundary is injectable so session lifecycle can be tested without
/// a device or a second FFmpeg installation.
abstract interface class MediaNativeAdapter {
  Future<void> configure();

  Future<MediaNativeSession> execute(List<String> arguments);

  Future<void> cancel(int sessionId);
}

abstract interface class MediaNativeSession {
  int get id;

  Future<void> get done;

  Future<int?> returnCode();

  Future<String> logs();
}

/// Executes arguments with the FFmpeg libraries linked into the application.
class NativeMediaExecutor implements MediaExecutor {
  const NativeMediaExecutor({
    MediaNativeAdapter adapter = const _FfmpegMediaAdapter(),
  }) : _adapter = adapter;

  final MediaNativeAdapter _adapter;

  @override
  Future<MediaExecution> start(List<String> arguments) async {
    try {
      await _adapter.configure();
      final session = await _adapter.execute(arguments);
      return _NativeMediaExecution(_adapter, session);
    } catch (_) {
      // Native exceptions may contain the command's URL, headers or key.
      throw const ProviderException('无法启动视频处理，请重试');
    }
  }
}

class _NativeMediaExecution implements MediaExecution {
  _NativeMediaExecution(this._adapter, MediaNativeSession session)
    : _sessionId = session.id {
    // Completion can precede start() returning, or even its caller attaching a
    // listener. Observe errors immediately while preserving them for done.
    unawaited(
      _done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(_finish(session));
  }

  final MediaNativeAdapter _adapter;
  final Completer<void> _done = Completer<void>();
  final int _sessionId;
  bool _cancelled = false;
  Future<void>? _cancellation;

  @override
  Future<void> get done => _done.future;

  Future<void> _finish(MediaNativeSession session) async {
    try {
      await session.done;
      final code = await session.returnCode();
      if (_done.isCompleted) return;
      if (_cancelled) {
        _done.completeError(const ProviderException('已取消准备'));
      } else if (code == 0) {
        _done.complete();
      } else {
        final log = await session.logs();
        if (_done.isCompleted) return;
        _done.completeError(
          ProviderException(
            _cancelled ? '已取消准备' : mediaFailureMessage(log, code),
          ),
        );
      }
    } catch (_) {
      if (!_done.isCompleted) {
        _done.completeError(
          ProviderException(_cancelled ? '已取消准备' : '无法读取视频处理结果，请重试'),
        );
      }
    }
  }

  @override
  Future<void> cancel() => _cancellation ??= _cancel();

  Future<void> _cancel() async {
    if (_done.isCompleted) return;
    _cancelled = true;
    try {
      await _adapter.cancel(_sessionId);
    } catch (_) {
      throw const ProviderException('无法取消视频处理，请重试');
    }
    try {
      await done;
    } on ProviderException {
      // Native cancellation normally completes with a non-success return code.
    }
  }
}

class _FfmpegMediaAdapter implements MediaNativeAdapter {
  const _FfmpegMediaAdapter();

  @override
  Future<void> configure() async {
    FFmpegKitConfig.setLogRedirectionStrategy(
      LogRedirectionStrategy.neverPrintLogs,
    );
    await FFmpegKitConfig.enableLogs();
  }

  @override
  Future<MediaNativeSession> execute(List<String> arguments) async {
    final session = await FFmpegSession.create(arguments);
    // The native method runs on a worker queue and completes with the job.
    // Per-session callbacks in this dependency are never removed from its
    // global registry; using the method's Future avoids retaining every job.
    return _FfmpegMediaSession(session, FFmpegKitConfig.ffmpegExecute(session));
  }

  @override
  Future<void> cancel(int sessionId) => FFmpegKit.cancel(sessionId);
}

class _FfmpegMediaSession implements MediaNativeSession {
  const _FfmpegMediaSession(this._session, this.done);

  final FFmpegSession _session;

  @override
  final Future<void> done;

  @override
  int get id => _session.getSessionId()!;

  @override
  Future<int?> returnCode() async =>
      (await _session.getReturnCode())?.getValue();

  @override
  Future<String> logs() async => await _session.getAllLogsAsString() ?? '';
}
