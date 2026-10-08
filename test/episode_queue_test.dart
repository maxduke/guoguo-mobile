import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/domain/episode_queue.dart';

void main() {
  test(
    'catalog queue uses neighboring slots, with safe missing/end bounds',
    () {
      expect(nextAdjacentEpisodeIndex(-1, 3), isNull);
      expect(nextAdjacentEpisodeIndex(0, 0), isNull);
      expect(nextAdjacentEpisodeIndex(0, 3), 1);
      expect(nextAdjacentEpisodeIndex(2, 3), isNull);
    },
  );

  test('download queue advances only across consecutive original slots', () {
    expect(nextAdjacentEpisodeIndex(0, 3, episodeIndices: [4, 5, 9]), 1);
    expect(nextAdjacentEpisodeIndex(1, 3, episodeIndices: [4, 5, 9]), isNull);
    expect(nextAdjacentEpisodeIndex(2, 3, episodeIndices: [4, 5, 9]), isNull);
    expect(nextAdjacentEpisodeIndex(0, 2, episodeIndices: [4, 4]), isNull);
    expect(nextAdjacentEpisodeIndex(0, 2, episodeIndices: [4, 3]), isNull);
  });
}
