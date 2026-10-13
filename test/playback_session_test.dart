import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/episode_buffer.dart';
import 'package:guoguo_mobile/platform/media_preparer.dart';
import 'package:guoguo_mobile/platform/playback_session.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

class _Provider implements ProviderClient {
  int resolves = 0, warms = 0;
  bool encrypted = true;
  int expiresAt = 0;
  final qualities = <int>[];
  final releases = <String>[], cancelled = <String>[];
  final plans = <String, Map<String, dynamic>>{};
  Completer<Map<String, dynamic>>? resolveGate, warmGate;

  Map<String, dynamic> plan(String session) => {
    'url': 'https://example.test/$session.mp4',
    'remoteUrl': 'https://example.test/$session.mp4',
    'session': session,
    'contentKey': encrypted ? '00112233445566778899aabbccddeeff' : '',
    'expiresAt': expiresAt,
  };
  Map<String, dynamic> cached(String session) => {
    ...plans[session]!,
    'url': 'http://127.0.0.1:43210/$session.mp4',
    'prefetchedBytes': 64,
    'prefetchMs': 10,
  };
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final id = args['id'] as String? ?? '';
    switch (method) {
      case 'resolve':
        resolves++;
        qualities.add(args['quality'] as int);
        final result = plan('session-$resolves');
        plans[result['session'] as String] = result;
        return resolveGate == null ? result : await resolveGate!.future;
      case 'prefetch':
        warms++;
        return warmGate == null ? cached(id) : await warmGate!.future;
      case 'cancelPrefetch':
        cancelled.add(id);
        if (warmGate != null && !warmGate!.isCompleted) {
          warmGate!.complete(cached(id));
        }
        return {};
      case 'release':
        releases.add(id);
        return {};
      default:
        throw StateError('Unexpected method $method');
    }
  }
}

class _Preparer extends MediaPreparer {
  final inputs = <ResolvedMedia>[], policies = <bool>[];
  Completer<String>? ready;
  bool cancelled = false, disposed = false, _streaming = false;
  int disposals = 0;
  @override
  bool get streaming => _streaming;
  @override
  Future<String> prepare(
    ResolvedMedia media, {
    bool progressive = false,
  }) async {
    inputs.add(media);
    policies.add(progressive);
    _streaming = progressive;
    if (ready != null) return ready!.future;
    return progressive
        ? 'http://127.0.0.1:43210/stream.m3u8'
        : media.contentKey.isEmpty
        ? media.url
        : '/tmp/prepared-${media.session}.mp4';
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    disposals++;
    await cancel();
  }
}

class _Fixture {
  final provider = _Provider();
  final jobs = <_Preparer>[];
  final phases = <String>[];
  DateTime now = DateTime.utc(2026, 10, 3);
  String? local;
  bool online = true, progressive = false;
  bool? fullPrefetch;
  _Preparer Function()? jobFactory;
  late final session = PlaybackSessionController(
    provider: provider,
    drama: const Drama(id: 'fixture', source: DramaSource.hongguo, title: '会话'),
    episodes: [
      Episode.fromJson({'id': '1'}, 0),
      Episode.fromJson({'id': '2'}, 1),
    ],
    localFile: (_) async => local,
    canResolve: () => online,
    progressive: (_) => progressive,
    completePrefetch: () => fullPrefetch ?? !progressive,
    onPhase: (_, label) => phases.add(label),
    now: () => now,
    preparerFactory: () {
      final job = jobFactory?.call() ?? _Preparer();
      jobs.add(job);
      return job;
    },
  );
  _Fixture() {
    addTearDown(() async {
      session.close();
      await settle();
    });
  }
}

