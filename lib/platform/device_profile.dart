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
