import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import '../domain/discovery.dart';
import '../domain/catalog_response.dart';
import '../domain/download_plan.dart';

abstract interface class ProviderClient {
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]);
}

// Optional observation at the same decoding boundary used by typed operations.
// Ordinary clients and native request arguments keep their existing contract.
abstract interface class DecodingProviderClient implements ProviderClient {
  Future<T> callDecoded<T>(
    String method,
    Map<String, dynamic> arguments,
    T Function(Map<String, dynamic>) decode, {
    DramaSource? source,
  });
}

class NativeProviderClient implements ProviderClient {
  // Covers and app operations use the same native core and readiness gate.
  static final shared = NativeProviderClient();
  static const _channel = MethodChannel('guoguo/core');
  Future<void>? _initialization;
  bool _initialized = false, _initializing = false;
  bool _sourceDiagnostics = false;
  bool _catalogPrefetch = false;
  int _traceSerial = 0;

  Future<void> get ready =>
      _initialization ??
      Future.error(const ProviderException('站源组件尚未就绪，请稍候或重试站源连接'));

  Future<void> initialize(String directory) {
    if (_initialized || _initializing) return _initialization!;
    _initializing = true;
    final future = Future<void>.microtask(() => _initialize(directory));
    _initialization = future;
    // Keep a failed attempt observable to callers until an explicit retry.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  Future<void> _initialize(String directory) async {
    try {
      await _channel.invokeMethod<void>('initialize', {'directory': directory});
      try {
        final info = await _call('coreInfo');
        if (info['protocol'] != 3) {
          throw const ProviderException('站源组件版本不匹配，请安装最新完整版本');
        }
        _sourceDiagnostics = info['sourceDiagnostics'] == 1;
        _catalogPrefetch = info['catalogPrefetch'] == 1;
      } catch (_) {
        throw const ProviderException('站源组件版本不匹配，请安装最新完整版本');
      }
      _initialized = true;
    } on MissingPluginException {
      throw const ProviderException('站源组件未安装，请安装包含站源核心的完整版本');
    } on PlatformException {
      throw const ProviderException('站源连接暂未就绪，请重试');
    } finally {
      _initializing = false;
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    await ready;
    return _call(method, arguments);
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'catalog' &&
        arguments['background'] == true &&
        !_catalogPrefetch) {
      throw const ProviderException('当前站源组件不支持提前加载，请安装最新完整版本');
    }
    final traceId =
        _sourceDiagnostics &&
            const {
              'catalog',
              'categories',
              'ranking',
              'boards',
              'recommendations',
              'search',
              'suggestions',
              'detail',
              'chapters',
            }.contains(method)
        ? 'native-${DateTime.now().microsecondsSinceEpoch}-${++_traceSerial}'
        : null;
    try {
      final raw = await _channel.invokeMethod<String>(
        'call',
        jsonEncode({'method': method, ...arguments, 'traceId': ?traceId}),
      );
      if (raw == null) throw const FormatException('站源未返回数据');
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on MissingPluginException {
      throw const ProviderException('站源组件未安装，请安装包含站源核心的完整版本');
    } on PlatformException catch (error) {
      Map? diagnostic;
      if (traceId != null) {
        try {
          diagnostic =
              (await _call('requestDiagnostic', {
                    'traceId': traceId,
                  }))['diagnostic']
                  as Map?;
        } catch (_) {
          // A missing diagnostic cannot replace the original failure.
        }
      }
      throw ProviderException(
        error.message ?? '站源暂时不可用，请稍后重试',
        userMessage: '站源暂时不可用，请稍后重试',
        failureHint: _failureHint(error.message),
        diagnostic: diagnostic,
      );
    }
  }

  static String? _failureHint(String? message) {
    final text = message?.toLowerCase() ?? '';
    if (text.contains('已暂停该域名请求')) {
      return '站点暂时限制请求，请稍后重试';
    }
    if (text.contains('浏览器验证') || text.contains('cloudflare')) {
      return '站点要求浏览器验证，暂时无法加载';
    }
    if (text.contains('域名解析失败') ||
        text.contains('dns') ||
        text.contains('no such host') ||
        text.contains('内网或保留网络') ||
        text.contains('没有可用的公网地址')) {
      return '站点域名解析异常，可尝试切换网络后重试';
    }
    if (text.contains('deadline exceeded') || text.contains('timeout')) {
      return '站点连接超时，请稍后重试';
    }
    return null;
  }
}

class ProviderException implements Exception {
  const ProviderException(
    this.message, {
    String? userMessage,
    this.failureHint,
    this.diagnostic,
  }) : _userMessage = userMessage;
  final String message;
  // Fixed display text, never the native error's URL, credentials or IP address.
  final String? failureHint;
  final Map? diagnostic;
  final String? _userMessage;
  String get userMessage => _userMessage ?? message;
  @override
  String toString() => message;
}

String? providerFailureHint(Object error) {
  if (error is FormatException || error is TypeError) {
    return '站源返回内容无法处理，请稍后重试或切换站源';
  }
  if (error is! ProviderException) return null;
  // Prefer the core's fixed failure code. Older cores retain their safe hint.
  return switch (error.diagnostic?['failure']) {
    'dns' => '站点域名解析异常，可尝试切换网络后重试',
    'timeout' => '站点连接超时，请稍后重试',
    'verification' => '站点要求浏览器验证，暂时无法加载',
    'backoff' => '站点暂时限制请求，请稍后重试',
    'connection' => '站点连接中断，可尝试切换网络后重试',
    'http' => '站点返回错误状态，请稍后重试或切换站源',
    _ => error.failureHint,
  };
}

String providerFailureMessage(Object error, String fallback) {
  final hint = providerFailureHint(error);
  return hint == null ? fallback : '$fallback\n$hint';
}

extension ProviderOperations on ProviderClient {
  Future<T> _read<T>(
    String method,
    Map<String, dynamic> arguments,
    T Function(Map<String, dynamic>) decode, {
    DramaSource? source,
  }) async {
    final client = this;
    if (client is DecodingProviderClient) {
      return client.callDecoded(method, arguments, decode, source: source);
    }
    return decode(await call(method, arguments));
  }

