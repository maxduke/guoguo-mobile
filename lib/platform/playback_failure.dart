import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'cast_session.dart';
import 'episode_buffer.dart';
import 'provider_client.dart';

class LocalEpisodeUnavailable extends ProviderException {
  const LocalEpisodeUnavailable() : super('此分集尚未下载，请联网后播放');
}

enum PlaybackFailureKind {
  playback,
  network,
  localUnavailable,
  cancelled,
  airPlayRoute,
  airPlayReturn,
}

/// User-facing guidance, independent of native exception text and payloads.
class PlaybackFailure {
  const PlaybackFailure(
    this.message, {
    this.kind = PlaybackFailureKind.playback,
    bool autoRecover = true,
  }) : _autoRecover = autoRecover;

  final String message;
  final PlaybackFailureKind kind;
  final bool _autoRecover;
  bool get autoRecover =>
      _autoRecover &&
      (kind == PlaybackFailureKind.playback ||
          kind == PlaybackFailureKind.network);

  static const _cancelled = PlaybackFailure(
    '准备已取消，请重试或选择其他分集',
    kind: PlaybackFailureKind.cancelled,
  );
  static const _network = PlaybackFailure(
    '视频连接失败，请检查网络后重试',
    kind: PlaybackFailureKind.network,
  );

  factory PlaybackFailure.from(Object error) {
    if (error is LocalEpisodeUnavailable) {
      return const PlaybackFailure(
        '此分集未下载或文件已不存在，请下载后再播放',
        kind: PlaybackFailureKind.localUnavailable,
      );
    }
    if (error is EpisodeCancelled || error is CastCancelled) return _cancelled;
    if (error is PlatformException && error.code == 'airplay_route') {
      return const PlaybackFailure(
        'AirPlay 仍连接电视，请选择 iPhone 后播放',
        kind: PlaybackFailureKind.airPlayRoute,
      );
    }
    if (error is TimeoutException ||
        error is SocketException ||
        error is HttpException) {
      return _network;
    }
    if (error is ProviderException) {
      // Match our own bounded core messages, and never render the surrounding
      // fallback errors, response body, media URL or device identifiers.
      if (error.message.contains('红果播放设备注册失败')) {
        return const PlaybackFailure(
          '红果播放连接暂未就绪，请稍后重试',
          kind: PlaybackFailureKind.network,
        );
      }
      if (error.message.contains('红果 App 接口未返回有效数据')) {
        return const PlaybackFailure('红果暂未返回播放资源，请稍后重试');
      }
      if (error.message.contains('红果 App 未返回兼容的媒体') ||
          error.message.contains('红果 App 播放信息格式异常')) {
        return const PlaybackFailure('红果暂未提供可播放资源，请重试或切换分集');
      }
      // Preserve known actionable messages; upstream exception text is not UI.
      return switch (error.message) {
        '已取消准备' => _cancelled,
        '视频传输失败，请检查网络后重试' || '视频准备超时，请重试' => _network,
        '存储空间不足，请清理空间后重试' => const PlaybackFailure(
          '手机存储空间不足，请清理后重试',
          autoRecover: false,
        ),
        '视频链接已失效或访问被拒绝，请重试以重新获取链接' => const PlaybackFailure(
          '播放链接已失效，请重试以重新获取视频',
        ),
        '视频处理组件不兼容（参数错误），请更新应用' ||
        '站源组件未安装，请安装包含站源核心的完整版本' ||
        '站源组件版本不匹配，请安装最新完整版本' => const PlaybackFailure(
          '播放组件不可用，请更新至完整版本后再播放',
          autoRecover: false,
        ),
        '站源组件尚未就绪，请稍候或重试站源连接' || '站源连接暂未就绪，请重试' => const PlaybackFailure(
          '站源连接尚未就绪，请返回首页重试连接',
          autoRecover: false,
        ),
        _ => const PlaybackFailure('播放资源暂时不可用，请重试或切换分集'),
      };
    }
    return const PlaybackFailure('视频暂时无法播放，请重试或切换分集');
  }
}
