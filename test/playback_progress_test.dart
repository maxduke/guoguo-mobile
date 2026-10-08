import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/platform/playback_progress.dart';

void main() {
  const drama = Drama(
    id: 'fixture',
    source: DramaSource.hongguo,
    title: '观看进度',
  );
  final episodes = [
    Episode.fromJson({'id': 'one', 'currentEpisode': 8}, 0),
    Episode.fromJson({'id': 'two', 'currentEpisode': 12}, 1),
  ];
  late DateTime now;
  late List<WatchRecord> records;
  late PlaybackProgressController progress;

  setUp(() {
    now = DateTime.utc(2026, 10, 8);
    records = [];
    progress = PlaybackProgressController(
      drama: drama,
      episodes: episodes,
      initialIndex: 0,
      episodeIndices: [5, 9],
      now: () => now,
      saveWatch: (record) async => records.add(record),
    );
  });

  test('selection preserves true identity and resets only a new episode', () {
    progress.completed = true;
    progress.select(0);
    progress.save(const Duration(seconds: 120), const Duration(seconds: 120));
    progress.select(1);
    progress.save(const Duration(seconds: 7), const Duration(seconds: 90));
    expect(records.first.episodeId, 'one');
    expect(records.first.episodeIndex, 5);
    expect(records.first.episodeNumber, 8);
    expect(records.first.episodeCompleted, true);
    expect(progress.index, 1);
    expect(records.last.episodeId, 'two');
    expect(records.last.episodeIndex, 9);
    expect(records.last.episodeNumber, 12);
    expect(records.last.episodeCompleted, false);
  });

  test('periodic saves share a limit while transitions save immediately', () {
    progress.save(Duration.zero, const Duration(seconds: 120), force: false);
    now = now.add(const Duration(seconds: 9));
    progress.save(
      const Duration(seconds: 9),
      const Duration(seconds: 120),
      force: false,
    );
    expect(records, hasLength(1));
    progress.completed = true;
    progress.save(const Duration(seconds: 120), const Duration(seconds: 120));
    expect(records, hasLength(2));
    now = now.add(const Duration(seconds: 9));
    progress.save(
      const Duration(seconds: 120),
      const Duration(seconds: 120),
      force: false,
    );
    expect(records, hasLength(2));
    now = now.add(const Duration(seconds: 1));
    progress.save(
      const Duration(seconds: 120),
      const Duration(seconds: 120),
      force: false,
    );
    expect(records, hasLength(3));
    expect(records.last.updatedAt, now);
  });

  test('unknown duration and reaching the end do not imply completion', () {
    progress.save(const Duration(seconds: 3), Duration.zero);
    progress.save(const Duration(seconds: 120), const Duration(seconds: 120));
    expect(records.first.durationMs, 0);
    expect(records.first.positionMs, 3000);
    expect(records.every((record) => !record.episodeCompleted), true);
  });

  test(
    'pending writes retain the episode and completion captured at save',
    () async {
      final gate = Completer<void>();
      progress = PlaybackProgressController(
        drama: drama,
        episodes: episodes,
        initialIndex: 0,
        saveWatch: (record) async {
          await gate.future;
          records.add(record);
        },
      );
      progress.completed = true;
      progress.save(const Duration(seconds: 120), const Duration(seconds: 120));
      progress.select(1);
      progress.save(const Duration(seconds: 5), const Duration(seconds: 120));
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(records.first.episodeId, 'one');
      expect(records.first.episodeIndex, 0);
      expect(records.first.episodeCompleted, true);
      expect(records.last.episodeId, 'two');
      expect(records.last.episodeIndex, 1);
      expect(records.last.episodeCompleted, false);
    },
  );

  test('a persistence failure permits the next periodic save', () async {
    var attempts = 0;
    progress = PlaybackProgressController(
      drama: drama,
      episodes: episodes,
      initialIndex: 0,
      now: () => now,
      saveWatch: (record) async {
        if (++attempts == 1) throw StateError('storage unavailable');
        records.add(record);
      },
    );
    progress.save(const Duration(seconds: 1), const Duration(seconds: 120));
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(seconds: 10));
    progress.save(
      const Duration(seconds: 11),
      const Duration(seconds: 120),
      force: false,
    );
    expect(attempts, 2);
    expect(records.single.positionMs, 11000);
  });
}