  Future<List<SourceCategory>> categories(DramaSource source) => _read(
    'categories',
    {'source': source.name},
    (result) => List.unmodifiable(
      (result['items'] as List).map(
        (raw) => SourceCategory.fromJson(raw as Map),
      ),
    ),
  );

  Future<CatalogPage> catalogPage(
    DramaSource source, {
    String? category,
    int? page,
    String? requestId,
    bool background = false,
  }) => _read('catalog', {
    'source': source.name,
    'category': ?category,
    'page': ?page,
    'requestId': ?requestId,
    if (background) 'background': true,
  }, (result) => CatalogPage.fromJson(result, source));

  Future<void> cancelCatalog(
    DramaSource source,
    String requestId, {
    required int page,
    required String category,
  }) async {
    await call('cancelCatalog', {
      'source': source.name,
      'requestId': requestId,
      'page': page,
      'category': category,
    });
  }

  Future<CatalogSearchResult> searchPage(
    DramaSource source,
    String query, {
    int page = 1,
    required String requestId,
    String? continuation,
  }) => _read('search', {
    'source': source.name,
    'query': query,
    'page': page,
    'requestId': requestId,
    'continuation': ?continuation,
  }, (result) => CatalogSearchResult.fromJson(result, source));

  Future<CatalogSearchResult?> searchProgress(
    DramaSource source,
    String query, {
    int page = 1,
    required String requestId,
  }) async {
    final result = await call('searchProgress', {
      'source': source.name,
      'query': query,
      'page': page,
      'requestId': requestId,
    });
    if (result['source'] != source.name || result['query'] != query) {
      return null;
    }
    return CatalogSearchResult.fromJson(result, source);
  }

