import 'dart:convert';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import '../platform/provider_client.dart';
import '../domain/models.dart';

String coverRequest(Drama drama) => Uri(
  scheme: 'guoguo-cover',
  host: drama.source.name,
  queryParameters: {'id': drama.id, 'url': drama.cover},
).toString();

/// Cache decoded image bytes, not upstream encrypted responses.
const coverCacheKey = 'guoguo-decoded-covers-v1';
final coverCache = CacheManager(
  Config(
    coverCacheKey,
    maxNrOfCacheObjects: 600,
    fileService: ProviderCoverService(NativeProviderClient.shared),
  ),
);

class ProviderCoverService extends FileService {
  ProviderCoverService(this.provider) {
    concurrentFetches = 3;
  }
  final ProviderClient provider;
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url);
    final result = await provider.call(
      'cover',
      uri.scheme == 'guoguo-cover'
          ? {
              'id': uri.queryParameters['id'],
              'url': uri.queryParameters['url'] ?? '',
            }
          : {'url': url},
    );
    final bytes = base64Decode(result['data'] as String);
    return HttpGetResponse(
      http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
        headers: {
          'content-type': result['contentType'] as String,
          'cache-control': 'max-age=604800',
        },
      ),
    );
  }
}
