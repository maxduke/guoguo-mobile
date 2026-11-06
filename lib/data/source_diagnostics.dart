import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/source_diagnostic.dart';

class SourceDiagnostics extends ChangeNotifier {
  SourceDiagnostics({required this.now});
  final DateTime Function() now;
  static const limit = 64;
  final _samples = <SourceDiagnostic>[];
  bool _closed = false;
  List<SourceDiagnostic> get samples => List.unmodifiable(_samples);

  SourceDiagnostic? latestFor(DramaSource source) {
    SourceDiagnostic? latest;
    for (final sample in _samples) {
      if (sample.source != source ||
          sample.background ||
          sample.result == 'cancelled' ||
          sample.method == 'suggestions') {
        continue;
      }
      if (latest == null || sample.at.isAfter(latest.at)) latest = sample;
    }
    return latest;
  }

  void add(SourceDiagnostic sample) {
    if (_closed) return;
    _samples.insert(0, sample);
    if (_samples.length > limit) _samples.removeLast();
    notifyListeners();
  }

  void cached(DramaSource source, String method, {int page = 1}) => add(
    SourceDiagnostic(
      source: source,
      method: method,
      at: now(),
      elapsedMs: 0,
      page: page,
      cacheHits: 1,
      networkAttempts: 0,
      stage: 'cache',
      requestResult: 'not_requested',
    ),
  );

  void clear({DramaSource? source}) {
    if (_closed) return;
    if (source == null) {
      _samples.clear();
    } else {
      _samples.removeWhere((sample) => sample.source == source);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _samples.clear();
    super.dispose();
  }
}
