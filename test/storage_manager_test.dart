import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/cover_cache.dart';
import 'package:guoguo_mobile/data/download_store.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/data/storage_manager.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/playback_temporary_files.dart';
import 'widget_test.dart' show NoNetwork;

DownloadEntry entry(String directory) => DownloadEntry(
  id: 'download',
  drama: const Drama(id: 'a', source: DramaSource.hongguo, title: '剧集'),
  episode: const Episode(id: 'e', title: '第一集', number: 1, raw: {}),
  index: 0,
  directory: directory,
  input: 'video.mp4',
  process: false,
  contentKey: '',
  tasks: [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late DownloadStore downloads;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('guoguo-storage-manager-');
    store = AppStore(
      storage: AppFileStorage(Directory('${root.path}/records')),
      provider: NoNetwork(),
    );
    downloads = DownloadStore(store)..manifestLoaded = true;
  });
  tearDown(() async {
    downloads.dispose();
    store.dispose();
    await root.delete(recursive: true);
  });

  test(
    'all cleanup scopes preserve downloaded files, live playback and records',
    () async {
      await store.records.toggleFavorite(entry('unused').drama);
      await store.catalog.saveRecommendations([entry('unused').drama]);
      final durable = File('${root.path}/records/records.json');
      final before = await durable.readAsBytes();
      final download = await Directory('${root.path}/download').create();
      final video = File('${download.path}/video.mp4');
      await video.writeAsBytes(List.filled(1024, 1));
      downloads.entries = [entry(download.path)];
      final coverDirectory = await Directory(
        '${root.path}/$coverCacheKey',
      ).create();
      final registered = File('${coverDirectory.path}/registered');
      await registered.writeAsBytes([1, 2, 3]);
      await File('${coverDirectory.path}/unregistered').writeAsBytes([4, 5]);
      final playback = Directory('${root.path}/playback');
      final active = await PlaybackTemporaryFiles.allocate(playback);
      addTearDown(() => PlaybackTemporaryFiles.released(active));
      await File('${active.path}/video').writeAsBytes([1, 2, 3, 4]);
      final stale = await Directory('${playback.path}/session-unused').create();
      await File('${stale.path}/video').writeAsBytes([1, 2]);
      final manager = StorageManager(
        store,
        downloads,
        temporaryDirectory: () async => root,
        clearCovers: () async => registered.delete(),
      );
      var usage = await manager.measure();
      expect(usage.downloadBytes, 1024);
      expect(usage.coverBytes, 5);
      expect(usage.playback.activeBytes, 4);
      expect(usage.playback.unusedBytes, 2);
      expect(usage.catalogBytes, greaterThan(0));
      await manager.clearUnusedPlayback();
      await manager.clearCovers();
      await manager.clearCatalog();
      usage = await manager.measure();
      expect(usage.coverBytes, 2);
      expect(usage.playback.activeBytes, 4);
      expect(usage.playback.unusedBytes, 0);
      expect(usage.catalogBytes, 0);
      expect(usage.downloadBytes, 1024);
      expect(await video.length(), 1024);
      expect(await durable.readAsBytes(), before);
      expect(store.catalog.catalogs[DramaSource.hongguo], isNotEmpty);
      expect(downloads.entries, hasLength(1));
    },
  );

  test(
    'download path collisions and linked roots remain unknown instead of zero',
    () async {
      final obstacle = File('${root.path}/obstacle');
      await obstacle.writeAsBytes([1, 2, 3]);
      downloads.entries = [entry(obstacle.path)];
      final manager = StorageManager(
        store,
        downloads,
        temporaryDirectory: () async => root,
        clearCovers: () async {},
      );
      expect((await manager.measure()).downloadBytes, isNull);
      expect(downloads.usageError, isNotNull);
      final actual = await Directory('${root.path}/actual').create();
      await File('${actual.path}/outside-video').writeAsBytes([1]);
      final link = await Link('${root.path}/download-link').create(actual.path);
      downloads.entries = [entry(link.path)];
      expect((await manager.measure()).downloadBytes, isNull);
      downloads.entries = [entry('${root.path}/missing')];
      expect((await manager.measure()).downloadBytes, 0);
      expect(downloads.usageError, isNull);
    },
  );

  test(
    'temporary-directory failures do not hide independent download and catalog sizes',
    () async {
      final manager = StorageManager(
        store,
        downloads,
        temporaryDirectory: () async =>
            throw const FileSystemException('private error'),
        clearCovers: () async {},
      );
      final usage = await manager.measure();
      expect(usage.downloadBytes, 0);
      expect(usage.catalogBytes, 0);
      expect(usage.coverBytes, isNull);
      expect(usage.playback.totalBytes, isNull);
    },
  );

  test(
    'an unread download manifest has unknown usage instead of a false zero',
    () async {
      downloads.manifestLoaded = false;
      final manager = StorageManager(
        store,
        downloads,
        temporaryDirectory: () async => root,
        clearCovers: () async {},
      );
      expect((await manager.measure()).downloadBytes, isNull);
      downloads.manifestLoaded = true;
      expect((await manager.measure()).downloadBytes, 0);
    },
  );
}
