import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/source_diagnostics.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/discovery.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/source_diagnostic.dart';
import 'package:guoguo_mobile/platform/observed_provider_client.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Provider implements ProviderClient {
  Map<String, dynamic> response = {};
  Object? error;
  Map<String, dynamic>? arguments;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    arguments = args;
    if (error != null) throw error!;
    return response;
  }
}

Map<String, dynamic> _sample({
  String method = 'catalog',
  String result = 'success',
}) => SourceDiagnostic(
  source: DramaSource.huangguo,
  method: method,
  at: DateTime.utc(2026, 10, 10),
  elapsedMs: 25,
  networkAttempts: 2,
  result: result,
  stage: 'complete',
).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SourceDiagnostics diagnostics;
  setUp(
    () =>
        diagnostics = SourceDiagnostics(now: () => DateTime.utc(2026, 10, 10)),
  );
  tearDown(() => diagnostics.dispose());
  test(
    'observed metadata records actual attempts without changing request arguments',
    () async {
      final provider = _Provider()
        ..response = {'_diagnostic': _sample(), 'items': []};
      final observed = ObservedProviderClient(provider, diagnostics);
      final args = {'source': 'huangguo', 'query': 'secret'};
      await observed.call('catalog', args);
      expect(identical(provider.arguments, args), true);
      expect(diagnostics.samples.single.networkAttempts, 2);
      expect(
        jsonEncode(diagnostics.samples.single.toJson()).contains('secret'),
        false,
      );
    },
  );
  test(
    'missing or mismatched metadata stays unknown instead of claiming cache hits',
    () async {
      final provider = _Provider()
        ..response = {'_diagnostic': _sample(method: 'search')};
      await ObservedProviderClient(
        provider,
        diagnostics,
      ).call('catalog', {'source': 'huangguo'});
      expect(diagnostics.samples.single.networkAttempts, isNull);
      expect(diagnostics.samples.single.cacheHits, 0);
      provider.error = const ProviderException('https://secret?token=secret');
      await expectLater(
        ObservedProviderClient(
          provider,
          diagnostics,
        ).call('catalog', {'source': 'huangguo'}),
        throwsA(isA<ProviderException>()),
      );
      expect(diagnostics.samples.first.result, 'failed');
      expect(
        jsonEncode(
          diagnostics.samples.map((s) => s.toJson()).toList(),
        ).contains('secret'),
        false,
      );
    },
  );

  test('legacy IDs retain validated native source metadata', () async {
    final provider = _Provider()
      ..response = {
        '_diagnostic': {..._sample(method: 'chapters'), 'source': 'huangdou'},
      };
    await ObservedProviderClient(
      provider,
      diagnostics,
    ).call('chapters', {'id': '12345'});
    expect(diagnostics.samples.single.source, DramaSource.huangdou);
    expect(diagnostics.samples.single.networkAttempts, 2);
  });
  test(
    'explicit cache hits and bounded retention are independent of provider calls',
    () {
      for (var index = 0; index < 70; index++) {
        diagnostics.cached(DramaSource.hongguo, 'search', page: index + 1);
      }
      expect(diagnostics.samples, hasLength(64));
      expect(diagnostics.samples.first.page, 70);
      expect(diagnostics.samples.last.page, 7);
      expect(diagnostics.samples.first.networkAttempts, 0);
      expect(diagnostics.samples.first.cacheHits, 1);
      diagnostics.clear();
      expect(diagnostics.samples, isEmpty);
    },
  );
  test('diagnostic enums and numbers cannot carry raw exception text', () {
    for (final invalid in [
      {..._sample(), 'failure': 'secret'},
      {..._sample(), 'method': 'secret'},
      {..._sample(), 'networkAttempts': -1},
      {..._sample(), 'source': 'secret'},
    ]) {
      expect(() => SourceDiagnostic.fromJson(invalid), throwsFormatException);
    }
  });
  test('unwatched media operations never record URLs', () async {
    await ObservedProviderClient(
      _Provider(),
      diagnostics,
    ).call('resolve', {'url': 'secret'});
    expect(diagnostics.samples, isEmpty);
  });

  test(
    'discovery cache reads record cache use without global store notifications',
    () {
      final store = AppStore(storage: MemoryStorage(), provider: _Provider());
      addTearDown(store.dispose);
      var notifications = 0;
      store.addListener(() => notifications++);
      store.catalog.discoveryCache.putRecommendations(
        RecommendationGenre.shortPlay,
        const [],
        DateTime.now(),
      );
      store.catalog.discoveryCache.recommendations(
        RecommendationGenre.shortPlay,
      );
      expect(store.sourceDiagnostics.samples.single.method, 'recommendations');
      expect(store.sourceDiagnostics.samples.single.cacheHits, 1);
      expect(store.sourceDiagnostics.samples.single.networkAttempts, 0);
      expect(notifications, 0);
    },
  );

  test(
    'native failure retrieves the matching trace while preserving the user error',
    () async {
      const channel = MethodChannel('guoguo/core');
      final requests = <Map<String, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'initialize') return null;
            final request =
                jsonDecode(call.arguments as String) as Map<String, dynamic>;
            requests.add(request);
            switch (request['method']) {
              case 'coreInfo':
                return jsonEncode({
                  'protocol': 3,
                  'sourceDiagnostics': 1,
                  'catalogPrefetch': 1,
                });
              case 'catalog':
                throw PlatformException(
                  code: 'core',
                  message: 'secret DNS lookup failed',
                );
              case 'requestDiagnostic':
                return jsonEncode({
                  'diagnostic': {
                    ..._sample(result: 'failed'),
                    'failure': 'dns',
                    'stage': 'dns',
                  },
                });
            }
            throw StateError('unexpected request');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final native = NativeProviderClient();
      await native.initialize('/fixture');
      await expectLater(
        ObservedProviderClient(
          native,
          diagnostics,
        ).call('catalog', {'source': 'huangguo'}),
        throwsA(isA<ProviderException>()),
      );
      expect(requests[1]['traceId'], requests[2]['traceId']);
      expect(diagnostics.samples.single.failure, 'dns');
      expect(diagnostics.samples.single.networkAttempts, 2);
    },
  );
}
