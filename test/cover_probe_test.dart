import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/data/source_diagnostics.dart';
import 'package:guoguo_mobile/domain/models.dart';
import 'package:guoguo_mobile/domain/source_diagnostic.dart';
import 'package:guoguo_mobile/platform/cover_probe.dart';
import 'package:guoguo_mobile/platform/observed_provider_client.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

class _Provider implements ProviderClient {
  _Provider(this.data);
  final String data;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => {'data': data, 'contentType': 'image/png'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(
    id: 'dsd:123',
    source: DramaSource.dsd,
    title: 'sample',
    cover: 'https://secret.invalid/?token=secret',
  );
  for (final response in [
    'invalid base64!',
    base64Encode(utf8.encode('<html>secret</html>')),
  ]) {
    test(
      'cover diagnostics distinguish response and image decoding failures',
      () async {
        final diagnostics = SourceDiagnostics(now: DateTime.now);
        addTearDown(diagnostics.dispose);
        await probeCover(
          ObservedProviderClient(_Provider(response), diagnostics),
          diagnostics,
          drama,
        );
        final latest = diagnostics.samples.first;
        expect(latest.method, 'cover');
        expect(latest.validation, 'failed');
        expect(latest.requestResult, 'success');
        expect(
          latest.stage,
          response.startsWith('invalid') ? 'response' : 'image_decode',
        );
        expect(SourceDiagnostic.fromJson(latest.toJson()).stage, latest.stage);
        expect(jsonEncode(latest.toJson()), isNot(contains('secret')));
      },
    );
  }
  test(
    'valid cover codec check reports success and releases its image',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff235849), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final diagnostics = SourceDiagnostics(now: DateTime.now);
      addTearDown(diagnostics.dispose);
      await probeCover(
        ObservedProviderClient(
          _Provider(base64Encode(bytes!.buffer.asUint8List())),
          diagnostics,
        ),
        diagnostics,
        drama,
      );
      expect(diagnostics.samples.first.validation, 'passed');
      expect(diagnostics.samples.first.source, DramaSource.dsd);
    },
  );
}
