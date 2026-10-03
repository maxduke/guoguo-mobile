import '../domain/models.dart';
import '../domain/playback_policy.dart';
import 'playback_session.dart';
import 'provider_client.dart';

/// Owns the per-episode retry budget and the asynchronous recovery guard.
class PlaybackRecoveryController {
  PlaybackRecoveryController(this.session, this.provider);

  final PlaybackSessionController session;
  final ProviderClient provider;
  final PlaybackHealth health = PlaybackHealth();
  final PlaybackRecovery _budget = PlaybackRecovery();
  int? _generation;
  bool _closed = false;
  bool get recovering =>
      _generation != null &&
      _current(_generation!) &&
      _generation == session.generation;
  bool _current(int ticket) => !_closed && session.isCurrent(ticket);

  void reset() => _budget.reset();

  Future<void> recover(
    int index, {
    required Future<void> Function() pause,
    required void Function(RecoveryAction) onAction,
    required void Function(ResolvedMedia?) restart,
    required void Function() onFailure,
  }) async {
    final ticket = session.generation;
    if (!_current(ticket) || recovering) return;
    final media = session.peek(index)?.media;
    var action = _budget.next(alternative: media?.hasAlternative == true);
    if (action == RecoveryAction.stop) {
      onAction(action);
      return;
    }
    _generation = ticket;
    session.retain({index});
    onAction(action);
    ResolvedMedia? replacement;
    try {
      await pause();
      if (!_current(ticket)) return;
      if (action == RecoveryAction.alternative) {
        try {
          replacement = await provider.fallback(media!);
        } catch (_) {
          if (!_current(ticket)) return;
          action = _budget.next(alternative: false);
        }
      }
      if (!_current(ticket)) return;
      if (action == RecoveryAction.stop) {
        onAction(action);
      } else {
        final next = replacement;
        replacement = null;
        restart(next);
      }
    } catch (_) {
      if (_current(ticket)) onFailure();
    } finally {
      if (replacement != null) await session.releaseUnused(replacement);
      if (_generation == ticket) _generation = null;
      if (_current(ticket)) health.reset();
    }
  }

  Future<bool> compatible(int ticket, Future<bool> Function() operation) async {
    if (!_current(ticket) || recovering) return false;
    _generation = ticket;
    try {
      return await operation();
    } finally {
      if (_generation == ticket) _generation = null;
    }
  }

  void close() {
    _closed = true;
    _generation = null;
    health.reset();
  }
}
