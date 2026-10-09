import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_driver.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class FakeDriver extends DownloadDriver {
  bool failSubmit = false;
  final saved = <String, TaskRecord>{};
  final submitted = <DownloadTask>[];
  final canceled = <String>[];
  @override
  Future<TaskRecord?> record(String id) async => saved[id];
  @override
  Future<List<TaskRecord>> records() async => saved.values.toList();
  @override
  Future<bool> enqueue(DownloadTask task) async {
    if (failSubmit) throw StateError('native queue unavailable');
    submitted.add(task);
    saved[task.taskId] = TaskRecord(task, TaskStatus.enqueued, 0, -1);
    return true;
  }

  @override
  Future<bool> cancel(Iterable<String> ids) async {
    canceled.addAll(ids);
    return true;
  }

  @override
  Future<void> deleteRecord(String id) async {
    saved.remove(id);
  }
}

class PlanProvider implements ProviderClient {
  bool fail = false, changed = false, empty = false, signed = false;
  void Function(Map<String, dynamic>)? mutate;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (fail) throw const ProviderException('暂时无法获取资源');
    final plan = <String, dynamic>{
      'refreshOnResume': signed,
      'input': 'local.m3u8',
      'process': true,
      'contentKey': changed ? 'changed' : '',
      'headers': <String, String>{},
      'inline': [
        {
          'name': 'local.m3u8',
          'body': base64Encode(utf8.encode('fixture playlist')),
        },
      ],
      'assets': empty
          ? []
          : [
              {
                'name': '1.bin',
                'url': signed
                    ? 'https://example.com/1?Signature=new'
                    : 'https://example.com/1',
                if (signed) 'identity': 'https://example.com/1',
              },
              {
                'name': '2.bin',
                'url': signed
                    ? 'https://example.com/2?Signature=new'
                    : 'https://example.com/2?renewed',
                if (signed) 'identity': 'https://example.com/2',
              },
            ],
    };
    mutate?.call(plan);
    return plan;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore app;
  late DownloadStore downloads;
  late FakeDriver driver;
  late PlanProvider provider;
  late MemoryStorage storage;
  late DownloadEntry entry;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-recovery-');
    provider = PlanProvider();
    driver = FakeDriver();
    storage = MemoryStorage();
    app = AppStore(storage: MemoryStorage(), provider: provider);
    downloads = DownloadStore(
      app,
      driver: driver,
      storage: storage,
      root: root,
    );
    final directory = await Directory('${root.path}/123').create();
    await File('${directory.path}/1.bin').writeAsString('keep this fragment');
    await File(
      '${directory.path}/local.m3u8',
    ).writeAsString('fixture playlist');
    entry = DownloadEntry(
      id: '123',
      drama: const Drama(
        id: 'd',
        source: DramaSource.hongguo,
        title: 'fixture',
      ),
      episode: Episode.fromJson({'id': 'e'}, 0),
      index: 0,
      directory: directory.path,
      input: 'local.m3u8',
      contentKey: '',
      process: true,
      failure: '旧失败',
      tasks: [
        for (var i = 1; i <= 2; i++)
          DownloadTask(
            taskId: '123_$i',
            url: 'https://example.com/$i',
            filename: '$i.bin',
            group: 'guoguo',
            metaData: '123',
          ),
      ],
    );
    downloads.entries.add(entry);
    driver.saved['123_1'] = TaskRecord(
      entry.tasks[0],
      TaskStatus.complete,
      1,
      18,
    );
    driver.saved['123_2'] = TaskRecord(
      entry.tasks[1],
      TaskStatus.failed,
      0,
      -1,
    );
  });
  tearDown(() async {
    downloads.dispose();
    app.dispose();
    await root.delete(recursive: true);
  });

  final invalidPlans = <String, void Function(Map<String, dynamic>)>{
    'parent path': (plan) => plan['inline'][0]['name'] = '../local.m3u8',
    'duplicate asset': (plan) =>
        plan['assets'].add(<String, dynamic>{...plan['assets'][0]}),
    'inline collision': (plan) => plan['inline'][0]['name'] = '1.bin',
    'invalid base64': (plan) => plan['inline'][0]['body'] = '!',
    'missing input': (plan) => plan['input'] = 'missing.m3u8',
    'invalid headers': (plan) => plan['headers'] = {'Referer': 1},
    'invalid process': (plan) => plan['process'] = 'true',
    'invalid refresh': (plan) => plan['refreshOnResume'] = 'true',
    'invalid URL': (plan) => plan['assets'][0]['url'] = 'file:///1.bin',
  };
  for (final invalid in invalidPlans.entries) {
    test('${invalid.key} is rejected before staging a new download', () async {
      provider.mutate = invalid.value;
      final before = await root.list().map((item) => item.path).toList();
      await expectLater(
        downloads.enqueue(entry.drama, Episode.fromJson({'id': 'new'}, 0), 0),
        throwsA(isA<ProviderException>()),
      );
      expect(await root.list().map((item) => item.path).toList(), before);
      expect(downloads.entries, [entry]);
      expect(driver.submitted, isEmpty);
    });

    test(
      '${invalid.key} preserves the original tasks and files on retry',
      () async {
        provider.mutate = invalid.value;
        final original = entry.tasks.toList();
        await expectLater(downloads.retry(entry), throwsA(anything));
        expect(entry.tasks, original);
        expect(driver.canceled, isEmpty);
        expect(driver.submitted, isEmpty);
        expect(
          await File('${entry.directory}/1.bin').readAsString(),
          'keep this fragment',
        );
        expect(
          await File('${entry.directory}/local.m3u8').readAsString(),
          'fixture playlist',
        );
      },
    );
  }

  test(
    'lost signed native task is recreated with a fresh grant on restart',
    () async {
      provider.signed = true;
      entry.refreshOnResume = true;
      entry.assetIdentities.addAll({
        '1.bin': 'https://example.com/1',
        '2.bin': 'https://example.com/2',
      });
      entry.userPaused = false;
      entry.failure = null;
      driver.saved.remove(entry.tasks.last.taskId);
      await downloads.restorePendingTasks();
      expect(driver.submitted.single.url, contains('Signature=new'));
      expect(
        await File('${entry.directory}/1.bin').readAsString(),
        'keep this fragment',
      );
    },
  );

  test(
    'signed download resume refreshes grants and keeps completed assets by identity',
    () async {
      provider.signed = true;
      entry.refreshOnResume = true;
      entry.assetIdentities.addAll({
        '1.bin': 'https://example.com/1',
        '2.bin': 'https://example.com/2',
      });
      entry.tasks[0] = entry.tasks[0].copyWith(
        url: 'https://example.com/1?Signature=old',
      );
      await downloads.resume(entry);
      expect(driver.submitted, hasLength(1));
      expect(
        driver.submitted.single.url,
        'https://example.com/2?Signature=new',
      );
      expect(
        await File('${entry.directory}/1.bin').readAsString(),
        'keep this fragment',
      );
      final restored = DownloadEntry.fromJson(entry.toJson());
      expect(restored.refreshOnResume, isTrue);
      expect(restored.assetIdentities, entry.assetIdentities);
    },
  );

  test(
    'changed signed asset identity cannot be mixed with downloaded fragments',
    () async {
      provider.signed = true;
      entry.refreshOnResume = true;
      entry.assetIdentities['1.bin'] = 'https://example.com/different';
      await expectLater(
        downloads.resume(entry),
        throwsA(isA<ProviderException>()),
      );
      expect(driver.submitted, isEmpty);
      expect(
        await File('${entry.directory}/1.bin').readAsString(),
        'keep this fragment',
      );
    },
  );
  test(
    'native storage failure is explained and persisted without raw URLs',
    () async {
      entry.failure = null;
      driver.saved['123_2'] = TaskRecord(
        entry.tasks[1],
        TaskStatus.failed,
        0,
        -1,
        TaskFileSystemException('https://private.example/token=secret'),
      );
      await downloads.reload();
      expect(entry.failure, contains('剩余空间'));
      expect(entry.failure, isNot(contains('secret')));
      expect((storage.value!['jobs'] as List).single['failure'], entry.failure);
    },
  );

  test(
    'enqueue exception keeps registered task with persisted failure',
    () async {
      driver.failSubmit = true;
      await expectLater(
        downloads.enqueue(
          const Drama(id: 'new', source: DramaSource.hongguo, title: 'new'),
          entry.episode,
          0,
        ),
        throwsA(isA<ProviderException>()),
      );
      final created = downloads.entries.last;
      expect(created.drama.id, 'new');
      expect(created.status, TaskStatus.failed);
      expect(created.failure, isNotNull);
      expect(await Directory(created.directory).exists(), isTrue);
      expect((storage.value!['jobs'] as List).last['failure'], created.failure);
    },
  );

  test('failed planning preserves original task and completed file', () async {
    provider.fail = true;
    await expectLater(
      downloads.retry(entry),
      throwsA(isA<ProviderException>()),
    );
    expect(downloads.entries.single, same(entry));
    expect(
      await File('${entry.directory}/1.bin').readAsString(),
      'keep this fragment',
    );
    expect(driver.canceled, isEmpty);
    expect(driver.submitted, isEmpty);
    final restored = DownloadEntry.fromJson(
      Map<String, dynamic>.from((storage.value!['jobs'] as List).single),
    );
    expect(restored.failure, contains('暂时无法'));
  });

  test('retry submits only missing segment with refreshed URL', () async {
    await downloads.retry(entry);
    expect(driver.submitted.map((t) => t.taskId), ['123_2']);
    expect(driver.submitted.single.url, endsWith('?renewed'));
    expect(driver.canceled, ['123_2']);
    expect(entry.failure, isNull);
    expect(await File('${entry.directory}/1.bin').exists(), isTrue);
    expect(entry.progress, .5);
  });

  test('changed content key cannot mix new and old fragments', () async {
    provider.changed = true;
    await expectLater(
      downloads.retry(entry),
      throwsA(isA<ProviderException>()),
    );
    expect(driver.submitted, isEmpty);
    expect(driver.canceled, isEmpty);
    expect(await File('${entry.directory}/1.bin').exists(), isTrue);
  });

  test('invalid new plan leaves no unregistered directory', () async {
    provider.empty = true;
    await expectLater(
      downloads.enqueue(
        const Drama(id: 'other', source: DramaSource.hongguo, title: 'other'),
        entry.episode,
        0,
      ),
      throwsA(isA<ProviderException>()),
    );
    expect(await root.list().length, 1);
  });

  test(
    'orphan cleanup keeps registered directories and unrelated names',
    () async {
      await Directory('${root.path}/456').create();
      await Directory('${root.path}/notes').create();
      await downloads.cleanupOrphans();
      expect(await Directory('${root.path}/456').exists(), isFalse);
      expect(await Directory('${root.path}/notes').exists(), isTrue);
      expect(await File('${entry.directory}/1.bin').exists(), isTrue);
    },
  );
}
