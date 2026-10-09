import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

const _drama = Drama(id: 'd', source: DramaSource.hongguo, title: '测试短剧');

class _Provider implements ProviderClient {
  final responses = <String, Map<String, dynamic>>{};
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    requests.add((method, arguments));
    return responses[method]!;
  }
}

void _expectRequest(
  (String, Map<String, dynamic>) actual,
  (String, Map<String, dynamic>) expected,
) {
  expect(actual.$1, expected.$1);
  expect(actual.$2, expected.$2);
}

void main() {
  test(
    'catalog requests preserve optional page and the empty all-category ID',
    () async {
      final provider = _Provider()
        ..responses['catalog'] = {
          'items': [_drama.toJson()],
        }
        ..responses['categories'] = {
          'items': [
            {'id': '', 'name': '全部'},
          ],
        };
      final page = await provider.catalogPage(DramaSource.hongguo);
      _expectRequest(provider.requests.last, (
        'catalog',
        {'source': 'hongguo'},
      ));
      expect(page.items.single.key, _drama.key);
      expect(() => page.items.clear(), throwsUnsupportedError);
      provider.responses['catalog'] = {'items': []};
      await provider.catalogPage(DramaSource.huangju, category: '', page: 1);
      _expectRequest(provider.requests.last, (
        'catalog',
        {'source': 'huangju', 'category': '', 'page': 1},
      ));
      final categories = await provider.categories(DramaSource.huangju);
      expect(categories.single.id, isEmpty);
      expect(() => categories.clear(), throwsUnsupportedError);
    },
  );

  test(
    'search progress ignores stale identity before parsing its payload',
    () async {
      final provider = _Provider()
        ..responses['searchProgress'] = {
          'source': 'huangguo',
          'query': 'other',
          'items': 'invalid',
        }
        ..responses['search'] = {
          'items': [_drama.toJson()],
          'hasMore': true,
          'total': 7,
        }
        ..responses['cancelSearch'] = {};
      expect(
        await provider.searchProgress(
          DramaSource.hongguo,
          'query',
          page: 2,
          requestId: 'owner',
        ),
        isNull,
      );
      provider.responses['searchProgress'] = {
        'source': 'hongguo',
        'query': 'other',
        'items': 'invalid',
      };
      expect(
        await provider.searchProgress(
          DramaSource.hongguo,
          'query',
          requestId: 'owner',
        ),
        isNull,
      );
      provider.responses['searchProgress'] = {
        'source': 'hongguo',
        'query': 'query',
        'items': [_drama.toJson()],
      };
      expect(
        (await provider.searchProgress(
          DramaSource.hongguo,
          'query',
          requestId: 'owner',
        ))!.items.single.key,
        _drama.key,
      );
      final result = await provider.searchPage(
        DramaSource.hongguo,
        'query',
        page: 2,
        requestId: 'owner',
      );
      expect(result.hasMore, isTrue);
      expect(result.total, 7);
      _expectRequest(provider.requests.last, (
        'search',
        {
          'source': 'hongguo',
          'query': 'query',
          'page': 2,
          'requestId': 'owner',
        },
      ));
      await provider.cancelSearch(DramaSource.hongguo, 'query', 'owner');
      _expectRequest(provider.requests.last, (
        'cancelSearch',
        {'source': 'hongguo', 'query': 'query', 'requestId': 'owner'},
      ));
    },
  );

  for (final invalid in <String, Map<String, dynamic>>{
    'foreign source': {
      'items': [
        {..._drama.toJson(), 'source': 'huangguo'},
      ],
    },
    'unknown source': {
      'items': [
        {..._drama.toJson(), 'source': 'unknown'},
      ],
    },
    'bad tags': {
      'items': [
        {
          ..._drama.toJson(),
          'tags': ['valid', 1],
        },
      ],
    },
    'bad cursor': {
      'items': [_drama.toJson()],
      'hasMore': 'true',
    },
    'bad limitation': {
      'items': [_drama.toJson()],
      'limited': 1,
    },
    'bad warning': {
      'items': [_drama.toJson()],
      'warning': 1,
    },
    'bad total': {
      'items': [_drama.toJson()],
      'total': '7',
    },
  }.entries) {
    test(
      '${invalid.key} cannot enter catalog, recent searches or search cache',
      () async {
        final provider = _Provider()
          ..responses['search'] = invalid.value
          ..responses['cancelSearch'] = {};
        final app = AppStore(storage: MemoryStorage(), provider: provider);
        addTearDown(app.dispose);
        await expectLater(
          app.catalog.searchCatalog(DramaSource.hongguo, 'query'),
          throwsA(anything),
        );
        expect(app.catalog.catalogs, isEmpty);
        expect(app.catalog.recentSearches, isEmpty);
        expect(
          app.catalog.searchCache.read('hongguo|query|1', DateTime.now()),
          isNull,
        );
      },
    );
  }

  test(
    'chapter numbering and all provider fields survive resolve and download requests',
    () async {
      final raw = <String, dynamic>{
        'id': 'episode',
        'title': '真实第八集',
        'currentEpisode': '8',
        'vip': true,
        'unknownProviderField': 'keep',
        'credentials': {'grant': 'fixture', 'expiry': 123},
      };
      final media = <String, dynamic>{
        'url': 'http://127.0.0.1/local',
        'remoteUrl': 'https://media.test/file?grant=fixture',
        'headers': {
          'Referer': 'https://media.test/',
          'Origin': 'https://media.test',
          'User-Agent': 'fixture',
        },
        'qualities': [720, 1080],
        'quality': 720,
        'session': 'session',
        'contentKey': 'key',
        'castDirect': true,
      };
      final planJson = <String, dynamic>{
        'input': 'index.m3u8',
        'process': true,
        'contentKey': 'key',
        'refreshOnResume': true,
        'headers': media['headers'],
        'inline': [
          {'name': 'index.m3u8', 'body': base64Encode(utf8.encode('playlist'))},
        ],
        'assets': [
          {
            'name': '1.bin',
            'url': 'https://media.test/1?grant=fixture',
            'identity': 'https://media.test/1',
          },
        ],
      };
      final provider = _Provider()
        ..responses['chapters'] = {
          'chapters': [raw],
        }
        ..responses['resolve'] = media
        ..responses['downloadPlan'] = planJson;
      final episodes = await provider.chapters(_drama);
      final episode = episodes.single;
      expect(episode.number, 8);
      expect(episode.vip, isTrue);
      expect(episode.raw, raw);
      expect(() => episodes.clear(), throwsUnsupportedError);
      expect(() => episode.raw['id'] = 'other', throwsUnsupportedError);
      raw['id'] = 'mutated';
      expect(episode.id, 'episode');
      expect(episode.raw['id'], 'episode');
      final resolved = await provider.resolve(_drama, episode, quality: 720);
      _expectRequest(provider.requests.last, (
        'resolve',
        {'id': _drama.id, 'chapter': episode.raw, 'quality': 720},
      ));
      expect(resolved.headers, media['headers']);
      expect(() => resolved.headers.clear(), throwsUnsupportedError);
      expect(() => resolved.qualities.clear(), throwsUnsupportedError);
      (media['qualities'] as List).clear();
      expect(resolved.qualities, [720, 1080]);
      final plan = await provider.downloadPlan(_drama, episode);
      _expectRequest(provider.requests.last, (
        'downloadPlan',
        {'id': _drama.id, 'chapter': episode.raw},
      ));
      expect(plan.assets.single.identity, 'https://media.test/1');
      expect(plan.assets.single.url, 'https://media.test/1?grant=fixture');
      expect(plan.headers, media['headers']);
      expect(plan.refreshOnResume, isTrue);
      expect(utf8.decode(plan.inline.single.bytes), 'playlist');
      expect(() => plan.inline.single.bytes[0] = 0, throwsUnsupportedError);
      expect(() => plan.assets.clear(), throwsUnsupportedError);
      expect(() => plan.headers.clear(), throwsUnsupportedError);
    },
  );

  test(
    'invalid qualities fail at parsing, before a media session is installed',
    () async {
      final provider = _Provider()
        ..responses['resolve'] = {
          'url': 'http://127.0.0.1/local',
          'remoteUrl': 'https://media.test/file',
          'qualities': [720, 'invalid'],
        };
      await expectLater(
        provider.resolve(_drama, Episode.fromJson({'id': 'e'}, 0)),
        throwsA(isA<TypeError>()),
      );
    },
  );

  test('detail response must match the requested drama and source', () async {
    final provider = _Provider()
      ..responses['detail'] = {
        'item': {..._drama.toJson(), 'id': 'other'},
      };
    await expectLater(provider.dramaDetail(_drama), throwsFormatException);
    provider.responses['detail'] = {
      'item': {..._drama.toJson(), 'source': 'huangguo'},
    };
    await expectLater(provider.dramaDetail(_drama), throwsFormatException);
  });
}
