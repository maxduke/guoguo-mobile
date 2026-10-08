import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Pages implements ProviderClient {
  _Pages([this.source = DramaSource.hongguo]);
  final DramaSource source;
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
          Drama(id: id, source: source, title: id).toJson(),
      ],
      'hasMore': page < 3,
      'warning': page == 2 ? '部分分类暂时不可用' : '',
    };
  }
}

class _Cover implements ProviderClient {
  _Cover({this.id, this.cover = ''});
  final String? id;
  final String cover;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    expect(method, 'cover');
    if (id != null) {
      expect(args, {'id': id, 'url': cover});
    } else {
      expect(args['url'], 'https://pic.zdmhyg.cn/fixture');
    }
    return {
      'data': base64Encode([255, 216, 255, 0]),
      'contentType': 'image/jpeg',
    };
  }
}

void main() {
  test('legacy cover paths and bare IDs survive the Flutter bridge', () async {
    for (final path in [
      'cf230705/image/original.jpg',
      '/cf230705/image/comic.jpg',
      'k12p/c92a/remix.jpg?key=a%2Bb&expires=123',
      'k12p/c92a/drama.jpg',
      'upload_01/upload/cover.jpg',
      '',
    ]) {
      final drama = Drama(
        id: '12345',
        source: DramaSource.huangguo,
        title: 'fixture',
        cover: path,
      );
      final response = await ProviderCoverService(
        _Cover(id: drama.id, cover: path),
      ).get(coverRequest(drama));
      expect(response.statusCode, 200);
      expect(response.fileExtension, '.jpg');
    }
  });
  test(
    'saved records without a cover request artwork by provider identity',
    () async {
      for (final source in [DramaSource.huangguo, DramaSource.huangdou]) {
        final id = source == DramaSource.huangguo
            ? 'huangguoai:target'
            : 'huangdou:target';
        final drama = Drama(id: id, source: source, title: 'fixture');
        final response = await ProviderCoverService(
          _Cover(id: id),
        ).get(coverRequest(drama));
        expect(response.statusCode, 200);
      }
    },
  );
  for (final source in [DramaSource.hongguo, DramaSource.huangguo]) {
    test(
      '${source.name} pagination deduplicates, retains warnings and resumes',
      () async {
        final storage = MemoryStorage();
        final provider = _Pages(source);
        final store = AppStore(storage: storage, provider: provider);
        await store.catalog.selectSource(source);
        await store.catalog.refresh();
        await Future.wait([store.catalog.loadMore(), store.catalog.loadMore()]);
        expect(provider.requested, [1, 2]);
        expect(store.catalog.library.length, 3);
        expect(store.catalog.sourceErrors[source], contains('部分分类'));
        final restored = AppStore(storage: storage, provider: provider);
        await restored.load();
        await restored.catalog.loadMore();
        await restored.catalog.loadMore();
        expect(provider.requested, [1, 2, 3]);
        expect(restored.catalog.hasMore[source], isFalse);
        expect(restored.catalog.library.length, 3);
        await restored.catalog.refresh();
        expect(provider.requested, [1, 2, 3, 1]);
        expect(restored.catalog.library.length, 2);
        expect(restored.catalog.catalogs[source]!.length, 3);
        store.dispose();
        restored.dispose();
      },
    );
  }
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
