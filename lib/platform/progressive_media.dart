import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'media_executor.dart';
import 'provider_client.dart';

@immutable
class ProgressiveTimeline {
  const ProgressiveTimeline({required this.duration, required this.complete});

  /// Duration covered by published, nonempty fragments in the EVENT playlist.
  final Duration duration;

  /// True only after the writer exits and publishes a valid ENDLIST.
  final bool complete;
}

class _PlaylistObservation {
  const _PlaylistObservation(this.duration, this.ended);
  final Duration duration;
  final bool ended;
}

/// A private loopback origin serving only completed output of one media job.
class ProgressiveMedia {
  ProgressiveMedia(
    this.directory,
    this.execution, {
    this.maxBytes = 128 * 1024 * 1024,
    this.maxDuration = const Duration(minutes: 5),
  }) {
    _completion = execution.done.then<void>(
      (_) async {
        _writerFinished = true;
        // An inspection may have read the previous atomic playlist just as
        // FFmpeg exited. Wait for it, then read the final snapshot ourselves.
        await _inspection;
        if (!_closed) await _inspect();
        if (!_closed && !complete) {
          failure ??= const ProviderException('视频未生成完整播放列表');
        }
        _monitor?.cancel();
      },
      onError: (Object _) {
        failure ??= const ProviderException('视频准备中断，正在切换兼容方式');
        _monitor?.cancel();
      },
    );
  }
  final Directory directory;
  final MediaExecution execution;
  final int maxBytes;
  final Duration maxDuration;
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final Stopwatch _clock = Stopwatch()..start();
  late final Future<void> _completion;
  HttpServer? _server;
  Timer? _monitor;
  Future<void>? _closing;
  Future<void>? _inspection;
  bool _closed = false, _writerFinished = false, _ready = false;
  final ValueNotifier<ProgressiveTimeline> _timeline = ValueNotifier(
    const ProgressiveTimeline(duration: Duration.zero, complete: false),
  );
  ValueListenable<ProgressiveTimeline> get timeline => _timeline;
  bool get complete => _timeline.value.complete;
  Future<void> get finished async {
    await _completion;
    if (failure != null) throw failure!;
  }

  ProviderException? failure;
  String get url => 'http://127.0.0.1:${_server!.port}/$_token/index.m3u8';
  static final _segment = RegExp(r'^segment_[0-9]{5,}\.m4s$');

