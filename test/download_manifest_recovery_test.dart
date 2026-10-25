import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/download_manifest_recovery.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'download_initialization_test.dart' show InitializationDriver;
import 'download_recovery_test.dart' show PlanProvider;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, media;
  late FileStorage storage;
  late DownloadEntry valid;
  late DownloadManifestRecovery recovery;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-manifest-recovery-');
    media = await Directory('${root.path}/media').create();
    storage = FileStorage(Directory('${root.path}/records'));
    final directory = await Directory('${media.path}/123').create();
    await File('${directory.path}/video.mp4').writeAsString('saved video');
    valid = DownloadEntry(
      id: '123',
      drama: const Drama(
        id: 'one',
        source: DramaSource.hongguo,
        title: '保存的视频',
      ),
      episode: Episode.fromJson({'id': 'episode'}, 0),
      index: 0,
      directory: '/old/container',
      input: 'video.mp4',
      contentKey: '',
      process: false,
      tasks: [],
      ready: true,
    );
    await Directory('${media.path}/456').create();
    await File(
      '${media.path}/456/partial.bin',
    ).writeAsString('unidentified data');
    await storage.write({
      'version': 1,
      'jobs': [valid.toJson(), 'damaged row'],
    });
    recovery = DownloadManifestRecovery(storage, media);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'partial repair preserves original, resumes valid media, protects unknown and late folders',
    () async {
      final original = await File(
        '${storage.directory.path}/state.json',
      ).readAsBytes();
      final preview = await recovery.inspect();
      expect(preview.entries.length, 1);
      expect(preview.rejected, 1);
      expect(preview.protectedDirectories, {'456'});
      await Directory('${media.path}/789').create();
      await File('${media.path}/789/late.bin').writeAsString('late data');
      final copy = await recovery.restore(preview);
      expect(await copy.readAsBytes(), original);
      final app = AppStore(storage: MemoryStorage(), provider: PlanProvider());
      final downloads = DownloadStore(
        app,
        driver: InitializationDriver(),
        storage: storage,
        root: media,
      );
      addTearDown(app.dispose);
      addTearDown(downloads.dispose);
      await downloads.initialize();
      expect(downloads.initializationError, isNull);
      expect(
        await downloads.localFile(valid.drama, valid.episode),
        '${media.path}/123/video.mp4',
      );
      expect(
        await File('${media.path}/456/partial.bin').readAsString(),
        'unidentified data',
      );
      expect(
        await File('${media.path}/789/late.bin').readAsString(),
        'late data',
      );
      expect(downloads.recoveryNotice, isNotNull);
      await downloads.enqueue(
        valid.drama,
        Episode.fromJson({'id': 'next'}, 1),
        1,
      );
      expect((await storage.read())!['preserveUnknownDirectories'], true);
      await downloads.cleanupOrphans();
      expect(await File('${media.path}/789/late.bin').exists(), true);
    },
  );

  test(
    'unreadable JSON can be preserved and reset without deleting media',
    () async {
      final bad = [123, 255, 0];
      await File('${storage.directory.path}/state.json').writeAsBytes(bad);
      final preview = await recovery.inspect();
      expect(preview.entries, isEmpty);
      final copy = await recovery.restore(preview);
      expect(await copy.readAsBytes(), bad);
      expect(await File('${media.path}/123/video.mp4').exists(), true);
      expect((await storage.read())!['jobs'], isEmpty);
    },
  );

  test(
    'failed replacement retains both original bytes and recovery copy',
    () async {
      final preview = await recovery.inspect();
      final original = await File(
        '${storage.directory.path}/state.json',
      ).readAsBytes();
      await Directory('${storage.directory.path}/state.json.tmp').create();
      await expectLater(
        recovery.restore(preview),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File('${storage.directory.path}/state.json').readAsBytes(),
        original,
      );
      final copies = await Directory(
        '${storage.directory.path}/recovery',
      ).list(recursive: true).where((e) => e is File).cast<File>().toList();
      expect(await copies.single.readAsBytes(), original);
      expect(await File('${media.path}/456/partial.bin').exists(), true);
    },
  );

  test('ambiguous duplicate and unsafe entries are isolated', () async {
    final unsafe = valid.toJson()
      ..['id'] = '999'
      ..['input'] = '../video.mp4';
    await storage.write({
      'version': 1,
      'jobs': [valid.toJson(), valid.toJson(), unsafe],
    });
    final preview = await recovery.inspect();
    expect(preview.entries, isEmpty);
    expect(preview.rejected, 3);
    expect(preview.protectedDirectories, {'123', '456'});
    final copy = await recovery.preserve();
    expect(jsonDecode(await copy.readAsString())['jobs'], hasLength(3));
  });
}
