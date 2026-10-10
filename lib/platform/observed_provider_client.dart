import '../data/source_diagnostics.dart';
import '../domain/models.dart';
import '../domain/source_diagnostic.dart';
import 'provider_client.dart';

class ObservedProviderClient implements DecodingProviderClient {
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
  ]) => _observe(method, arguments, (result) => result);

  @override
  Future<T> callDecoded<T>(
    String method,
    Map<String, dynamic> arguments,
    T Function(Map<String, dynamic>) decode, {
    DramaSource? source,
  }) => _observe(method, arguments, decode, source: source, validate: true);

  Future<T> _observe<T>(
    String method,
    Map<String, dynamic> arguments,
    T Function(Map<String, dynamic>) decode, {
    DramaSource? source,
    bool validate = false,
  }) async {
    if (!SourceDiagnostic.methods.contains(method)) {
      return decode(await delegate.call(method, arguments));
    }
    final started = diagnostics.now(), watch = Stopwatch()..start();
    Map<String, dynamic>? result;
    Object? requestFailure;
    bool? valid;
    try {
      try {
        result = await delegate.call(method, arguments);
      } catch (error) {
        requestFailure = error;
        rethrow;
      }
      // The exact parser used by callers runs once, inside the observation.
      // A parser failure preserves the successful core request's counters.
      try {
        final decoded = decode(result);
        if (validate) valid = true;
        return decoded;
      } catch (_) {
        if (validate) valid = false;
        rethrow;
      }
    } finally {
      final native = requestFailure is ProviderException
          ? requestFailure.diagnostic
          : result?['_diagnostic'];
      SourceDiagnostic? sample;
      if (native is Map) {
        try {
          sample = SourceDiagnostic.fromJson(native);
        } catch (_) {
          // Diagnostics must never turn an available response into a failure.
        }
      }
      source ??= sourceFor(method, arguments);
      if (sample?.method != method ||
          (source != null && sample?.source != source)) {
        sample = null;
      }
      if (sample == null && source != null) {
        sample = SourceDiagnostic(
          source: source,
          method: method,
          at: started,
          elapsedMs: watch.elapsedMilliseconds,
          page: arguments['page'] is int ? arguments['page'] as int : 1,
          refresh: arguments['refresh'] == true,
          background: arguments['background'] == true,
          result: requestFailure == null ? 'success' : 'failed',
          failure: requestFailure == null ? '' : 'other',
          stage: requestFailure is FormatException ? 'response' : 'unknown',
        );
      }
      if (sample != null) {
        diagnostics.add(
          valid == null ? sample : sample.withValidation(valid: valid),
        );
      }
    }
  }
}
