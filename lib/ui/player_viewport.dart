import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

/// The viewport follows available space; native video gravity controls cropping.
class PlayerViewport extends StatelessWidget {
  const PlayerViewport({
    super.key,
    required this.controller,
    required this.playerKey,
  });
  final BetterPlayerController controller;
  final GlobalKey playerKey;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth > 0 && constraints.maxHeight > 0) {
        controller.setOverriddenAspectRatio(
          constraints.maxWidth / constraints.maxHeight,
        );
      }
      return BetterPlayer(key: playerKey, controller: controller);
    },
  );
}
