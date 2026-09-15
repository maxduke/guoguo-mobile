import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Pages implements ProviderClient {
  final requested = <int>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final page = args['page'] as int? ?? 1;
    requested.add(page);
    return {
      'items': [
        for (final id in page == 1 ? ['1', '2'] : ['2', '3'])
          Drama(id: id, source: DramaSource.hongguo, title: id).toJson(),
      ],
      'hasMore': page < 3,
      'warning': page == 2 ? '部分分类暂时不可用' : '',
    };
  }
}

class _Cover implements ProviderClient {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    expect(method, 'cover');
    expect(args['url'], 'https://pic.zdmhyg.cn/fixture');
    return {
      'data': base64Encode([255, 216, 255, 0]),
      'contentType': 'image/jpeg',
    };
  }
}

void main() {
  test(
    'pagination deduplicates, retains partial errors and resumes after restart',
    () async {
      final storage = MemoryStorage();
      final provider = _Pages();
      final store = AppStore(storage: storage, provider: provider);
      await store.refresh();
      await Future.wait([store.loadMore(), store.loadMore()]);
      expect(provider.requested, [1, 2]);
      expect(store.library.length, 3);
      expect(store.sourceErrors[DramaSource.hongguo], contains('部分分类'));
      final restored = AppStore(storage: storage, provider: provider);
      await restored.load();
      await restored.loadMore();
      await restored.loadMore();
      expect(provider.requested, [1, 2, 3]);
      expect(restored.hasMore[DramaSource.hongguo], isFalse);
      expect(restored.library.length, 3);
      store.dispose();
      restored.dispose();
    },
  );
  test(
    'cover cache receives decoded bytes with a reusable cache lifetime',
    () async {
      final response = await ProviderCoverService(
        _Cover(),
      ).get('https://pic.zdmhyg.cn/fixture');
      expect(await response.content.expand((bytes) => bytes).toList(), [
        255,
        216,
        255,
        0,
      ]);
      expect(response.statusCode, 200);
      expect(response.fileExtension, '.jpg');
      expect(
        response.validTill.isAfter(DateTime.now().add(const Duration(days: 6))),
        isTrue,
      );
    },
  );
}
