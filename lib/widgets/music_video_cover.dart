import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/music_video_player.dart';

/// Dibuja el music video de la canción actual en el área de cover del
/// PlayerScreen. El controller es ÚNICO y compartido vía [MusicVideoPlayer];
/// este widget solo lo pinta. El play/pause/seek se sincronizan con el audio
/// dentro del service.
class MusicVideoCover extends StatelessWidget {
  const MusicVideoCover({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<MusicVideoPlayer>();
    final c = svc.controller;
    if (c == null || !c.value.isInitialized) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
