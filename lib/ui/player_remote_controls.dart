import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PlayerRemoteControls extends StatefulWidget {
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
    this.isPlaying,
    this.onBack,
    this.onHideControls,
  });
  final bool enabled, controlsVisible, playing;
  final ValueGetter<bool>? isPlaying;
  final VoidCallback? onBack;
  final VoidCallback? onHideControls;
  final VoidCallback onShowControls, onPlayPause;
  final VoidCallback? onPrevious, onNext;
  final ValueChanged<Duration> onSeekBy;
  final Widget child;

  @override
  State<PlayerRemoteControls> createState() => _PlayerRemoteControlsState();
}

class _PlayerRemoteControlsState extends State<PlayerRemoteControls> {
  final _focus = FocusNode(debugLabel: 'player-remote');

  @override
  void didUpdateWidget(PlayerRemoteControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled &&
        !widget.controlsVisible &&
        (!oldWidget.enabled || oldWidget.controlsVisible)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.enabled && !widget.controlsVisible) {
          _focus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop:
        !widget.enabled ||
        !widget.controlsVisible ||
        widget.onHideControls == null,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.enabled && widget.controlsVisible) {
        widget.onHideControls?.call();
      }
    },
    child: Focus(
      // Keep the video subtree mounted across menus and lifecycle changes.
      focusNode: _focus,
      canRequestFocus: widget.enabled,
      skipTraversal: true,
      autofocus: widget.enabled,
      onKeyEvent: (node, event) {
        if (!widget.enabled ||
            event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (event is KeyDownEvent &&
            widget.onBack != null &&
            {
              LogicalKeyboardKey.escape,
              LogicalKeyboardKey.goBack,
              LogicalKeyboardKey.browserBack,
            }.contains(key)) {
          widget.onBack!();
          return KeyEventResult.handled;
        }
        if ({
          LogicalKeyboardKey.mediaPlayPause,
          LogicalKeyboardKey.mediaPlay,
          LogicalKeyboardKey.mediaPause,
          LogicalKeyboardKey.space,
        }.contains(key)) {
          if (event is KeyRepeatEvent) return KeyEventResult.handled;
          final playing = widget.isPlaying?.call() ?? widget.playing;
          if (!(key == LogicalKeyboardKey.mediaPlay && playing) &&
              !(key == LogicalKeyboardKey.mediaPause && !playing)) {
            widget.onPlayPause();
          }
          widget.onShowControls();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.mediaTrackNext ||
            key == LogicalKeyboardKey.mediaTrackPrevious) {
          if (event is KeyRepeatEvent) return KeyEventResult.handled;
          (key == LogicalKeyboardKey.mediaTrackNext
                  ? widget.onNext
                  : widget.onPrevious)
              ?.call();
          widget.onShowControls();
          return KeyEventResult.handled;
        }
        if ({
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.select,
        }.contains(key)) {
          if (!widget.controlsVisible &&
              (key == LogicalKeyboardKey.arrowLeft ||
                  key == LogicalKeyboardKey.arrowRight)) {
            widget.onSeekBy(
              Duration(seconds: key == LogicalKeyboardKey.arrowLeft ? -10 : 10),
            );
          }
          widget.onShowControls();
          return widget.controlsVisible
              ? KeyEventResult.ignored
              : KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    ),
  );
}
