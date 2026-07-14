import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../providers/playback_controller.dart';
import '../services/music_video_player.dart';

/// Reproducción del music video a pantalla completa con controles.
///
/// Usa el MISMO `VideoPlayerController` compartido de [MusicVideoPlayer] —
/// no crea uno nuevo, así el video y el audio siguen sincronizados con el
/// resto de la app. Los controles (play/pause, seek) van contra el
/// [PlaybackController] (que enruta el seek al video vía el seekEvents que
/// ya conecta el service).
///
/// Al entrar fuerza orientación libre (permite landscape) + oculta la
/// system UI (immersive). Al salir restaura ambas.
class VideoFullscreenScreen extends StatefulWidget {
  const VideoFullscreenScreen({super.key});

  @override
  State<VideoFullscreenScreen> createState() => _VideoFullscreenScreenState();
}

class _VideoFullscreenScreenState extends State<VideoFullscreenScreen> {
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // Landscape + immersive. Permitimos ambas orientaciones (el usuario
    // puede querer portrait para videos verticales).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // Restaurar UI del sistema + orientación normal (la app es
    // primariamente portrait pero no forzamos — dejamos que el sistema
    // decida como antes).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<MusicVideoPlayer>();
    final controller = svc.controller;
    final pb = context.watch<PlaybackController>();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ─────────── El video ───────────
            if (controller != null && controller.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // ─────────── Overlay de controles ───────────
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _Controls(
                  playback: pb,
                  controller: controller,
                  onSeekInteract: _scheduleHide,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.playback,
    required this.controller,
    required this.onSeekInteract,
  });

  final PlaybackController playback;
  final VideoPlayerController? controller;
  final VoidCallback onSeekInteract;

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final song = playback.currentSong;
    return Container(
      // Scrim degradado arriba y abajo para legibilidad de los controles
      // sobre cualquier frame del video.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x99000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0xB3000000),
          ],
          stops: [0.0, 0.25, 0.6, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar: cerrar fullscreen + título.
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close_fullscreen_rounded,
                      color: Colors.white),
                  tooltip: 'Salir de pantalla completa',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        song?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),

            const Spacer(),

            // Centro: transporte prev / play-pause / next.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 40,
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: playback.previous,
                ),
                const SizedBox(width: 24),
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.white24,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    iconSize: 52,
                    color: Colors.white,
                    icon: Icon(playback.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                    onPressed: playback.togglePlayPause,
                  ),
                ),
                const SizedBox(width: 24),
                IconButton(
                  iconSize: 40,
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: playback.next,
                ),
              ],
            ),

            const Spacer(),

            // Scrubber + tiempos. Position desde el ValueNotifier del
            // playback (audio manda el reloj); el seek se enruta al video
            // por el seekEvents que ya conecta MusicVideoPlayer.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ValueListenableBuilder<Duration>(
                valueListenable: playback.positionNotifier,
                builder: (context, pos, _) {
                  final dur = playback.duration;
                  final max =
                      dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);
                  final val = pos.inMilliseconds.toDouble().clamp(0.0, max);
                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: val,
                          max: max,
                          onChanged: (v) {
                            onSeekInteract();
                            playback.seek(Duration(milliseconds: v.round()));
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_fmt(pos),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            Text(_fmt(dur),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
