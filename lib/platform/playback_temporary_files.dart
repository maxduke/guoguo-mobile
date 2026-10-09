import 'dart:io';

import 'package:path/path.dart' as path;

import 'file_usage.dart';

class PlaybackFileUsage {
  const PlaybackFileUsage({
    required this.activeBytes,
    required this.unusedBytes,
  });
  final int? activeBytes, unusedBytes;
  int? get totalBytes => activeBytes == null || unusedBytes == null
      ? null
      : activeBytes! + unusedBytes!;
}

/// Only MediaPreparer's session directories belong to this cleanup scope.
class PlaybackTemporaryFiles {
  static final _active = <String>{};
  static Future<void> _maintenance = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _maintenance.then((_) => operation());
    _maintenance = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  static String _identity(Directory directory) =>
      path.normalize(directory.absolute.path);

  static Future<Directory> allocate(Directory root) => _serialized(() async {
    if (await FileSystemEntity.isLink(root.path)) {
      throw FileSystemException('播放临时目录不可用', root.path);
    }
    await root.create(recursive: true);
    final directory = await root.createTemp('session-');
    // Registration is inside the allocation boundary; cleanup cannot observe
    // a newly created session before its owner has been registered.
    _active.add(_identity(directory));
    return directory;
  });

  static void released(Directory directory) =>
      _active.remove(_identity(directory));

  static bool _session(Directory directory) => directory.uri.pathSegments
      .where((part) => part.isNotEmpty)
      .last
      .startsWith('session-');

  static Future<PlaybackFileUsage> measure(Directory root) async {
    int? activeBytes = 0, unusedBytes = 0;
    try {
      if (await FileSystemEntity.isLink(root.path)) {
        return const PlaybackFileUsage(activeBytes: null, unusedBytes: null);
      }
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory || !_session(entry)) continue;
        final bytes = await directoryFileBytes(entry);
        if (_active.contains(_identity(entry))) {
          activeBytes = activeBytes == null || bytes == null
              ? null
              : activeBytes + bytes;
        } else {
          unusedBytes = unusedBytes == null || bytes == null
              ? null
              : unusedBytes + bytes;
        }
      }
    } on FileSystemException catch (error) {
      if (!missingFileScope(error, root.path)) {
        return const PlaybackFileUsage(activeBytes: null, unusedBytes: null);
      }
    }
    return PlaybackFileUsage(
      activeBytes: activeBytes,
      unusedBytes: unusedBytes,
    );
  }

  static Future<void> clearUnused(Directory root) => _serialized(() async {
    if (await FileSystemEntity.isLink(root.path)) {
      throw FileSystemException('播放临时目录不可用', root.path);
    }
    try {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory &&
            _session(entry) &&
            !_active.contains(_identity(entry))) {
          await entry.delete(recursive: true);
        }
      }
    } on FileSystemException catch (error) {
      if (!missingFileScope(error, root.path)) rethrow;
    }
  });
}