  Future<void> cancelSearch(
    DramaSource source,
    String query,
    String requestId,
  ) async {
    await call('cancelSearch', {
      'source': source.name,
      'query': query,
      'requestId': requestId,
    });
  }

  Future<List<String>> suggestions(String query) => _read(
    'suggestions',
    {'source': DramaSource.hongguo.name, 'query': query},
    (result) => List.unmodifiable(
      (result['items'] as List? ?? []).map(
        (raw) => (raw as Map)['name'] as String,
      ),
    ),
  );

  Future<Drama> dramaDetail(Drama drama) =>
      _read('detail', {'id': drama.id}, (result) {
        final patch = Drama.fromJson(
          Map<String, dynamic>.from(result['item'] as Map),
        );
        if (patch.key != drama.key) throw const FormatException('剧集资料不匹配');
        return patch;
      }, source: drama.source);

  Future<DownloadPlan> downloadPlan(Drama drama, Episode episode) async {
    final plan = DownloadPlan.fromJson(
      await call('downloadPlan', {'id': drama.id, 'chapter': episode.raw}),
    );
    if (plan.assets.isEmpty) throw const ProviderException('未找到可下载资源');
    return plan;
  }

  Future<List<DiscoveryBoard>> discoveryBoards(DramaSource source) => _read(
    'boards',
    {'source': source.name},
    (result) => List.unmodifiable(
      (result['items'] as List).map(
        (raw) => DiscoveryBoard.fromJson(raw as Map, source),
      ),
    ),
  );

  Future<DiscoveryColumnResult> discoveryColumn(
    DramaSource source,
    String board, {
    int page = 1,
    bool refresh = false,
  }) => _read(
    'ranking',
    {'board': board, 'page': page, 'refresh': refresh},
    (result) => DiscoveryColumnResult.fromJson(
      result,
      source,
      board: board,
      page: page,
    ),
    source: source,
  );

  Future<RecommendationBatch> recommendations(
    RecommendationGenre genre, {
    int offset = 0,
    String sessionId = '',
    List<String> seen = const [],
  }) => _read('recommendations', {
    'recommendation': {
      'genre': genre.id,
      'offset': offset,
      'sessionId': sessionId,
      'seen': seen,
    },
  }, RecommendationBatch.fromJson);

  Future<List<Episode>> chapters(Drama drama) =>
      _read('chapters', {'id': drama.id}, (result) {
        final rows = result['chapters'] as List? ?? [];
        if (rows.isEmpty) {
          throw const ProviderException(
            '暂未找到可播放分集',
            failureHint: '站点暂未提供可播放分集，可稍后重试或切换站源',
          );
        }
        return List.unmodifiable([
          for (var i = 0; i < rows.length; i++)
            Episode.fromJson(Map<String, dynamic>.from(rows[i] as Map), i),
        ]);
      }, source: drama.source);

  Future<ResolvedMedia> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int metadataAhead = 0,
  }) async => ResolvedMedia.fromJson(
    await call('resolve', {
      'id': drama.id,
      'chapter': episode.raw,
      'quality': quality,
      if (metadataAhead > 0) 'metadataAhead': metadataAhead,
    }),
  );
  Future<ResolvedMedia> fallback(ResolvedMedia media) async =>
      ResolvedMedia.fromJson(await call('fallback', {'id': media.session}));

  Future<ResolvedMedia> prefetch(ResolvedMedia media) async =>
      ResolvedMedia.fromJson(await call('prefetch', {'id': media.session}));

  Future<void> cancelPrefetch(ResolvedMedia? media) async {
    if (media == null || media.session.isEmpty) return;
    await call('cancelPrefetch', {'id': media.session});
  }

  Future<void> release(ResolvedMedia? media) async {
    if (media == null || media.session.isEmpty) return;
    await call('release', {'id': media.session});
  }
}
