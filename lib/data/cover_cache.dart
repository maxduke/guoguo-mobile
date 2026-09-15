import 'dart:convert';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import '../platform/provider_client.dart';

/// Cache decoded image bytes, not upstream encrypted responses.
final coverCache = CacheManager(
  Config(
    'guoguo-decoded-covers-v1',
    maxNrOfCacheObjects: 600,
    fileService: ProviderCoverService(NativeProviderClient()),
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
    final result = await provider.call('cover', {'url': url});
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
