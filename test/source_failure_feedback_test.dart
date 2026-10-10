import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/ui/catalog_search_controller.dart';

class _Unavailable implements ProviderClient {
  _Unavailable(this.error);
  final Object error;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async => throw error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry in const {
    'dns': '站点域名解析异常，可尝试切换网络后重试',
    'timeout': '站点连接超时，请稍后重试',
    'verification': '站点要求浏览器验证，暂时无法加载',
    'backoff': '站点暂时限制请求，请稍后重试',
    'connection': '站点连接中断，可尝试切换网络后重试',
    'http': '站点返回错误状态，请稍后重试或切换站源',
  }.entries) {
    for (final source in [DramaSource.hongguo, DramaSource.huangju]) {
      test(
        '${source.name} uses the same safe ${entry.key} guidance across catalog operations',
        () async {
          final error = ProviderException(
            'private https://example.test/?grant=secret',
            diagnostic: {'failure': entry.key},
          );
          final store = AppStore(
            storage: MemoryStorage(),
            provider: _Unavailable(error),
          );
          addTearDown(store.dispose);
          await store.catalog.selectSource(source);
          await store.catalog.loadCategories();
          await store.catalog.refresh();
          final drama = Drama(
            id: '${source.name}:secret',
            source: source,
            title: 'secret',
          );
          await store.catalog.refreshDetail(drama, force: true);
          await expectLater(
            store.catalog.episodes(drama, refresh: true),
            throwsA(same(error)),
          );
          final search = CatalogSearchController(store.catalog);
          addTearDown(search.dispose);
          await search.submit('secret');
          final notices = [
            if (source.remoteCategories) store.catalog.categoryErrors[source],
            store.catalog.libraryError,
            store.catalog.detailErrors[drama.key],
            store.catalog.episodeErrors[drama.key],
            search.error,
          ];
          for (final notice in notices) {
            expect(notice, contains(entry.value));
            expect(notice, isNot(contains('secret')));
            expect(notice, isNot(contains('example.test')));
          }
        },
      );
    }
  }

  test(
    'older clients keep explicit safe hints and unknown failures keep only the page guidance',
    () {
      const old = ProviderException('private', failureHint: '站点连接超时，请稍后重试');
      expect(providerFailureMessage(old, '加载未完成'), '加载未完成\n站点连接超时，请稍后重试');
      const unknown = ProviderException(
        'private',
        diagnostic: {'failure': 'private'},
      );
      expect(providerFailureMessage(unknown, '加载未完成'), '加载未完成');
      expect(providerFailureMessage(StateError('private'), '加载未完成'), '加载未完成');
      expect(
        providerFailureMessage(const FormatException('private'), '加载未完成'),
        '加载未完成\n站源返回内容无法处理，请稍后重试或切换站源',
      );
    },
  );
}
