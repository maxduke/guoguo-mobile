import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('guoguo/core');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native failures separate diagnostic details from display messages',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return null;
        final method = (jsonDecode(call.arguments as String) as Map)['method'];
        if (method == 'coreInfo') return jsonEncode({'protocol': 3});
        throw PlatformException(
          code: 'provider',
          message: 'https://private.invalid?token=secret',
        );
      });
      final provider = NativeProviderClient();
      await provider.initialize('/providers');
      await expectLater(
        provider.call('catalog'),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.userMessage,
            'display message',
            '站源暂时不可用，请稍后重试',
          ),
        ),
      );
    },
  );

  test(
    'calls wait for initialization and protocol verification; concurrent initialization is shared',
    () async {
      final native = Completer<void>(), protocol = Completer<void>();
      final methods = <String>[];
      var initializations = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') {
          initializations++;
          await native.future;
          return null;
        }
        final method =
            (jsonDecode(call.arguments as String) as Map)['method'] as String;
        methods.add(method);
        if (method == 'coreInfo') {
          await protocol.future;
          return jsonEncode({'protocol': 3});
        }
        return jsonEncode({'items': []});
      });
      final provider = NativeProviderClient();
      final ready = provider.initialize('/providers');
      expect(provider.initialize('/providers'), same(ready));
      final catalog = provider.call('catalog');
      final cover = provider.call('cover');
      await Future<void>.delayed(Duration.zero);
      expect(initializations, 1);
      expect(methods, isEmpty);
      native.complete();
      await Future<void>.delayed(Duration.zero);
      expect(methods, ['coreInfo']);
      protocol.complete();
      await Future.wait([ready, catalog, cover]);
      expect(methods, ['coreInfo', 'catalog', 'cover']);
      await provider.initialize('/providers');
      expect(initializations, 1);
    },
  );

  test(
    'failed initialization blocks calls until an explicit retry and hides native details',
    () async {
      var fail = true, initializations = 0;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') {
          initializations++;
          if (fail) {
            throw PlatformException(
              code: 'provider',
              message: 'https://private.invalid?token=secret',
            );
          }
          return null;
        }
        final method =
            (jsonDecode(call.arguments as String) as Map)['method'] as String;
        methods.add(method);
        return jsonEncode(
          method == 'coreInfo' ? {'protocol': 3} : {'items': []},
        );
      });
      final provider = NativeProviderClient();
      final failure = isA<ProviderException>().having(
        (e) => e.message,
        'message',
        isNot(contains('secret')),
      );
      await expectLater(provider.call('catalog'), throwsA(failure));
      expect(initializations, 0);
      await expectLater(provider.initialize('/providers'), throwsA(failure));
      await expectLater(provider.call('catalog'), throwsA(failure));
      expect(methods, isEmpty);
      expect(initializations, 1);
      fail = false;
      final retry = provider.initialize('/providers');
      expect(provider.initialize('/providers'), same(retry));
      await provider.call('catalog');
      await retry;
      expect(initializations, 2);
      expect(methods, ['coreInfo', 'catalog']);
    },
  );

  test(
    'an incompatible protocol never releases queued provider operations',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return null;
        methods.add(
          (jsonDecode(call.arguments as String) as Map)['method'] as String,
        );
        return jsonEncode({'protocol': 2});
      });
      final provider = NativeProviderClient();
      final ready = provider.initialize('/providers');
      final failure = throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('版本不匹配'),
        ),
      );
      await Future.wait([
        expectLater(ready, failure),
        expectLater(provider.call('catalog'), failure),
      ]);
      expect(methods, ['coreInfo']);
    },
  );
}
