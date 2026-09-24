import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'media_executor.dart';
import 'provider_client.dart';

/// A private loopback origin serving only completed output of one media job.
class ProgressiveMedia {
  ProgressiveMedia(
    this.directory,
    this.execution, {
    this.maxBytes = 128 * 1024 * 1024,
    this.maxDuration = const Duration(minutes: 5),
  }) {
    _completion = execution.done.then(
      (_) {
        complete = true;
      },
      onError: (Object _) {
        failure ??= const ProviderException('视频准备中断，正在切换兼容方式');
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
  bool _closed = false, _checking = false;
  bool complete = false;
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
      (_) => unawaited(_checkBudget()),
    );
    while (!_closed) {
      await _checkBudget();
      if (failure != null) throw failure!;
      if (await _ready()) {
        if (_closed) throw const ProviderException('已取消准备');
        if (failure != null) throw failure!;
        return url;
      }
      if (complete) throw const ProviderException('视频未生成可播放分片');
      if (_clock.elapsed >= startupTimeout) {
        throw const ProviderException('提前开播准备超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const ProviderException('已取消准备');
  }

  Future<bool> _ready() async {
    final playlist = File('${directory.path}/index.m3u8');
    if (!await playlist.exists()) return false;
    if (await playlist.length() > 256 * 1024) {
      throw const ProviderException('播放列表过大');
    }
    final text = await playlist.readAsString();
    if (!text.startsWith('#EXTM3U') || !text.contains('URI="init.mp4"')) {
      return false;
    }
    // A finished writer without ENDLIST did not publish a valid final playlist.
    if (complete &&
        !text.split('\n').any((line) => line.trim() == '#EXT-X-ENDLIST')) {
      return false;
    }
    final fragments = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => _segment.hasMatch(line));
    if (fragments.isEmpty) return false;
    for (final name in ['init.mp4', fragments.first]) {
      final file = File('${directory.path}/$name');
      if (!await file.exists() || await file.length() == 0) return false;
    }
    return true;
  }

  Future<void> _checkBudget() async {
    if (_closed || _checking || failure != null) return;
    _checking = true;
    try {
      var bytes = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) bytes += await entity.length();
      }
      if (bytes > maxBytes || (!complete && _clock.elapsed > maxDuration)) {
        failure = const ProviderException('视频准备超过资源限制，正在切换兼容方式');
        _monitor?.cancel();
        await execution.cancel();
      }
      if (complete) _monitor?.cancel();
    } catch (_) {
      // Timer callbacks must never leak an asynchronous error. If cancelling
      // failed, close() will retry/propagate it so the writer's files remain.
      if (!_closed) {
        failure ??= const ProviderException('无法读取或停止临时视频');
        _monitor?.cancel();
      }
    } finally {
      _checking = false;
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
    if (!complete) await execution.cancel();
    await _completion;
  }
}
