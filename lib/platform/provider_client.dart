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

class NativeProviderClient implements ProviderClient {
  // Covers and app operations use the same native core and readiness gate.
  static final shared = NativeProviderClient();
  static const _channel = MethodChannel('guoguo/core');
  Future<void>? _initialization;
  bool _initialized = false, _initializing = false;

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
    try {
      final raw = await _channel.invokeMethod<String>(
        'call',
        jsonEncode({'method': method, ...arguments}),
      );
      if (raw == null) throw const FormatException('站源未返回数据');
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on MissingPluginException {
      throw const ProviderException('站源组件未安装，请安装包含站源核心的完整版本');
    } on PlatformException catch (error) {
      throw ProviderException(
        error.message ?? '站源暂时不可用，请稍后重试',
        userMessage: '站源暂时不可用，请稍后重试',
      );
    }
  }
}

class ProviderException implements Exception {
  const ProviderException(this.message, {String? userMessage})
    : _userMessage = userMessage;
  final String message;
  final String? _userMessage;
  String get userMessage => _userMessage ?? message;
  @override
  String toString() => message;
}

extension ProviderOperations on ProviderClient {
  Future<List<SourceCategory>> categories(DramaSource source) async {
    final result = await call('categories', {'source': source.name});
    return List.unmodifiable(
      (result['items'] as List).map(
        (raw) => SourceCategory.fromJson(raw as Map),
      ),
    );
  }

  Future<CatalogPage> catalogPage(
    DramaSource source, {
    String? category,
    int? page,
  }) async => CatalogPage.fromJson(
    await call('catalog', {
      'source': source.name,
      'category': ?category,
      'page': ?page,
    }),
    source,
  );

  Future<CatalogSearchResult> searchPage(
    DramaSource source,
    String query, {
    int page = 1,
    required String requestId,
  }) async => CatalogSearchResult.fromJson(
    await call('search', {
      'source': source.name,
      'query': query,
      'page': page,
      'requestId': requestId,
    }),
    source,
  );

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

  Future<List<String>> suggestions(String query) async {
    final result = await call('suggestions', {
      'source': DramaSource.hongguo.name,
      'query': query,
    });
    return List.unmodifiable(
      (result['items'] as List? ?? []).map(
        (raw) => (raw as Map)['name'] as String,
      ),
    );
  }

  Future<Drama> dramaDetail(Drama drama) async {
    final result = await call('detail', {'id': drama.id});
    final patch = Drama.fromJson(
      Map<String, dynamic>.from(result['item'] as Map),
    );
    if (patch.key != drama.key) throw const FormatException('剧集资料不匹配');
    return patch;
  }

  Future<DownloadPlan> downloadPlan(Drama drama, Episode episode) async {
    final plan = DownloadPlan.fromJson(
      await call('downloadPlan', {'id': drama.id, 'chapter': episode.raw}),
    );
    if (plan.assets.isEmpty) throw const ProviderException('未找到可下载资源');
    return plan;
  }

  Future<List<DiscoveryBoard>> discoveryBoards(DramaSource source) async {
    final result = await call('boards', {'source': source.name});
    return List.unmodifiable(
      (result['items'] as List).map(
        (raw) => DiscoveryBoard.fromJson(raw as Map, source),
      ),
    );
  }

  Future<DiscoveryColumnResult> discoveryColumn(
    DramaSource source,
    String board, {
    int page = 1,
    bool refresh = false,
  }) async => DiscoveryColumnResult.fromJson(
    await call('ranking', {'board': board, 'page': page, 'refresh': refresh}),
    source,
    board: board,
    page: page,
  );

  Future<RecommendationBatch> recommendations(
    RecommendationGenre genre, {
    int offset = 0,
    String sessionId = '',
    List<String> seen = const [],
  }) async => RecommendationBatch.fromJson(
    await call('recommendations', {
      'recommendation': {
        'genre': genre.id,
        'offset': offset,
        'sessionId': sessionId,
        'seen': seen,
      },
    }),
  );

  Future<List<Episode>> chapters(Drama drama) async {
    final result = await call('chapters', {'id': drama.id});
    final rows = result['chapters'] as List? ?? [];
    return List.unmodifiable([
      for (var i = 0; i < rows.length; i++)
        Episode.fromJson(Map<String, dynamic>.from(rows[i] as Map), i),
    ]);
  }

  Future<ResolvedMedia> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => ResolvedMedia.fromJson(
    await call('resolve', {
      'id': drama.id,
      'chapter': episode.raw,
      'quality': quality,
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
