import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/watch_resume.dart';

WatchRecord record({
  bool completed = true,
  String status = '',
  String id = 'b',
}) => WatchRecord(
  drama: Drama(
    id: 'drama',
    source: DramaSource.hongguo,
    title: '示例',
    status: status,
  ),
  episodeId: id,
  episodeIndex: 99,
  episodeNumber: 6,
  episodeCompleted: completed,
  positionMs: 60000,
  durationMs: 60000,
  updatedAt: DateTime.utc(2026),
);

List<Episode> episodes() => [
  Episode.fromJson({'id': 'a', 'currentEpisode': 2}, 0),
  Episode.fromJson({'id': 'b', 'currentEpisode': 6}, 1),
  Episode.fromJson({'id': 'c', 'currentEpisode': 10}, 2),
];

void main() {
  test('100 percent alone resumes the same episode by ID', () {
    final resume = WatchResume(record(completed: false), episodes());
    expect(resume.status, WatchStatus.watching);
    expect(resume.index, 1);
    expect(resume.canContinue, true);
  });

  test(
    'confirmed completion uses catalog order and real next episode number',
    () {
      final resume = WatchResume(record(), episodes());
      expect(resume.status, WatchStatus.nextEpisode);
      expect(resume.index, 2);
      expect(resume.episode!.number, 10);
      final reordered = WatchResume(record(), [episodes()[1], episodes()[0]]);
      expect(reordered.episode!.id, 'a');
    },
  );

  test('latest episode distinguishes ongoing, finished and unknown series', () {
    for (final status in ['ongoing', 'finished', 'completed', '']) {
      final resume = WatchResume(record(id: 'c', status: status), episodes());
      expect(resume.canContinue, false);
      expect(resume.status, switch (status) {
        'ongoing' => WatchStatus.waiting,
        'finished' || 'completed' => WatchStatus.completed,
        _ => WatchStatus.episodeCompleted,
      });
      expect(
        resume.index,
        status == 'finished' || status == 'completed' ? 0 : 2,
      );
    }
  });

  test('new chapters make a completed latest episode continuable again', () {
    final saved = record(id: 'c', status: 'ongoing');
    final rows = episodes();
    expect(WatchResume(saved, rows).status, WatchStatus.waiting);
    rows.add(Episode.fromJson({'id': 'd', 'currentEpisode': 14}, 3));
    final resume = WatchResume(saved, rows);
    expect(resume.canContinue, true);
    expect(resume.episode!.id, 'd');
  });

  test('missing catalog or ID never proves a whole series is complete', () {
    for (final rows in [null, <Episode>[], episodes()]) {
      final resume = WatchResume(
        record(id: 'missing', status: 'finished'),
        rows,
      );
      expect(resume.status, WatchStatus.episodeCompleted);
      expect(resume.canContinue, false);
    }
  });
}
