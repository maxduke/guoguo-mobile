import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/app_store.dart';
import 'package:guoguo_mobile/data/record_backup_codec.dart';
import 'package:guoguo_mobile/data/startup_record_recovery.dart';
import 'package:guoguo_mobile/data/storage.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/user_input_exception.dart';

import 'download_recovery_test.dart' show PlanProvider;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppFileStorage storage;
  late StartupRecordRecovery recovery;
  late File original, cache, download;
  final damaged = <int>[123, 34, 98, 255, 0];
  const drama = Drama(
    id: 'saved',
    source: DramaSource.hongguo,
    title: '备份中的收藏',
  );
  final backup = RecordBackup([drama], []);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('startup-record-recovery-');
    final directory = await Directory('${root.path}/records').create();
    storage = AppFileStorage(directory);
    recovery = StartupRecordRecovery(storage);
    original = await File(
      '${directory.path}/records.json',
    ).writeAsBytes(damaged);
    cache = await File(
      '${directory.path}/catalog-cache.json',
    ).writeAsString('cache bytes');
    download = await File(
      '${root.path}/download.mp4',
    ).writeAsString('saved media');
  });
  tearDown(() => root.delete(recursive: true));

  Future<List<File>> archives() async => Directory(
    '${storage.directory.path}/recovery',
  ).list(recursive: true).where((e) => e is File).cast<File>().toList();

  for (final fresh in [true, false]) {
    test(
      '${fresh ? 'fresh records' : 'backup restore'} preserves exact original and leaves cache/media intact',
      () async {
        if (fresh) {
          await recovery.startFresh();
        } else {
          await recovery.restore(backup);
        }
        expect(await (await archives()).single.readAsBytes(), damaged);
        final app = AppStore(storage: storage, provider: PlanProvider());
        addTearDown(app.dispose);
        await app.load();
        expect(app.records.favorites.length, fresh ? 0 : 1);
        if (!fresh) expect(app.records.favorites.values.single.key, drama.key);
        expect(await cache.readAsString(), 'cache bytes');
        expect(await download.readAsString(), 'saved media');
      },
    );
  }

  test(
    'export preserves raw damaged bytes without replacing the original',
    () async {
      final copy = await recovery.preserve();
      expect(await copy.readAsBytes(), damaged);
      expect(await original.readAsBytes(), damaged);
    },
  );

  test(
    'failed atomic write leaves both original and preserved copy recoverable',
    () async {
      final collision = await Directory('${original.path}.tmp').create();
      await expectLater(
        recovery.restore(backup),
        throwsA(isA<FileSystemException>()),
      );
      expect(await original.readAsBytes(), damaged);
      expect(await (await archives()).single.readAsBytes(), damaged);
      await collision.delete();
      await recovery.startFresh();
      expect(await archives(), hasLength(2));
      expect(
        jsonDecode(await original.readAsString())['records']['favorites'],
        isEmpty,
      );
    },
  );

  test(
    'incompatible backup never touches the original or creates recovery files',
    () async {
      final invalid = RecordBackup([drama], [], seasonReminders: []);
      invalid.favorites.addAll(List.filled(RecordBackup.maxRecords, drama));
      await expectLater(
        recovery.restore(invalid),
        throwsA(isA<UserInputException>()),
      );
      expect(await original.readAsBytes(), damaged);
      expect(
        await Directory('${storage.directory.path}/recovery').exists(),
        isFalse,
      );
    },
  );

  test('failure to preserve the original prevents replacement', () async {
    await original.delete();
    await Directory(original.path).create();
    await expectLater(
      recovery.startFresh(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await Directory(original.path).exists(), isTrue);
    expect(await File('${original.path}.tmp').exists(), isFalse);
  });

  test(
    'record writes and recovery copies share one serialization boundary',
    () async {
      final restoring = recovery.restore(backup);
      final resetting = recovery.startFresh();
      await Future.wait([restoring, resetting]);
      final copies = await archives();
      expect(copies, hasLength(2));
      final bodies = await Future.wait(copies.map((f) => f.readAsBytes()));
      expect(bodies.any((body) => body.length == damaged.length), isTrue);
      final valid = bodies.singleWhere((body) => body.length != damaged.length);
      expect(
        jsonDecode(utf8.decode(valid))['records']['favorites'],
        hasLength(1),
      );
      expect(
        jsonDecode(await original.readAsString())['records']['favorites'],
        isEmpty,
      );
    },
  );

  test(
    'background backup validation preserves the v2 contract and rejects invalid UTF-8',
    () async {
      final parsed = await decodeRecordBackupBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(backup.toJson()))),
      );
      expect(parsed.favorites.single.key, drama.key);
      for (final bytes in [
        damaged,
        utf8.encode('{"format":"guoguo.records","version":1}'),
      ]) {
        await expectLater(
          decodeRecordBackupBytes(Uint8List.fromList(bytes)),
          throwsA(isA<UserInputException>()),
        );
      }
    },
  );
}
