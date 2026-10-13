import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/media_executor.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Session implements MediaNativeSession {
  _Session(this.id, {this.code = 0, this.log = '', this.resultError});

  @override
  final int id;
  final completion = Completer<void>();
  int? code;
  String log;
  Object? resultError;

  @override
  Future<void> get done => completion.future;

  @override
  Future<int?> returnCode() async {
    if (resultError case final error?) throw error;
    return code;
  }

  @override
  Future<String> logs() async => log;
}

class _Adapter implements MediaNativeAdapter {
  _Adapter(this.session, {this.completeBeforeReturn = false});

  final _Session session;
  final bool completeBeforeReturn;
  List<String>? receivedArguments;
  final cancelledIds = <int>[];
  Object? configureError;

  @override
  Future<void> configure() async {
    if (configureError case final error?) throw error;
  }

  @override
  Future<MediaNativeSession> execute(List<String> arguments) async {
    receivedArguments = arguments;
    if (completeBeforeReturn) finish();
    return session;
  }

  @override
  Future<void> cancel(int sessionId) async {
    cancelledIds.add(sessionId);
  }

  void finish() => session.completion.complete();
}

void main() {
  test(
    'returns a linked session and completes on successful native result',
    () async {
      final adapter = _Adapter(_Session(42));
      final execution = await NativeMediaExecutor(
        adapter: adapter,
      ).start(['-i', 'input.mp4']);

      expect(adapter.receivedArguments, ['-i', 'input.mp4']);
      adapter.finish();
      await execution.done;
      await execution.cancel();
      expect(adapter.cancelledIds, isEmpty);
    },
  );

  test('classifies failures without exposing the native log', () async {
    final adapter = _Adapter(
      _Session(42, code: 1, log: 'HTTP 403 https://host/?token=secret'),
    );
    final execution = await NativeMediaExecutor(adapter: adapter).start([]);
    adapter.finish();

    await expectLater(
      execution.done,
      throwsA(
        isA<ProviderException>()
            .having((error) => error.message, 'message', contains('访问被拒绝'))
            .having(
              (error) => error.message,
              'message',
              isNot(contains('secret')),
            ),
      ),
    );
  });

  test(
    'completion before start returns remains observable without zone errors',
    () async {
      final adapter = _Adapter(
        _Session(42, code: 2, log: 'key=secret'),
        completeBeforeReturn: true,
      );
      final execution = await NativeMediaExecutor(adapter: adapter).start([]);
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        execution.done,
        throwsA(
          isA<ProviderException>()
              .having((error) => error.message, 'message', contains('错误码 2'))
              .having(
                (error) => error.message,
                'message',
                isNot(contains('secret')),
              ),
        ),
      );
    },
  );

  test('result and startup exceptions are sanitized', () async {
    final adapter = _Adapter(
      _Session(42, resultError: StateError('https://host/?token=secret')),
    );
    final execution = await NativeMediaExecutor(adapter: adapter).start([]);
    adapter.finish();
    await expectLater(
      execution.done,
      throwsA(
        isA<ProviderException>().having(
          (error) => error.message,
          'message',
          isNot(contains('secret')),
        ),
      ),
    );

    adapter.configureError = StateError('key=secret');
    await expectLater(
      NativeMediaExecutor(adapter: adapter).start([]),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.message,
          'message',
          isNot(contains('secret')),
        ),
      ),
    );
  });

  test(
    'cancellation is session specific, idempotent, and waits for completion',
    () async {
      final adapter = _Adapter(_Session(73, code: 255));
      final execution = await NativeMediaExecutor(adapter: adapter).start([]);
      final first = execution.cancel();
      final second = execution.cancel();
      expect(identical(first, second), isTrue);
      expect(adapter.cancelledIds, [73]);

      var settled = false;
      first.then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      adapter.finish();
      await first;
      expect(settled, isTrue);
      await expectLater(
        execution.done,
        throwsA(
          isA<ProviderException>().having(
            (error) => error.message,
            'message',
            '已取消准备',
          ),
        ),
      );
      expect(adapter.cancelledIds, [73]);
    },
  );
}
