import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/file_usage.dart';
import 'package:guoguo_mobile/platform/playback_temporary_files.dart';

class _AllocatingDirectory implements Directory {
  _AllocatingDirectory(this.directory);
  final Directory directory;
  final created = Completer<Directory>(), release = Completer<void>();
  @override
  String get path => directory.path;
  @override
  Future<Directory> create({bool recursive = false}) =>
      directory.create(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) async {
    final session = await directory.createTemp(prefix);
    await File('${session.path}/native-output').writeAsBytes([1, 2, 3]);
    created.complete(session);
    await release.future;
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DisappearingFileDirectory implements Directory {
  _DisappearingFileDirectory(this.path);
  @override
  final String path;
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.value(File('$path/vanished'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('guoguo-playback-files-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'missing scopes are empty; invalid and incomplete scopes are unknown',
    () async {
      final missing = Directory('${root.path}/missing/');
      expect(await directoryFileBytes(missing), 0);
      expect(await fileBytes(File('${root.path}/missing-file')), 0);
      final usage = await PlaybackTemporaryFiles.measure(missing);
      expect(usage.totalBytes, 0);
      await PlaybackTemporaryFiles.clearUnused(missing);
      final collision = File('${root.path}/not-a-directory');
      await collision.writeAsString('keep');
      expect(await directoryFileBytes(Directory(collision.path)), isNull);
      expect(await fileBytes(File(root.path)), isNull);
      expect(
        await directoryFileBytes(_DisappearingFileDirectory(root.path)),
        isNull,
      );
      expect(
        (await PlaybackTemporaryFiles.measure(
          Directory(collision.path),
        )).totalBytes,
        isNull,
      );
      await expectLater(
        PlaybackTemporaryFiles.clearUnused(Directory(collision.path)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await collision.readAsString(), 'keep');
    },
  );

  test(
    'cleanup protects all active owners and only deletes owned unused sessions',
    () async {
      final playback = Directory('${root.path}/playback');
      final phone = await PlaybackTemporaryFiles.allocate(playback);
      final airPlay = await PlaybackTemporaryFiles.allocate(playback);
      addTearDown(() {
        PlaybackTemporaryFiles.released(phone);
        PlaybackTemporaryFiles.released(airPlay);
      });
      await File('${phone.path}/video').writeAsBytes([1, 2]);
      await File('${airPlay.path}/video').writeAsBytes([3, 4, 5]);
      final stale = await Directory('${playback.path}/session-stale').create();
      await File('${stale.path}/video').writeAsBytes([6, 7, 8, 9]);
      final unrelated = await Directory('${playback.path}/other-data').create();
      await File('${unrelated.path}/keep').writeAsBytes([10]);
      var usage = await PlaybackTemporaryFiles.measure(playback);
      expect(usage.activeBytes, 5);
      expect(usage.unusedBytes, 4);
      await PlaybackTemporaryFiles.clearUnused(playback);
      expect(await stale.exists(), isFalse);
      expect(await phone.exists(), isTrue);
      expect(await airPlay.exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
      PlaybackTemporaryFiles.released(phone);
      await PlaybackTemporaryFiles.clearUnused(playback);
      expect(await phone.exists(), isFalse);
      expect(await airPlay.exists(), isTrue);
      usage = await PlaybackTemporaryFiles.measure(playback);
      expect(usage.activeBytes, 3);
      expect(usage.unusedBytes, 0);
    },
  );

  test(
    'cleanup cannot enter the asynchronous allocation and registration window',
    () async {
      final playback = _AllocatingDirectory(Directory('${root.path}/playback'));
      final allocation = PlaybackTemporaryFiles.allocate(playback);
      final session = await playback.created.future;
      addTearDown(() => PlaybackTemporaryFiles.released(session));
      var cleaned = false;
      final cleanup = PlaybackTemporaryFiles.clearUnused(
        playback.directory,
      ).then((_) => cleaned = true);
      await Future<void>.delayed(Duration.zero);
      expect(cleaned, isFalse);
      expect(await session.exists(), isTrue);
      playback.release.complete();
      expect(await allocation, session);
      await cleanup;
      expect(await File('${session.path}/native-output').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'linked roots and session links cannot count or remove external files',
    () async {
      final external = await Directory('${root.path}/external').create();
      final file = File('${external.path}/keep');
      await file.writeAsBytes([1, 2, 3]);
      final playback = await Directory('${root.path}/playback').create();
      await Link('${playback.path}/session-link').create(external.path);
      expect((await PlaybackTemporaryFiles.measure(playback)).totalBytes, 0);
      await PlaybackTemporaryFiles.clearUnused(playback);
      expect(await file.readAsBytes(), [1, 2, 3]);
      final link = await Link('${root.path}/linked-root').create(external.path);
      expect(await directoryFileBytes(Directory(link.path)), isNull);
      expect(
        (await PlaybackTemporaryFiles.measure(Directory(link.path))).totalBytes,
        isNull,
      );
      await expectLater(
        PlaybackTemporaryFiles.allocate(Directory(link.path)),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        PlaybackTemporaryFiles.clearUnused(Directory(link.path)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
      // A failed maintenance operation must not poison the next allocation.
      final session = await PlaybackTemporaryFiles.allocate(playback);
      PlaybackTemporaryFiles.released(session);
    },
  );
}