void main() {
  test(
    'background CENC completes preparation before selection and reuses its file',
    () async {
      final f = _Fixture();
      final warmed = await f.session.prefetch(1);
      expect(f.jobs.single.inputs, hasLength(1));
      expect(f.jobs.single.policies, [false]);
      expect(warmed.path, '/tmp/prepared-session-1.mp4');
      expect(warmed.timing.preparation, 'complete');
      expect(warmed.timing.prefetchBytes, 64);
      f.now = f.now.add(const Duration(minutes: 3));
      final selected = await f.session.prepare(
        1,
        ticket: f.session.invalidate(),
      );
      expect(identical(warmed, selected), isTrue);
      expect(f.provider.resolves, 1);
      expect(f.provider.warms, 1);
      expect(f.jobs.single.inputs, hasLength(1));
      expect(
        f.jobs.single.inputs.single.url,
        'http://127.0.0.1:43210/session-1.mp4',
      );
      expect(selected.path, '/tmp/prepared-session-1.mp4');
      expect(selected.timing.preparation, 'complete');
      expect(f.provider.releases, isEmpty);
      f.session.close();
      f.session.close();
      await settle();
      expect(f.provider.releases, ['session-1']);
      expect(f.jobs.single.disposals, 1);
    },
  );

  test(
    'progressive and direct prefetch keep bounded media preparation',
    () async {
      for (final mode in ['progressive', 'direct']) {
        final f = _Fixture()..progressive = mode == 'progressive';
        f.provider.encrypted = mode != 'direct';
        final warmed = await f.session.prefetch(1);
        expect(f.jobs.single.inputs, isEmpty);
        expect(warmed.timing.prefetchBytes, 64);
        final selected = await f.session.prepare(
          1,
          ticket: f.session.invalidate(),
        );
        expect(selected, same(warmed));
        expect(f.jobs.single.policies, [mode == 'progressive']);
        expect(selected.timing.preparation, mode);
        expect(f.provider.resolves, 1);
      }
    },
  );

  test('complete prefetch does not start a progressive producer', () async {
    final f = _Fixture()
      ..progressive = true
      ..fullPrefetch = true;
    final warmed = await f.session.prefetch(1);
    expect(f.jobs.single.policies, [false]);
    expect(warmed.path, '/tmp/prepared-session-1.mp4');
    final selected = await f.session.prepare(1, ticket: f.session.invalidate());
    expect(selected, same(warmed));
    expect(f.jobs.single.inputs, hasLength(1));
  });

  test(
    'selection ends in-flight warming and removes only the background deadline',
    () async {
      final f = _Fixture();
      f.provider.warmGate = Completer();
      final warmed = f.session.prefetch(1);
      await settle();
      expect(f.provider.warms, 1);
      final selected = await f.session.prepare(
        1,
        ticket: f.session.invalidate(),
      );
      expect(identical(await warmed, selected), isTrue);
      expect(f.provider.cancelled, ['session-1']);
      expect(f.provider.resolves, 1);
      expect(f.provider.releases, isEmpty);
      expect(f.jobs.single.inputs, hasLength(1));
    },
  );

  testWidgets(
    'selection shares CENC preparation after the old 15 second limit',
    (tester) async {
      final f = _Fixture();
      final gate = Completer<String>();
      f.jobFactory = () => _Preparer()..ready = gate;
      final prefetch = f.session.prefetch(1);
      await tester.pump();
      expect(f.jobs.single.inputs, hasLength(1));
      await tester.pump(const Duration(seconds: 30));
      expect(f.jobs.single.cancelled, isFalse);
      expect(f.session.contains(1), isTrue);
      final selecting = f.session.prepare(1, ticket: f.session.invalidate());
      await tester.pump(const Duration(seconds: 40));
      expect(f.jobs.single.cancelled, isFalse);
      gate.complete('/tmp/ready.mp4');
      await tester.pump();
      expect(await selecting, same(await prefetch));
      expect(f.jobs.single.inputs, hasLength(1));
      expect(f.provider.resolves, 1);
      f.session.close();
      await tester.pump();
    },
  );

  testWidgets(
    'CENC background deadline cancels preparation and frees late media',
    (tester) async {
      final f = _Fixture();
      final gate = Completer<String>();
      f.jobFactory = () => _Preparer()..ready = gate;
      final prefetch = f.session.prefetch(
        1,
        timeout: const Duration(seconds: 3),
      );
      final failure = expectLater(prefetch, throwsA(isA<TimeoutException>()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await failure;
      expect(f.jobs.single.cancelled, isTrue);
      expect(f.session.contains(1), isFalse);
      gate.complete('/tmp/late.mp4');
      await tester.pump();
      expect(f.session.peek(1), isNull);
      expect(f.jobs.single.disposals, 1);
      expect(f.provider.releases, ['session-1']);
    },
  );

  test(
    'background preparation failure keeps the active episode usable',
    () async {
      final f = _Fixture();
      final current = await f.session.prepare(
        0,
        ticket: f.session.invalidate(),
      );
      final gate = Completer<String>();
      f.jobFactory = () => _Preparer()..ready = gate;
      final prefetch = f.session.prefetch(1);
      final failure = expectLater(prefetch, throwsA(isA<ProviderException>()));
      await settle();
      gate.completeError(const ProviderException('准备失败'));
      await failure;
      expect(f.session.peek(0), same(current));
      expect(f.jobs.first.cancelled, isFalse);
      expect(f.provider.releases, ['session-2']);
      f.jobFactory = null;
      final next = await f.session.prepare(1, ticket: f.session.invalidate());
      expect(next.path, '/tmp/prepared-session-3.mp4');
      expect(f.provider.resolves, 3);
    },
  );

  test(
    'closing during resolution releases the late result without preparing it',
    () async {
      final f = _Fixture();
      final gate = f.provider.resolveGate = Completer();
      final pending = f.session.prepare(0, ticket: f.session.invalidate());
      final failure = expectLater(pending, throwsA(isA<EpisodeCancelled>()));
      await settle();
      final phases = f.phases.length;
      f.session.close();
      gate.complete(f.provider.plans['session-1']);
      await failure;
      await settle();
      expect(f.jobs.single.inputs, isEmpty);
      expect(f.jobs.single.disposals, 1);
      expect(f.provider.releases, ['session-1']);
      expect(f.phases, hasLength(phases));
      expect(f.session.peek(0), isNull);
    },
  );

  test('late resolution cannot prepare or evict a newer selection', () async {
    final f = _Fixture();
    final gate = f.provider.resolveGate = Completer();
    final old = f.session.prepare(0, ticket: f.session.invalidate());
    final failure = expectLater(old, throwsA(isA<EpisodeCancelled>()));
    await settle();
    f.session.evict(0);
    f.provider.resolveGate = null;
    final fresh = await f.session.prepare(0, ticket: f.session.invalidate());
    gate.complete(f.provider.plans['session-1']);
    await failure;
    await settle();
    expect(f.session.peek(0), same(fresh));
    expect(f.jobs.first.inputs, isEmpty);
    expect(f.jobs.last.inputs.single.session, 'session-2');
    expect(f.provider.releases, ['session-1']);
  });

  test(
    'evicting background preparation rejects its late completion and preserves retry',
    () async {
      final f = _Fixture();
      final gate = Completer<String>();
      f.jobFactory = () =>
          f.jobs.isEmpty ? (_Preparer()..ready = gate) : _Preparer();
      final prefetch = f.session.prefetch(1);
      final prefetchFailure = expectLater(
        prefetch,
        throwsA(isA<EpisodeCancelled>()),
      );
      final old = f.session.prepare(1, ticket: f.session.invalidate());
      final failure = expectLater(old, throwsA(isA<EpisodeCancelled>()));
      await settle();
      expect(f.jobs.first.inputs, hasLength(1));
      f.session.retry(1);
      final fresh = await f.session.prepare(1, ticket: f.session.invalidate());
      gate.complete('/tmp/late.mp4');
      await failure;
      await prefetchFailure;
      await settle();
      expect(f.session.peek(1), same(fresh));
      expect(f.jobs.first.cancelled, isTrue);
      expect(f.jobs.first.disposals, 1);
      expect(f.provider.releases, ['session-1']);
      expect(fresh.path, '/tmp/prepared-session-2.mp4');
    },
  );

  test(
    'pending replacement ownership survives overwrites, retain and repeated close',
    () async {
      final f = _Fixture();
      f.session.retry(
        0,
        resolved: ResolvedMedia.fromJson(f.provider.plan('one')),
      );
      f.session.retry(
        0,
        resolved: ResolvedMedia.fromJson(f.provider.plan('two')),
      );
      f.session.retry(
        1,
        resolved: ResolvedMedia.fromJson(f.provider.plan('three')),
      );
      f.session.retain({0});
      await settle();
      expect(f.provider.releases, ['one', 'three']);
      f.session.close();
      f.session.close();
      await settle();
      f.session.retry(
        0,
        resolved: ResolvedMedia.fromJson(f.provider.plan('after-close')),
      );
      await settle();
      expect(f.provider.releases, ['one', 'three', 'two', 'after-close']);
      expect(f.provider.resolves, 0);
      expect(f.jobs, isEmpty);
    },
  );

  test(
    'remote TTL and expiring authorization refresh while complete local files remain reusable',
    () async {
      for (final mode in ['remote', 'authorization', 'local']) {
        final f = _Fixture();
        f.provider.encrypted = false;
        if (mode == 'local') f.local = '/tmp/local.mp4';
        if (mode == 'authorization') {
          f.provider.expiresAt = f.now
              .add(const Duration(seconds: 6))
              .millisecondsSinceEpoch;
        }
        final first = await f.session.prepare(
          0,
          ticket: f.session.invalidate(),
        );
        f.now = f.now.add(
          mode == 'authorization'
              ? const Duration(seconds: 2)
              : const Duration(minutes: 3),
        );
        f.provider.expiresAt = 0;
        final next = await f.session.prepare(0, ticket: f.session.invalidate());
        expect(identical(first, next), mode == 'local');
        expect(f.provider.resolves, mode == 'local' ? 0 : 2);
        expect(f.provider.releases, mode == 'local' ? isEmpty : ['session-1']);
      }
    },
  );

  test(
    'local/offline playback releases an unused replacement without resolving',
    () async {
      final f = _Fixture()
        ..online = false
        ..local = '/tmp/local.mp4';
      f.session.retry(
        0,
        resolved: ResolvedMedia.fromJson(f.provider.plan('unused')),
      );
      final item = await f.session.prepare(0, ticket: f.session.invalidate());
      expect(item.path, '/tmp/local.mp4');
      expect(item.media, isNull);
      expect(item.timing.local, isTrue);
      expect(f.jobs.single.inputs, isEmpty);
      expect(f.provider.resolves, 0);
      expect(f.provider.releases, ['unused']);
      f.session.close();
      await settle();
      expect(f.provider.releases, ['unused']);
    },
  );

  test(
    'selected preparation respects complete fallback and remembered quality',
    () async {
      final f = _Fixture()..progressive = true;
      f.session.requireComplete(1, compatibilityFallback: true);
      f.session.retry(1, quality: 720);
      await f.session.prefetch(1);
      final item = await f.session.prepare(1, ticket: f.session.invalidate());
      expect(f.jobs.single.policies, [false]);
      expect(item.timing.compatibilityFallback, isTrue);
      expect(item.timing.preparation, 'complete');
      f.session.retry(1);
      await f.session.prepare(1, ticket: f.session.invalidate());
      expect(f.provider.qualities, [720, 720]);
      expect(f.jobs.last.policies, [false]);
    },
  );

  test(
    'native setup serializes and skips stale queued work after a swipe',
    () async {
      final f = _Fixture();
      final gate = Completer<void>();
      final calls = <int>[];
      final oldTicket = f.session.invalidate();
      final first = f.session.installSource(oldTicket, () async {
        calls.add(1);
        await gate.future;
      });
      await settle();
      final currentTicket = f.session.invalidate();
      final stale = f.session.installSource(
        oldTicket,
        () async => calls.add(99),
      );
      final latest = f.session.installSource(
        currentTicket,
        () async => calls.add(2),
      );
      await settle();
      expect(calls, [1]);
      gate.complete();
      expect(await first, isFalse);
      expect(await stale, isFalse);
      expect(await latest, isTrue);
      expect(calls, [1, 2]);
    },
  );

  test('native setup failure leaves the next setup usable', () async {
    final f = _Fixture();
    final ticket = f.session.invalidate();
    final failed = f.session.installSource(
      ticket,
      () async => throw StateError('setup failed'),
    );
    final failure = expectLater(failed, throwsStateError);
    var installed = false;
    expect(
      await f.session.installSource(ticket, () async {
        installed = true;
      }),
      isTrue,
    );
    await failure;
    expect(installed, isTrue);
  });

  test(
    'closing invalidates in-flight native setup and prevents queued setup',
    () async {
      final f = _Fixture();
      final gate = Completer<void>();
      final ticket = f.session.invalidate();
      final first = f.session.installSource(ticket, () => gate.future);
      var queued = false;
      final next = f.session.installSource(ticket, () async {
        queued = true;
      });
      await settle();
      f.session.close();
      gate.complete();
      expect(await first, isFalse);
      expect(await next, isFalse);
      expect(queued, isFalse);
      expect(f.session.isCurrent(ticket), isFalse);
    },
  );
}