  Future<String> start({
    Duration startupTimeout = const Duration(seconds: 45),
  }) async {
    if (_closed) throw const ProviderException('已取消准备');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw const ProviderException('已取消准备');
    }
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
    _monitor = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_inspect()),
    );
    while (!_closed) {
      await _inspect();
      if (failure != null) throw failure!;
      if (_ready) {
        // The writer may have exited during an earlier inspection. Do not
        // return that live snapshot until the final playlist has been checked.
        if (_writerFinished && !complete) await _completion;
        if (_closed) throw const ProviderException('已取消准备');
        if (failure != null) throw failure!;
        if (_writerFinished && !complete) {
          throw const ProviderException('视频未生成完整播放列表');
        }
        return url;
      }
      if (_writerFinished) throw const ProviderException('视频未生成可播放分片');
      if (_clock.elapsed >= startupTimeout) {
        throw const ProviderException('提前开播准备超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const ProviderException('已取消准备');
  }

  Future<_PlaylistObservation?> _readPlaylist() async {
    final playlist = File('${directory.path}/index.m3u8');
    try {
      if (await FileSystemEntity.type(playlist.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      if (await playlist.length() > 256 * 1024) {
        throw const ProviderException('播放列表过大');
      }
      // FFmpeg uses temp_file and rename, so one read is one whole snapshot.
      final text = await playlist.readAsString();
      if (!text.endsWith('\n')) return null;
      final lines = text.split('\n').map((line) => line.trim()).toList();
      if (lines.first != '#EXTM3U' ||
          !lines.any(
            (line) =>
                line.startsWith('#EXT-X-MAP:') &&
                line.contains('URI="init.mp4"'),
          )) {
        return null;
      }
      if (!await _publishedFile('init.mp4')) return null;

      var seconds = 0.0;
      double? pending;
      var segments = 0;
      var ended = false;
      final seen = <String>{};
      for (final line in lines.skip(1)) {
        if (line.isEmpty) continue;
        if (ended) return null;
        if (line.startsWith('#EXTINF:')) {
          if (pending != null) return null;
          if (line.indexOf(',') <= 8) return null;
          final value = line.substring(8).split(',').first.trim();
          pending = double.tryParse(value);
          if (pending == null || !pending.isFinite || pending <= 0) return null;
        } else if (line == '#EXT-X-ENDLIST') {
          if (pending != null) return null;
          ended = true;
        } else if (line.startsWith('#')) {
          if (pending != null) return null;
        } else {
          if (pending == null ||
              !_segment.hasMatch(line) ||
              !seen.add(line) ||
              !await _publishedFile(line)) {
            return null;
          }
          seconds += pending;
          if (!seconds.isFinite || seconds * 1000000 > 9007199254740991) {
            return null;
          }
          segments++;
          pending = null;
        }
      }
      if (pending != null || segments == 0) return null;
      final micros = (seconds * 1000000).round();
      if (micros <= 0) return null;
      return _PlaylistObservation(Duration(microseconds: micros), ended);
    } on FileSystemException {
      // An atomic replacement can race a file lookup; the next poll retries.
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> _publishedFile(String name) async {
    final path = '${directory.path}/$name';
    return await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file &&
        await File(path).length() > 0;
  }

  Future<void> _inspect() {
    if (_closed || failure != null) return Future.value();
    return _inspection ??= _inspectBody().whenComplete(
      () => _inspection = null,
    );
  }

  Future<void> _inspectBody() async {
    final finalPass = _writerFinished;
    try {
      var bytes = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) bytes += await entity.length();
      }
      if (_closed) return;
      if (bytes > maxBytes ||
          (!_writerFinished && _clock.elapsed > maxDuration)) {
        failure = const ProviderException('视频准备超过资源限制，正在切换兼容方式');
        _monitor?.cancel();
        await execution.cancel();
        return;
      }
      final snapshot = await _readPlaylist();
      if (_closed) return;
      _ready = snapshot != null;
      if (snapshot == null ||
          snapshot.duration < _timeline.value.duration ||
          (finalPass && !snapshot.ended)) {
        if (finalPass) {
          failure ??= const ProviderException('视频未生成完整播放列表');
          _monitor?.cancel();
        }
        return;
      }
      final finalized = finalPass && snapshot.ended;
      final previous = _timeline.value;
      if (snapshot.duration != previous.duration ||
          finalized != previous.complete) {
        _timeline.value = ProgressiveTimeline(
          duration: snapshot.duration,
          complete: finalized,
        );
      }
      if (finalized) _monitor?.cancel();
    } catch (_) {
      // Timer callbacks must never leak an asynchronous error. If cancelling
      // failed, close() will retry/propagate it so the writer's files remain.
      if (!_closed) {
        failure ??= const ProviderException('无法读取或停止临时视频');
        _monitor?.cancel();
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final parts = request.uri.pathSegments;
      if (parts.length != 2 ||
          parts[0] != _token ||
          !(parts[1] == 'index.m3u8' ||
              parts[1] == 'init.mp4' ||
              _segment.hasMatch(parts[1]))) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return;
      }
      if (_closed || failure != null) {
        response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      final file = File('${directory.path}/${parts[1]}');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final playlist = parts[1] == 'index.m3u8';
      response.headers.contentType = ContentType(
        playlist ? 'application' : 'video',
        playlist ? 'vnd.apple.mpegurl' : 'mp4',
      );
      if (playlist) {
        if (await file.length() > 256 * 1024) {
          response.statusCode = HttpStatus.serviceUnavailable;
          return;
        }
        // Atomic replacement allows this request to read one complete snapshot.
        final bytes = await file.readAsBytes();
        response.contentLength = bytes.length;
        if (request.method == 'GET') response.add(bytes);
        return;
      }
      final size = await file.length();
      var start = 0, end = size - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return;
        }
        if (match[1]!.isEmpty) {
          final suffix = int.tryParse(match[2]!);
          start = suffix == null || suffix <= 0 ? size : max(0, size - suffix);
        } else {
          start = int.tryParse(match[1]!) ?? size;
          if (match[2]!.isNotEmpty) {
            end = min(end, int.tryParse(match[2]!) ?? -1);
          }
        }
        if (start >= size || end < start) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.contentLength = max(0, end - start + 1);
      if (request.method == 'GET') {
        await response.addStream(file.openRead(start, end + 1));
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.serviceUnavailable;
      } catch (_) {
        /* Already sent. */
      }
    } finally {
      try {
        if (response.statusCode >= 400 && request.method != 'HEAD') {
          // BetterPlayer's metadata parser also reads non-2xx bodies. A plain
          // message avoids its empty-input RangeError while native sees 503.
          response.write('Media unavailable\n');
        }
      } catch (_) {
        /* Headers or body were already sent. */
      }
      try {
        await response.close();
      } catch (_) {
        /* Player disconnected. */
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _monitor?.cancel();
    await _server?.close(force: true);
    if (!_writerFinished) await execution.cancel();
    await _completion;
    await _inspection;
    _timeline.dispose();
  }
}
