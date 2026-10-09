import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/file_usage.dart';
import '../platform/playback_temporary_files.dart';
import 'app_store.dart';
import 'cover_cache.dart';
import 'download_store.dart';
import 'storage.dart';

class StorageUsage {
  const StorageUsage({
    required this.downloadBytes,
    required this.playback,
    required this.coverBytes,
    required this.catalogBytes,
  });

  final int? downloadBytes, coverBytes, catalogBytes;
  final PlaybackFileUsage playback;
}

/// Each scope uses its existing owner for cleanup. Measurements are file sizes,
/// not a claim about all app data, filesystem allocation or native memory.
class StorageManager {
  StorageManager(
    this.store,
    this.downloads, {
    Future<Directory> Function()? temporaryDirectory,
    Future<void> Function()? clearCovers,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _clearCovers = clearCovers ?? _clearCoverCache;

  final AppStore store;
  final DownloadStore downloads;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<void> Function() _clearCovers;
  bool get canClearCatalog => store.storage is AppFileStorage;

  Future<int?> _downloadBytes() async {
    try {
      await downloads.refreshUsage();
      return downloads.manifestLoaded
          ? downloads.bytesFor(downloads.entries)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<(PlaybackFileUsage, int?)> _temporaryUsage() async {
    try {
      final root = await _temporaryDirectory();
      final playback = PlaybackTemporaryFiles.measure(
        Directory('${root.path}/playback'),
      );
      final covers = directoryFileBytes(
        Directory('${root.path}/$coverCacheKey'),
      );
      return (await playback, await covers);
    } catch (_) {
      return (
        const PlaybackFileUsage(activeBytes: null, unusedBytes: null),
        null,
      );
    }
  }

  Future<StorageUsage> measure() async {
    final downloads = _downloadBytes();
    final temporary = _temporaryUsage();
    final storage = store.storage;
    final catalog = storage is AppFileStorage
        ? storage.catalogCacheBytes()
        : Future<int?>.value();
    final (playback, covers) = await temporary;
    return StorageUsage(
      downloadBytes: await downloads,
      playback: playback,
      coverBytes: covers,
      catalogBytes: await catalog,
    );
  }

  Future<void> clearUnusedPlayback() async {
    final root = await _temporaryDirectory();
    await PlaybackTemporaryFiles.clearUnused(
      Directory('${root.path}/playback'),
    );
  }

  Future<void> clearCovers() => _clearCovers();
  Future<void> clearCatalog() => store.clearCatalogCache();
}

Future<void> _clearCoverCache() async {
  await coverCache.emptyCache();
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}
