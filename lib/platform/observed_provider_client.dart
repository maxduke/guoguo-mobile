import '../data/source_diagnostics.dart';
import '../domain/models.dart';
import '../domain/source_diagnostic.dart';
import 'provider_client.dart';

class ObservedProviderClient implements ProviderClient {
  ObservedProviderClient(this.delegate, this.diagnostics);
  final ProviderClient delegate;
  final SourceDiagnostics diagnostics;

  static DramaSource? sourceFor(String method, Map<String, dynamic> arguments) {
    if (method == 'recommendations') return DramaSource.hongguo;
    for (final source in DramaSource.values) {
      final id = arguments['id'], board = arguments['board'];
      if (arguments['source'] == source.name ||
          (id is String &&
              (id.startsWith('${source.name}:') ||
                  id.startsWith('web:${source.name}:'))) ||
          (board is String && board.startsWith('${source.name}-'))) {
        return source;
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (!SourceDiagnostic.methods.contains(method)) {
      return delegate.call(method, arguments);
    }
    final started = diagnostics.now(), watch = Stopwatch()..start();
    Map<String, dynamic>? result;
    Object? failure;
    try {
      result = await delegate.call(method, arguments);
      return result;
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      final native = failure is ProviderException
          ? failure.diagnostic
          : result?['_diagnostic'];
      SourceDiagnostic? sample;
      if (native is Map) {
        try {
          sample = SourceDiagnostic.fromJson(native);
        } catch (_) {
          // Diagnostics must never turn an available response into a failure.
        }
      }
      final source = sourceFor(method, arguments);
      if (sample?.method != method ||
          (source != null && sample?.source != source)) {
        sample = null;
      }
      if (sample != null) {
        diagnostics.add(sample);
      } else if (source != null) {
        diagnostics.add(
          SourceDiagnostic(
            source: source,
            method: method,
            at: started,
            elapsedMs: watch.elapsedMilliseconds,
            page: arguments['page'] is int ? arguments['page'] as int : 1,
            refresh: arguments['refresh'] == true,
            background: arguments['background'] == true,
            result: failure == null ? 'success' : 'failed',
            failure: failure == null ? '' : 'other',
            stage: failure is FormatException ? 'response' : 'unknown',
          ),
        );
      }
    }
  }
}
