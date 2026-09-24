import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:better_player_plus/better_player_plus.dart';
import 'package:guoguo_mobile/ui/episode_pager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/ui/player_page.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';
import 'package:guoguo_mobile/platform/media_preparer.dart';

import 'widget_test.dart' show NoNetwork;

// BetterPlayer also parses HLS in Dart; native playback is mocked separately.
class _PlaylistOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _PlaylistClient();
}

class _PlaylistClient implements HttpClient {
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (url.host != '127.0.0.1') {
      throw const SocketException('No network in test');
    }
    return _PlaylistRequest();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlaylistRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _PlaylistResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlaylistResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(
    utf8.encode(
      '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\nsegment_00000.m4s\n',
    ),
  ).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalDownloads extends DownloadStore {
  _LocalDownloads(super.store, this.directory);
  final String directory;
  final requestedIds = <String>[];

  @override
  Future<String?> localFile(Drama drama, Episode episode) async {
    requestedIds.add(episode.id);
    return '$directory/pip_episode_${episode.id}.mp4';
  }
}

class _NativePlayer {
  static const channel = MethodChannel('better_player_channel');
  static const eventChannel = MethodChannel(
    'better_player_channel/videoEvents7',
  );
  static const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity',
  );
  static const connectivityStatus = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  final sources = <String>[];
  final formats = <Object?>[];
  final plays = <Object?>[];
  final pauses = <Object?>[];
  final ids = <Object?>[];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'create') return {'textureId': 7};
      if (call.method == 'setDataSource') {
        ids.add(args?['textureId']);
        final source = args?['dataSource'] as Map;
        sources.add(source['uri'] as String);
        formats.add(source['videoFormat']);
        scheduleMicrotask(
          () => emit('initialized', {
            'duration': 30000,
            'width': 320.0,
            'height': 180.0,
          }),
        );
      }
      if (call.method == 'play') plays.add(args?['textureId']);
      if (call.method == 'pause') pauses.add(args?['textureId']);
      if (call.method == 'isPictureInPictureSupported') return true;
      if (call.method == 'position') return 0;
      return null;
    });
    messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(connectivityStatus, (_) async => null);
  }

  void emit(String event, [Map<String, Object?> extra = const {}]) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.handlePlatformMessage(
      eventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': event,
        ...extra,
      }),
      (_) {},
    );
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
    messenger.setMockMethodCallHandler(connectivity, null);
    messenger.setMockMethodCallHandler(connectivityStatus, null);
  }
}

class _OnlineDownloads extends DownloadStore {
  _OnlineDownloads(super.store);
  @override
  Future<String?> localFile(Drama drama, Episode episode) async => null;
}

class _Routes implements ProviderClient {
  int resolves = 0, fallbacks = 0;
  final releases = <String>[];
  Completer<Map<String, dynamic>>? pendingFallback;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'release') {
      releases.add(arguments['id'] as String);
      return {};
    }
    if (method == 'resolve') resolves++;
    if (method == 'fallback') {
      fallbacks++;
      if (pendingFallback != null) return pendingFallback!.future;
    }
    return plan(method == 'fallback' ? 1 : 0);
  }

  Map<String, dynamic> plan(int index) => {
    'url': 'https://example.test/route$index.mp4',
    'remoteUrl': 'https://example.test/route$index.mp4',
    'session': 'session-$resolves-$index',
    'routeIndex': index,
    'routeCount': 2,
  };
}

class _ProgressivePreparer extends MediaPreparer {
  bool requested = false, cancelled = false, disposed = false;
  bool produced = false;
  Completer<void>? readyGate;
  ProviderException? problem;
  @override
  bool get streaming => requested;
  @override
  bool get complete => produced;
  @override
  ProviderException? get failure => problem;
  @override
  Future<String> prepare(
    ResolvedMedia media, {
    bool progressive = false,
  }) async {
    requested = progressive;
    await readyGate?.future;
    return progressive
        ? 'http://127.0.0.1:43210/fixture/index.m3u8'
        : 'https://example.test/complete.mp4';
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await cancel();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _PlaylistOverrides());
  tearDownAll(() => HttpOverrides.global = originalOverrides);

