// Host-only AOT benchmark: dart compile exe scripts/benchmark_record_backup.dart -o /tmp/guoguo-backup-benchmark
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:guoguo_mobile/data/record_backup_codec.dart';
import 'package:guoguo_mobile/domain/models.dart';

Future<void> measure(
  String name,
  FutureOr<RecordBackup> Function() action,
) async {
  final clock = Stopwatch()..start();
  var last = clock.elapsedMicroseconds, gap = 0;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = clock.elapsedMicroseconds;
    if (now - last > gap) gap = now - last;
    last = now;
  });
  await Future<void>.delayed(const Duration(milliseconds: 20));
  gap = 0;
  final work = Stopwatch()..start();
  final result = await action();
  final elapsed = work.elapsedMicroseconds;
  await Future<void>.delayed(const Duration(milliseconds: 20));
  heartbeat.cancel();
  stdout.writeln(
    '$name records=${result.favorites.length} elapsedUs=$elapsed maxEventLoopGapUs=$gap',
  );
}

Future<void> main() async {
  for (final count in [80, 25000]) {
    final raw = jsonEncode(
      RecordBackup(
        List.generate(
          count,
          (i) => Drama(
            id: '$i',
            source: DramaSource.hongguo,
            title: '故事$i',
            description: 'x' * 500,
          ),
        ),
        [],
      ).toJson(),
    );
    final bytes = Uint8List.fromList(utf8.encode(raw));
    stdout.writeln('fixture bytes=${bytes.length}');
    for (var pass = 0; pass < 3; pass++) {
      await measure('sync-$pass', () => decodeRecordBackup(utf8.decode(bytes)));
      await measure('selected-$pass', () => decodeRecordBackupBytes(bytes));
    }
  }
}
