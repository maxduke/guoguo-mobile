import 'dart:io';
import 'package:flutter/services.dart';

Future<bool> isAndroidTelevision() async {
  if (!Platform.isAndroid) return false;
  try {
    return await const MethodChannel('guoguo/device')
            .invokeMethod<bool>('isTelevision')
            .timeout(const Duration(seconds: 2), onTimeout: () => false) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Local troubleshooting fields only; never forward arbitrary channel payloads.
Future<Map<String, Object?>> playbackDeviceInfo() async {
  try {
    final raw = await const MethodChannel('guoguo/device')
        .invokeMapMethod<String, dynamic>('playbackDeviceInfo')
        .timeout(const Duration(seconds: 2));
    if (raw == null) return const {};
    final result = <String, Object?>{};
    for (final key in [
      'manufacturer',
      'model',
      'androidVersion',
      'applicationId',
      'version',
    ]) {
      final value = raw[key];
      if (value is String) {
        result[key] = value.length <= 128 ? value : value.substring(0, 128);
      }
    }
    for (final key in ['apiLevel', 'build']) {
      if (raw[key] is int) result[key] = raw[key];
    }
    if (raw['television'] is bool) result['television'] = raw['television'];
    if (raw['abis'] is List) {
      result['abis'] = (raw['abis'] as List)
          .whereType<String>()
          .where((value) => value.length <= 32)
          .take(8)
          .toList();
    }
    if (const {'automatic', 'legacy-opengl'}.contains(raw['renderingPolicy'])) {
      result['renderingPolicy'] = raw['renderingPolicy'];
    }
    return Map.unmodifiable(result);
  } catch (_) {
    return const {};
  }
}
