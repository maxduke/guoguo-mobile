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

  Future<MediaNativeSession> execute(
    List<String> arguments,
    void Function(MediaNativeSession) onComplete,
  );

  Future<void> cancel(int sessionId);
}

abstract interface class MediaNativeSession {
  int get id;

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
    final execution = _NativeMediaExecution(_adapter);
    try {
      await _adapter.configure();
      final session = await _adapter.execute(arguments, execution.complete);
      execution.setSessionId(session.id);
      return execution;
    } catch (_) {
      // Native exceptions may contain the command's URL, headers or key.
      throw const ProviderException('无法启动视频处理，请重试');
    }
  }
}

class _NativeMediaExecution implements MediaExecution {
  _NativeMediaExecution(this._adapter) {
    // Completion can precede start() returning, or even its caller attaching a
    // listener. Observe errors immediately while preserving them for done.
    unawaited(
      _done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  final MediaNativeAdapter _adapter;
  final Completer<void> _done = Completer<void>();
  int? _sessionId;
  bool _cancelled = false;
  Future<void>? _cancellation;

  @override
  Future<void> get done => _done.future;

  void setSessionId(int id) => _sessionId = id;

  void complete(MediaNativeSession session) {
    unawaited(_finish(session));
  }

  Future<void> _finish(MediaNativeSession session) async {
    try {
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
    final sessionId = _sessionId;
    if (sessionId == null) {
      throw const ProviderException('无法取消视频处理，请重试');
    }
    try {
      await _adapter.cancel(sessionId);
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
  Future<MediaNativeSession> execute(
    List<String> arguments,
    void Function(MediaNativeSession) onComplete,
  ) async {
    final session = await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (session) => onComplete(_FfmpegMediaSession(session)),
    );
    return _FfmpegMediaSession(session);
  }

  @override
  Future<void> cancel(int sessionId) => FFmpegKit.cancel(sessionId);
}

class _FfmpegMediaSession implements MediaNativeSession {
  const _FfmpegMediaSession(this._session);

  final FFmpegSession _session;

  @override
  int get id => _session.getSessionId()!;

  @override
  Future<int?> returnCode() async =>
      (await _session.getReturnCode())?.getValue();

  @override
  Future<String> logs() async => await _session.getAllLogsAsString() ?? '';
}
