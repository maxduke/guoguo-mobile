import 'dart:async';

// Inspect the real dependency registry where completed jobs used to leak.
// ignore: implementation_imports
import 'package:ffmpeg_kit_flutter_new_full/src/ffmpeg_kit_factory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/media_executor.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final jobs = <int, Completer<void>>{};
  final codes = <int, int>{};
  final cancelled = <int>[];
  var nextId = 1000;

  setUp(() {
    jobs.clear();
    codes.clear();
    cancelled.clear();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = (call.arguments as Map?)?['sessionId'] as int?;
      switch (call.method) {
        case 'getPlatform':
          return 'ios';
        case 'getArch':
          return 'arm64';
        case 'getPackageName':
          return 'full';
        case 'isLTSBuild':
          return false;
        case 'getLogLevel':
          return 16;
        case 'ffmpegSession':
          final sessionId = nextId++;
          jobs[sessionId] = Completer<void>();
          return {'sessionId': sessionId};
        case 'ffmpegSessionExecute':
          await jobs[id]!.future;
          return null;
        case 'abstractSessionGetReturnCode':
          return codes[id] ?? 0;
        case 'cancelSession':
          cancelled.add(id!);
          return null;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'many native jobs finish without retaining per-session callbacks',
    () async {
      const executor = NativeMediaExecutor();
      final registered = ffmpegSessionCompleteCallbackMap.length;
      for (var index = 0; index < 64; index++) {
        final execution = await executor.start(['-i', 'episode-$index.mp4']);
        final id = nextId - 1;
        // start must return while the native worker is still running so the
        // preparer can cancel it or serve progressive output.
        expect(jobs[id]!.isCompleted, isFalse);
        expect(ffmpegSessionCompleteCallbackMap.length, registered);
        jobs[id]!.complete();
        await execution.done;
        jobs.remove(id);
      }
      expect(ffmpegSessionCompleteCallbackMap.length, registered);
      expect(cancelled, isEmpty);
    },
  );

  test(
    'native cancellation targets the running job and waits for its worker',
    () async {
      final execution = await const NativeMediaExecutor().start([
        '-i',
        'input.mp4',
      ]);
      final id = nextId - 1;
      final cancellation = execution.cancel();
      var stopped = false;
      unawaited(cancellation.then((_) => stopped = true));
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, [id]);
      expect(stopped, isFalse);
      codes[id] = 255;
      jobs[id]!.complete();
      await cancellation;
      await expectLater(execution.done, throwsA(isA<ProviderException>()));
      expect(stopped, isTrue);
    },
  );

  test(
    'native worker failure settles done without exposing command details',
    () async {
      final execution = await const NativeMediaExecutor().start([
        '-i',
        'input.mp4',
      ]);
      jobs[nextId - 1]!.completeError(StateError('https://host/?key=secret'));
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
    },
  );
}
