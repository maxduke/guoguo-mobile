import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cast_session.dart';

/// AirPlay remains controlled by AVPlayer. The relay gives receivers a URL
/// they can fetch, including for decrypted files and authenticated HLS.
class AirPlaySession extends ChangeNotifier {
  AirPlaySession({
    required this.relayFactory,
    this.channel = const MethodChannel('guoguo/airplay'),
  }) {
    channel.setMethodCallHandler((call) async {
      if (!_closed && call.method == 'externalPlaybackChanged') {
        final args = call.arguments as Map;
        if (args['textureId'] == textureId) {
          _setState(args['active'] == true, args['routed'] == true);
        }
      }
    });
  }

  final CastRelayHandle Function() relayFactory;
  final MethodChannel channel;
  int? textureId;
  bool active = false, routed = false, preparing = false;
  bool _closed = false;
  int _revision = 0;
  Object? _sourceKey;
  String? _url;
  CastRelayHandle? _relay;
  Completer<void>? _preparationDone;
  bool _prepared = false;

  void _setState(bool external, bool route) {
    external = external && _prepared;
    route = route && _prepared;
    route = route || external;
    if (active == external && routed == route) return;
    active = external;
    routed = route;
    if (!_closed) notifyListeners();
  }

  Future<void> open({
    required Object sourceKey,
    required CastSource source,
    required Future<bool> Function(String) install,
    bool showPicker = true,
  }) async {
    if (_closed || preparing || textureId == null) return;
    preparing = true;
    final done = _preparationDone = Completer<void>();
    notifyListeners();
    final revision = _revision;
    CastRelayHandle? started;
    var installed = false;
    try {
      if (!identical(_sourceKey, sourceKey) || _url == null) {
        await _relay?.close();
        if (_closed || revision != _revision) throw const CastCancelled();
        _relay = started = relayFactory();
        final url = await started
            .start(source.media, source.localPath)
            .timeout(const Duration(seconds: 8));
        if (_closed || revision != _revision) throw const CastCancelled();
        installed = await install(url);
        if (_closed || revision != _revision || !installed) {
          throw const CastCancelled();
        }
        _sourceKey = sourceKey;
        _url = url;
      }
      _prepared = true;
      final args = {'textureId': textureId};
      final state = await channel.invokeMapMethod<String, dynamic>(
        'prepareAirPlay',
        args,
      );
      if (_closed || revision != _revision) throw const CastCancelled();
      _setState(state?['active'] == true, state?['routed'] == true);
      if (showPicker) {
        await channel.invokeMethod<void>('showAirPlayRoutes', args);
      }
    } catch (_) {
      // Once AVPlayer uses the relay, retain it even if route presentation fails.
      // Cancelled source installation has no consumer and must release it.
      if (!installed && started != null && identical(_relay, started)) {
        _relay = null;
        await started.close();
      }
      rethrow;
    } finally {
      preparing = false;
      done.complete();
      _preparationDone = null;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> reset() async {
    _revision++;
    _sourceKey = null;
    _url = null;
    _prepared = false;
    _setState(false, false);
    final relay = _relay;
    final pending = _preparationDone?.future;
    _relay = null;
    await relay?.close();
    await pending;
  }

  @override
  void dispose() {
    _closed = true;
    channel.setMethodCallHandler(null);
    unawaited(reset());
    super.dispose();
  }
}
