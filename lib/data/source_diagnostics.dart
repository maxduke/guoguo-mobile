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

  void clear() {
    if (_closed) return;
    _samples.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _samples.clear();
    super.dispose();
  }
}
