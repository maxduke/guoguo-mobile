import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import '../data/source_diagnostics.dart';
import '../domain/models.dart';
import '../domain/source_diagnostic.dart';
import 'provider_client.dart';

Future<void> probeCover(
  ProviderClient provider,
  SourceDiagnostics diagnostics,
  Drama drama,
) async {
  final started = diagnostics.now();
  final response = await provider.call('cover', {
    'id': drama.id,
    'source': drama.source.name,
    'url': drama.cover,
    'timeoutMs': 12000,
  });
  final sample =
      diagnostics.samples
          .where(
            (s) =>
                s.source == drama.source &&
                s.method == 'cover' &&
                !s.at.isBefore(started),
          )
          .firstOrNull ??
      SourceDiagnostic(
        source: drama.source,
        method: 'cover',
        at: started,
        elapsedMs: 0,
      );
  ui.Codec? codec;
  Uint8List bytes;
  try {
    bytes = base64Decode(response['data'] as String);
  } catch (_) {
    diagnostics.add(sample.withValidation(valid: false));
    return;
  }
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 600,
      targetHeight: 600,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    diagnostics.add(sample.withValidation(valid: true));
  } catch (_) {
    diagnostics.add(
      sample.withValidation(valid: false, failureStage: 'image_decode'),
    );
  } finally {
    codec?.dispose();
  }
}
