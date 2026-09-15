import 'dart:async';

class EpisodeCancelled implements Exception {}

class EpisodeCancellation {
  bool cancelled = false;
  void Function()? onCancel;
  void check() {
    if (cancelled) throw EpisodeCancelled();
  }

  void cancel() {
    cancelled = true;
    onCancel?.call();
  }
}

class _Entry<T> {
  final cancellation = EpisodeCancellation();
  late Future<T> future;
  T? value;
}

/// Shares preparation between preload and playback; releases evicted results.
class EpisodeBuffer<T> {
  EpisodeBuffer({required this.load, required this.release});
  final Future<T> Function(int, EpisodeCancellation) load;
  final Future<void> Function(T) release;
  final Map<int, _Entry<T>> _entries = {};
  bool _closed = false;
  T? peek(int index) => _entries[index]?.value;
  bool contains(int index) => _entries.containsKey(index);
  Future<T> prepare(int index) {
    if (_closed) return Future.error(EpisodeCancelled());
    final existing = _entries[index];
    if (existing != null) return existing.future;
    final entry = _Entry<T>();
    _entries[index] = entry;
    entry.future = Future.sync(() => load(index, entry.cancellation))
        .then((value) async {
          if (entry.cancellation.cancelled || _closed) {
            await release(value);
            throw EpisodeCancelled();
          }
          entry.value = value;
          return value;
        })
        .catchError((Object error, StackTrace stack) {
          if (identical(_entries[index], entry)) _entries.remove(index);
          Error.throwWithStackTrace(error, stack);
        });
    unawaited(
      entry.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return entry.future;
  }

  void retain(Set<int> indices) {
    for (final index in _entries.keys.toList()) {
      if (!indices.contains(index)) evict(index);
    }
  }

  void evict(int index) {
    final entry = _entries.remove(index);
    if (entry == null) return;
    entry.cancellation.cancel();
    final value = entry.value;
    if (value != null) unawaited(release(value));
  }

  void close() {
    _closed = true;
    retain({});
  }
}
