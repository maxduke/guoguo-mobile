import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/device_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('guoguo/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'playback device info forwards only bounded troubleshooting fields',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'playbackDeviceInfo');
        return {
          'manufacturer': 'Fixture',
          'model': 'TV 9',
          'androidVersion': '10',
          'apiLevel': 29,
          'build': 55,
          'version': '0.20.3-dev',
          'abis': ['armeabi-v7a', 32],
          'applicationId': 'com.maxduke.guoguo_mobile.dev',
          'renderingPolicy': 'legacy-opengl',
          'television': true,
          'url': 'https://private.example/media?token=secret',
          'contentKey': 'secret',
        };
      });
      final info = await playbackDeviceInfo();
      expect(info['apiLevel'], 29);
      expect(info['build'], 55);
      expect(info['renderingPolicy'], 'legacy-opengl');
      expect(info['abis'], ['armeabi-v7a']);
      expect(info, isNot(contains('url')));
      expect(info, isNot(contains('contentKey')));
    },
  );

  test(
    'unavailable device channel does not expose exception contents',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'failed',
          message: 'https://private.example/?token=secret',
        );
      });
      expect(await playbackDeviceInfo(), isEmpty);
    },
  );
}
