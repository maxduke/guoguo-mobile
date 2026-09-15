import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/episode_buffer.dart';

void main() {
  test(
    'an old failed prefetch cannot evict a newer preparation for the same episode',
    () async {
      final old = Completer<String>();
      var calls = 0;
      final buffer = EpisodeBuffer<String>(
        load: (_, _) => ++calls == 1 ? old.future : Future.value('new'),
        release: (_) async {},
      );
      final stale = buffer.prepare(1);
      final failure = expectLater(stale, throwsStateError);
      buffer.evict(1);
      await buffer.prepare(1);
      old.completeError(StateError('old request failed'));
      await failure;
      expect(buffer.peek(1), 'new');
      buffer.close();
    },
  );
  test(
    'selection shares an unfinished prefetch and retains the previous episode',
    () async {
      var loads = 0;
      final next = Completer<String>();
      final released = <String>[];
      final buffer = EpisodeBuffer<String>(
        load: (index, token) {
          loads++;
          return index == 1 ? next.future : Future.value('episode$index');
        },
        release: (item) async {
          released.add(item);
        },
      );
      await buffer.prepare(0);
      final prefetch = buffer.prepare(1);
      final selection = buffer.prepare(1);
      expect(identical(prefetch, selection), isTrue);
      next.complete('episode1');
      expect(await selection, 'episode1');
      expect(loads, 2);
      buffer.retain({0, 1, 2});
      expect(await buffer.prepare(0), 'episode0');
      expect(loads, 2);
      buffer.close();
      expect(released, containsAll(['episode0', 'episode1']));
    },
  );
  test(
    'late evicted results are released once and cannot replace new preparation',
    () async {
      final late = Completer<String>();
      final released = <String>[];
      var loads = 0;
      final buffer = EpisodeBuffer<String>(
        load: (index, token) =>
            ++loads == 1 ? late.future : Future.value('fresh'),
        release: (item) async {
          released.add(item);
        },
      );
      final old = buffer.prepare(0);
      final failed = expectLater(old, throwsA(isA<EpisodeCancelled>()));
      buffer.evict(0);
      expect(await buffer.prepare(0), 'fresh');
      late.complete('stale');
      await failed;
      expect(buffer.peek(0), 'fresh');
      expect(released, ['stale']);
      buffer.close();
      buffer.close();
      expect(released, ['stale', 'fresh']);
    },
  );
}
