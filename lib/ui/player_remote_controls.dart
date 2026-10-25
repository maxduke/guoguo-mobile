import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PlayerRemoteControls extends StatelessWidget {
  const PlayerRemoteControls({
    super.key,
    required this.enabled,
    required this.controlsVisible,
    required this.onShowControls,
    required this.onPlayPause,
    required this.onSeekBy,
    required this.onPrevious,
    required this.onNext,
    required this.child,
    this.playing = false,
  });
  final bool enabled, controlsVisible, playing;
  final VoidCallback onShowControls, onPlayPause;
  final VoidCallback? onPrevious, onNext;
  final ValueChanged<Duration> onSeekBy;
  final Widget child;

  @override
  Widget build(BuildContext context) => !enabled
      ? child
      : Focus(
          autofocus: enabled,
          onKeyEvent: (node, event) {
            if (!enabled || event is! KeyDownEvent) {
              return KeyEventResult.ignored;
            }
            final key = event.logicalKey;
            if ({
              LogicalKeyboardKey.mediaPlayPause,
              LogicalKeyboardKey.mediaPlay,
              LogicalKeyboardKey.mediaPause,
              LogicalKeyboardKey.space,
            }.contains(key)) {
              if (!(key == LogicalKeyboardKey.mediaPlay && playing) &&
                  !(key == LogicalKeyboardKey.mediaPause && !playing)) {
                onPlayPause();
              }
              onShowControls();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.mediaTrackNext ||
                key == LogicalKeyboardKey.mediaTrackPrevious) {
              (key == LogicalKeyboardKey.mediaTrackNext ? onNext : onPrevious)
                  ?.call();
              onShowControls();
              return KeyEventResult.handled;
            }
            if ({
              LogicalKeyboardKey.arrowLeft,
              LogicalKeyboardKey.arrowRight,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.select,
            }.contains(key)) {
              if (!controlsVisible &&
                  (key == LogicalKeyboardKey.arrowLeft ||
                      key == LogicalKeyboardKey.arrowRight)) {
                onSeekBy(
                  Duration(
                    seconds: key == LogicalKeyboardKey.arrowLeft ? -10 : 10,
                  ),
                );
              }
              onShowControls();
              return controlsVisible
                  ? KeyEventResult.ignored
                  : KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: child,
        );
}
