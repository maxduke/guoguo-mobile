import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps native seek completion separate from play/pause commands. The iOS
/// dependency restores a captured play state after seekTo, so the app uses its
/// corrected native endpoint and leaves current viewer intent with AVPlayer.
class PlaybackSeek {
  static const _channel = MethodChannel('better_player_channel');

  static Future<Duration> to(
    BetterPlayerController player,
    String path,
    Duration target, {
    required bool Function() current,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      await player.seekTo(target);
      return target;
    }
    final duration = player.videoPlayerController?.value.duration;
    var bounded = target < Duration.zero ? Duration.zero : target;
    if (duration != null && duration > Duration.zero && bounded > duration) {
      bounded = duration;
    }
    final position = await _channel.invokeMethod<int>('guoguoSeek', {
      'uri': path.startsWith('http') ? path : 'file://$path',
      'location': bounded.inMilliseconds,
    });
    if (position == null) throw PlatformException(code: 'seek_failed');
    final actual = Duration(milliseconds: position);
    if (current()) {
      final video = player.videoPlayerController;
      if (video != null) video.value = video.value.copyWith(position: actual);
      player.cancelNextVideoTimer();
    }
    return actual;
  }
}
