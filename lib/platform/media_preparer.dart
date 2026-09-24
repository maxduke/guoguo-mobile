import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';
import 'provider_client.dart';
import 'media_commands.dart';
import 'media_executor.dart';
import 'progressive_media.dart';
export 'progressive_media.dart' show ProgressiveTimeline;

/// Owns each preparation's native job, loopback origin and temporary files.
class MediaPreparer {
  MediaPreparer({
    MediaExecutor? executor,
    Future<Directory> Function()? temporaryDirectory,
    this.startupTimeout = const Duration(seconds: 45),
  }) : _executor = executor ?? const NativeMediaExecutor(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  final MediaExecutor _executor;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration startupTimeout;
  MediaExecution? _job;
  Future<MediaExecution>? _starting;
  ProgressiveMedia? _progressive;
  Directory? _ownedDirectory;
  bool _cancelled = false;
  bool fellBack = false;
  Future<void>? _operation;
  Future<String>? _preparing;
  Future<void>? _disposal;
  Future<void>? _cancellation;
  bool get streaming => _progressive != null;
  bool get complete => _progressive?.complete ?? true;
  ValueListenable<ProgressiveTimeline>? get timeline => _progressive?.timeline;
  ProviderException? get failure => _progressive?.failure;
  Future<void> get finished =>
      _progressive?.finished ?? _operation ?? Future.value();

  Future<String> prepare(ResolvedMedia media, {bool progressive = false}) =>
      _preparing ??= _prepare(media, progressive);

  Future<String> _prepare(ResolvedMedia media, bool progressive) async {
    _checkCancelled();
    if (media.contentKey.isEmpty) return media.url;
    final root = await _temporaryDirectory();
    _checkCancelled();
    final playback = await Directory(
      '${root.path}/playback',
    ).create(recursive: true);
    _ownedDirectory = await playback.createTemp('session-');
    _checkCancelled();
    if (progressive && !media.hls) {
      final directory = await Directory(
        '${_ownedDirectory!.path}/stream',
      ).create();
      try {
        final job = await _start(
          progressiveArguments(
            input: media.url,
            directory: directory.path,
            contentKey: media.contentKey,
            headers: media.headers,
          ),
        );
        _checkCancelled();
        _operation = job.done;
        _progressive = ProgressiveMedia(directory, job);
        final url = await _progressive!.start(startupTimeout: startupTimeout);
        _checkCancelled();
        return url;
      } catch (_) {
        await _progressive?.close();
        if (_cancelled) await cancel();
        _progressive = null;
        // Native writes have stopped before removing a failed attempt.
        await directory.delete(recursive: true);
        _checkCancelled();
        fellBack = true;
      }
    }
    final target = '${_ownedDirectory!.path}/complete.mp4';
    await remux(
      input: media.url,
      output: target,
      contentKey: media.contentKey,
      headers: media.headers,
      hls: media.hls,
    );
    return target;
  }

  void _checkCancelled() {
    if (_cancelled) throw const ProviderException('已取消准备');
  }

  Future<MediaExecution> _start(List<String> arguments) async {
    _checkCancelled();
    final job = await (_starting = _executor.start(arguments));
    _job = job;
    _checkCancelled();
    return job;
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
    final job = await _start(
      remuxArguments(
        input: input,
        output: output,
        contentKey: contentKey,
        headers: headers,
        hls: hls,
      ),
    );
    await job.done.timeout(
      const Duration(minutes: 5),
      onTimeout: () async {
        await job.cancel();
        throw const ProviderException('视频准备超时，请重试');
      },
    );
    _checkCancelled();
  }

  Future<void> cancel() => _cancellation ??= _cancel();

  Future<void> _cancel() async {
    _cancelled = true;
    try {
      await _starting;
    } catch (_) {
      /* Failed startup has no running job. */
    }
    if (_progressive != null) {
      await _progressive!.close();
    } else {
      await _job?.cancel();
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    await cancel();
    try {
      await _preparing;
    } catch (_) {
      /* Failed or canceled preparation. */
    }
    try {
      await _operation;
    } catch (_) {
      /* Failed or canceled native job. */
    }
    final directory = _ownedDirectory;
    _ownedDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
