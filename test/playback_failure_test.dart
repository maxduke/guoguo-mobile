import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guoguo_mobile/platform/cast_session.dart';
import 'package:guoguo_mobile/platform/episode_buffer.dart';
import 'package:guoguo_mobile/platform/playback_failure.dart';
import 'package:guoguo_mobile/platform/provider_client.dart';

void main() {
  test(
    'unavailable files, cancellation and AirPlay require explicit action',
    () {
      final missing = PlaybackFailure.from(const LocalEpisodeUnavailable());
      expect(missing.kind, PlaybackFailureKind.localUnavailable);
      expect(missing.autoRecover, false);
      for (final cancelled in [
        EpisodeCancelled(),
        const CastCancelled(),
        const ProviderException('已取消准备'),
      ]) {
        final failure = PlaybackFailure.from(cancelled);
        expect(failure.kind, PlaybackFailureKind.cancelled);
        expect(failure.autoRecover, false);
      }
      final route = PlaybackFailure.from(
        PlatformException(
          code: 'airplay_route',
          message: 'private native details',
        ),
      );
      expect(route.kind, PlaybackFailureKind.airPlayRoute);
      expect(route.autoRecover, false);
      expect(route.message, contains('选择 iPhone'));
    },
  );

  test(
    'transport failures share network guidance without technical payloads',
    () {
      for (final error in [
        TimeoutException('private timeout'),
        const SocketException('private host'),
        const HttpException('private response'),
        const ProviderException('视频传输失败，请检查网络后重试'),
      ]) {
        final failure = PlaybackFailure.from(error);
        expect(failure.kind, PlaybackFailureKind.network);
        expect(failure.autoRecover, true);
        expect(failure.message, '视频连接失败，请检查网络后重试');
      }
    },
  );

  test('unknown provider, native and parsing errors use bounded guidance', () {
    for (final error in [
      const ProviderException('https://private.test/?key=secret'),
      PlatformException(
        code: 'native',
        message: 'secret',
        details: {'url': 'https://private.test'},
      ),
      const FormatException('secret payload'),
      StateError('secret state'),
    ]) {
      final failure = PlaybackFailure.from(error);
      expect(failure.message, isNot(contains('secret')));
      expect(failure.message, isNot(contains('private.test')));
      expect(failure.message, contains('重试'));
    }
  });

  test('known storage and component failures retain actionable guidance', () {
    final storage = PlaybackFailure.from(
      const ProviderException('存储空间不足，请清理空间后重试'),
    );
    expect(storage.message, contains('存储空间不足'));
    expect(storage.autoRecover, false);
    final component = PlaybackFailure.from(
      const ProviderException('站源组件未安装，请安装包含站源核心的完整版本'),
    );
    expect(component.message, contains('完整版本'));
    expect(component.autoRecover, false);
    final expired = PlaybackFailure.from(
      const ProviderException('视频链接已失效或访问被拒绝，请重试以重新获取链接'),
    );
    expect(expired.message, contains('重新获取视频'));
    expect(expired.autoRecover, true);
  });
}