  for (final trigger in [
    'error',
    'early end',
    'producer failure',
    'paused producer failure',
    'background',
    'paused background',
    'PiP',
    'paused PiP',
  ]) {
    testWidgets(
      'progressive $trigger switches to complete preparation with position and intent',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final platform = _NativePlayer()..install();
        addTearDown(platform.uninstall);
        final provider = _Routes();
        final store = AppStore(storage: MemoryStorage(), provider: provider)
          ..progressivePreparation = true
          ..prefetch = false
          ..playbackSpeed = 1.5;
        final downloads = _OnlineDownloads(store);
        final jobs = <_ProgressivePreparer>[];
        addTearDown(() {
          downloads.dispose();
          store.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              store: store,
              downloads: downloads,
              drama: const Drama(
                id: 'fixture',
                source: DramaSource.hongguo,
                title: '提前开播',
              ),
              episodes: [
                Episode.fromJson({'id': '1'}, 0),
                Episode.fromJson({'id': '2'}, 1),
              ],
              initialIndex: 0,
              preparerFactory: () {
                final job = _ProgressivePreparer();
                jobs.add(job);
                return job;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(jobs.single.requested, isTrue);
        expect(platform.sources.single, endsWith('index.m3u8'));
        final player = tester
            .widget<BetterPlayer>(find.byType(BetterPlayer))
            .controller;
        await player.seekTo(const Duration(seconds: 8));
        final paused = trigger.startsWith('paused');
        if (paused) {
          await tester.tapAt(const Offset(400, 300));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('暂停'));
          await tester.pumpAndSettle();
        }
        if (trigger.endsWith('PiP')) {
          if (!paused) {
            await tester.tapAt(const Offset(400, 300));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('更多播放设置'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('画中画').last);
        } else if (trigger.endsWith('background')) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
          expect(jobs.first.cancelled, isTrue);
          // A closed origin may reset native position before foregrounding.
          await player.seekTo(Duration.zero);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (trigger.endsWith('producer failure')) {
          jobs.first.problem = const ProviderException('synthetic failure');
          await tester.pump(const Duration(seconds: 2));
        } else {
          player.postEvent(
            BetterPlayerEvent(
              trigger == 'error'
                  ? BetterPlayerEventType.exception
                  : BetterPlayerEventType.finished,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(jobs, hasLength(2));
        expect(jobs.last.requested, isFalse);
        expect(jobs.first.cancelled, isTrue);
        expect(jobs.first.disposed, isTrue);
        expect(platform.sources.last, endsWith('complete.mp4'));
        expect(provider.fallbacks, 0);
        expect(
          player.videoPlayerController!.value.position,
          const Duration(seconds: 8),
        );
        expect(player.videoPlayerController!.value.speed, 1.5);
        expect(player.isPlaying(), !paused);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(jobs.last.disposed, isTrue);
      },
    );
  }

  testWidgets(
    'swiping while progressive preparation is pending cancels and releases the old job',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final platform = _NativePlayer()..install();
      addTearDown(platform.uninstall);
      final store = AppStore(storage: MemoryStorage(), provider: _Routes())
        ..progressivePreparation = true
        ..prefetch = false;
      final downloads = _OnlineDownloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      final first = _ProgressivePreparer()..readyGate = Completer<void>();
      final second = _ProgressivePreparer();
      var preparations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: 'fixture',
              source: DramaSource.hongguo,
              title: '切集',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
              Episode.fromJson({'id': '2'}, 1),
            ],
            initialIndex: 0,
            preparerFactory: () => preparations++ == 0 ? first : second,
          ),
        ),
      );
      await tester.pump();
      expect(first.requested, isTrue);
      await tester.drag(find.byType(EpisodePager), const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(first.cancelled, isTrue);
      first.readyGate!.complete();
      await tester.pumpAndSettle();
      expect(preparations, 2);
      expect(first.disposed, isTrue);
      expect(platform.sources, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final resume in [false, true]) {
    testWidgets(
      'progressive preference respects ${resume ? 'resume position' : 'default off'}',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final platform = _NativePlayer()..install();
        addTearDown(platform.uninstall);
        final store = AppStore(storage: MemoryStorage(), provider: _Routes())
          ..prefetch = false;
        const drama = Drama(
          id: 'fixture',
          source: DramaSource.hongguo,
          title: '续播',
        );
        if (resume) {
          store.progressivePreparation = true;
          await store.saveWatch(
            WatchRecord(
              drama: drama,
              episodeId: '1',
              episodeIndex: 0,
              positionMs: 8000,
              durationMs: 30000,
              updatedAt: DateTime.now(),
            ),
          );
        }
        final downloads = _OnlineDownloads(store);
        final job = _ProgressivePreparer();
        addTearDown(() {
          downloads.dispose();
          store.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              store: store,
              downloads: downloads,
              drama: drama,
              episodes: [
                Episode.fromJson({'id': '1'}, 0),
              ],
              initialIndex: 0,
              preparerFactory: () => job,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(job.requested, isFalse);
        expect(platform.sources.single, endsWith('complete.mp4'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'online recovery preserves position and speed, exhausts budget and releases sessions',
    (tester) async {
      final platform = _NativePlayer()..install();
      addTearDown(platform.uninstall);
      final provider = _Routes();
      final store = AppStore(storage: MemoryStorage(), provider: provider)
        ..playbackSpeed = 1.5
        ..autoAdvance = false;
      final downloads = _OnlineDownloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: 'fixture',
              source: DramaSource.hongguo,
              title: '播放恢复',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
              Episode.fromJson({'id': '2'}, 1),
            ],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final player = tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller;
      expect(find.byTooltip('返回').hitTestable(), findsNothing);
      await player.seekTo(const Duration(seconds: 8));
      player.postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));
      await tester.pumpAndSettle();
      expect(platform.sources, hasLength(1));
      void fail() =>
          player.postEvent(BetterPlayerEvent(BetterPlayerEventType.exception));
      fail();
      await tester.pumpAndSettle();
      expect(provider.fallbacks, 1);
      expect(provider.resolves, 1);
      expect(platform.sources.last, contains('route1.mp4'));
      expect(
        player.videoPlayerController!.value.position,
        const Duration(seconds: 8),
      );
      expect(player.videoPlayerController!.value.speed, 1.5);
      fail();
      await tester.pumpAndSettle();
      expect(provider.resolves, 2);
      fail();
      await tester.pumpAndSettle();
      expect(provider.fallbacks, 2);
      fail();
      await tester.pumpAndSettle();
      expect(find.text('自动恢复未成功，请重试或切换分集'), findsOneWidget);
      expect(platform.sources, hasLength(4));
      expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        provider.releases.toSet(),
        containsAll([
          'session-1-0',
          'session-1-1',
          'session-2-0',
          'session-2-1',
        ]),
      );
    },
  );

  testWidgets(
    'leaving during fallback releases its late result without restarting playback',
    (tester) async {
      final platform = _NativePlayer()..install();
      addTearDown(platform.uninstall);
      final provider = _Routes()
        ..pendingFallback = Completer<Map<String, dynamic>>();
      final store = AppStore(storage: MemoryStorage(), provider: provider);
      final downloads = _OnlineDownloads(store);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: 'fixture',
              source: DramaSource.hongguo,
              title: '播放恢复',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
            ],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final player = tester
          .widget<BetterPlayer>(find.byType(BetterPlayer))
          .controller;
      player.postEvent(BetterPlayerEvent(BetterPlayerEventType.exception));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      provider.pendingFallback!.complete(provider.plan(1));
      await tester.pump();
      await tester.pump();
      expect(platform.sources, hasLength(1));
      expect(provider.releases, contains('session-1-1'));
    },
  );

  testWidgets('swiping episodes preserves contain and selected fill mode', (
    tester,
  ) async {
    final platform = _NativePlayer()..install();
    addTearDown(platform.uninstall);
    final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
      ..offline = true;
    final directory = Directory.systemTemp.createTempSync('guoguo-fit-');
    for (var i = 1; i <= 3; i++) {
      File('${directory.path}/pip_episode_$i.mp4').createSync();
    }
    addTearDown(() => directory.deleteSync(recursive: true));
    final downloads = _LocalDownloads(store, directory.path);
    addTearDown(() {
      downloads.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          store: store,
          downloads: downloads,
          drama: const Drama(
            id: '1',
            source: DramaSource.hongguo,
            title: '比例回归',
          ),
          episodes: [
            for (var i = 1; i <= 3; i++) Episode.fromJson({'id': '$i'}, i - 1),
          ],
          initialIndex: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final player = tester
        .widget<BetterPlayer>(find.byType(BetterPlayer))
        .controller;
    void expectMode(String mode) {
      expect(player.videoPlayerController!.value.aspectRatioIOS, mode);
      expect(player.getFit(), mode == 'aspect' ? BoxFit.contain : BoxFit.cover);
    }

    Future<void> swipe(double dy) async {
      await tester.drag(find.byType(EpisodePager), Offset(0, dy));
      await tester.pumpAndSettle();
    }

    expectMode('aspect');
    await swipe(-500);
    expect(platform.sources.last, contains('pip_episode_2.mp4'));
    expectMode('aspect');
    await swipe(500);
    expect(platform.sources.last, contains('pip_episode_1.mp4'));
    expectMode('aspect');
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多播放设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('等比例铺满（裁切边缘）'));
    await tester.pumpAndSettle();
    expectMode('fill');
    await swipe(-500);
    expectMode('fill');
    expect(platform.sources.last, contains('pip_episode_2.mp4'));
    expect(platform.ids.toSet(), {7});
    await tester.pumpWidget(const SizedBox());
  });

  for (final initiallyPaused in [false, true]) {
    testWidgets(
      'explicit PiP entry ${initiallyPaused ? 'keeps user pause' : 'restores playback after transition pause'}',
      (tester) async {
        final platform = _NativePlayer()..install();
        addTearDown(platform.uninstall);
        final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
          ..offline = true;
        final directory = Directory.systemTemp.createTempSync('guoguo-pip-');
        File('${directory.path}/pip_episode_1.mp4').createSync();
        addTearDown(() => directory.deleteSync(recursive: true));
        final downloads = _LocalDownloads(store, directory.path);
        addTearDown(() {
          downloads.dispose();
          store.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              store: store,
              downloads: downloads,
              drama: const Drama(
                id: '1',
                source: DramaSource.hongguo,
                title: '画中画',
              ),
              episodes: [
                Episode.fromJson({'id': '1'}, 0),
              ],
              initialIndex: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(platform.plays, hasLength(1));
        await tester.tapAt(const Offset(400, 300));
        await tester.pump();
        if (initiallyPaused) {
          await tester.tap(find.byTooltip('暂停'));
          await tester.pump();
        }
        await tester.tap(find.byTooltip('更多播放设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('画中画').last);
        await tester.pumpAndSettle();
        platform.emit('pause'); // Simulate AVKit pausing while opening PiP.
        await tester.pump();
        final playsBeforePip = platform.plays.length;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        platform.emit('pipStart');
        await tester.pump();
        expect(
          platform.plays.length,
          initiallyPaused ? playsBeforePip : playsBeforePip + 1,
        );
        platform.emit('pipStop');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'PiP keeps one texture across episodes and stops advancing when closed',
    (tester) async {
      final platform = _NativePlayer()..install();
      addTearDown(platform.uninstall);
      final store = AppStore(storage: MemoryStorage(), provider: NoNetwork())
        ..offline = true;
      final directory = Directory.systemTemp.createTempSync('guoguo-pip-');
      File('${directory.path}/pip_episode_1.mp4').createSync();
      File('${directory.path}/pip_episode_2.mp4').createSync();
      File('${directory.path}/pip_episode_3.mp4').createSync();
      File('${directory.path}/pip_episode_4.mp4').createSync();
      addTearDown(() => directory.deleteSync(recursive: true));
      final downloads = _LocalDownloads(store, directory.path);
      addTearDown(() {
        downloads.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            store: store,
            downloads: downloads,
            drama: const Drama(
              id: '1',
              source: DramaSource.hongguo,
              title: '剧',
            ),
            episodes: [
              Episode.fromJson({'id': '1'}, 0),
              Episode.fromJson({'id': '2'}, 1),
              Episode.fromJson({'id': '3'}, 2),
              Episode.fromJson({'id': '4'}, 3),
            ],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.sources, hasLength(1));
      expect(platform.plays, hasLength(1));

      platform.emit('pipStart');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      platform.emit('completed');
      platform.emit(
        'completed',
      ); // A duplicate completion must not skip episode 2.
      await tester.pumpAndSettle();

      expect(platform.sources, hasLength(2));
      expect(platform.sources.last, contains('pip_episode_2.mp4'));
      expect(platform.ids, [7, 7]);
      expect(platform.plays, hasLength(2));
      // A transient resume does not end PiP until native reports pipStop.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      store.prefetch = false;
      platform.emit('completed');
      await tester.pumpAndSettle();
      expect(platform.sources.last, contains('pip_episode_3.mp4'));
      expect(platform.ids, [7, 7, 7]);
      expect(platform.plays, hasLength(3));
      store.prefetch = true;
      platform.emit('play');
      await tester.pump(); // Arm the delayed prefetch before closing PiP.
      final pausesBeforeClose = platform.pauses.length;
      platform.emit('pipStop');
      await tester.pump(const Duration(seconds: 3));
      expect(platform.pauses.length, greaterThan(pausesBeforeClose));
      expect(downloads.requestedIds, isNot(contains('4')));
      final playsBeforeCompletion = platform.plays.length;
      platform.emit('completed');
      await tester.pumpAndSettle();
      expect(platform.sources, hasLength(3));
      expect(platform.plays, hasLength(playsBeforeCompletion));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
