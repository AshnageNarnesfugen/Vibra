import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/ambient_video_palette_service.dart';
import '../services/music_video_player.dart';

/// Capa de fondo que muestra el music video de la canción actual.
///
/// Comparte el `VideoPlayerController` con [MusicVideoCover] vía
/// [MusicVideoPlayer]: una sola decoder/textura GPU pintada en dos lugares.
/// Antes había dos controllers independientes — desincronización y "el video
/// del cover sigue corriendo aunque pausas el de fondo" eran síntomas de eso.
///
/// **Ambient mode**: el `RepaintBoundary` con `_videoKey` es lo que el
/// `AmbientVideoPaletteService` captura periódicamente para extraer los
/// colores de las esquinas y filtrarlos al resto de la UI. Sin él, el
/// `toImage()` capturaría todo el árbol del Stack (con tinte, noise, etc.)
/// y los colores quedarían contaminados.
class MusicVideoBackgroundLayer extends StatefulWidget {
  const MusicVideoBackgroundLayer({super.key});

  @override
  State<MusicVideoBackgroundLayer> createState() =>
      _MusicVideoBackgroundLayerState();
}

class _MusicVideoBackgroundLayerState extends State<MusicVideoBackgroundLayer> {
  final GlobalKey _videoKey = GlobalKey(debugLabel: 'ambient-video-boundary');
  AmbientVideoPaletteService? _ambient;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<AmbientVideoPaletteService?>();
    if (_ambient != next) {
      _ambient?.unregisterVideoKey(_videoKey);
      _ambient = next;
      next?.registerVideoKey(_videoKey);
    }
  }

  @override
  void dispose() {
    _ambient?.unregisterVideoKey(_videoKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<MusicVideoPlayer>();
    final c = svc.controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return RepaintBoundary(
      key: _videoKey,
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      ),
    );
  }
}
