// Scrubber de posición y botonera de transporte.
//
// `part` de player_screen.dart: las clases del player comparten
// estado privado entre sí, así que viven en una sola librería
// partida en archivos por concern (imports en el archivo raíz).
part of '../player_screen.dart';

class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    // Duration sólo cambia al cargar una nueva canción → lectura directa.
    // Position cambia varias veces por segundo → ValueListenableBuilder
    // aislado para que sólo este widget se reconstruya, no todo el árbol
    // de PlaybackController.
    final dur = playback.duration;
    final max = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);

    final scheme = Theme.of(context).colorScheme;
    // Active del slider: primary del album con contraste 4.5:1 garantizado.
    final activeColor = ContrastUtils.ensureReadable(
      scheme.primary,
      scheme.surface,
      target: 4.5,
    );

    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playback.positionNotifier,
        builder: (context, pos, _) {
          final value = pos.inMilliseconds.toDouble().clamp(0.0, max);
          // AdaptiveColor envuelve el slider + tiempos: el track inactivo
          // y los timestamps usan tinta adaptada al bg, así son legibles
          // tanto sobre fondos claros como oscuros.
          return AdaptiveColor(
            builder: (context, adaptive) {
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: activeColor,
                      inactiveTrackColor: adaptive.withValues(alpha: 0.30),
                      thumbColor: activeColor,
                      overlayColor: activeColor.withValues(alpha: 0.18),
                    ),
                    child: Slider(
                      value: value,
                      max: max,
                      onChanged: (v) =>
                          playback.seek(Duration(milliseconds: v.round())),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(pos),
                            style: TextStyle(
                                color:
                                    adaptive.withValues(alpha: 0.85))),
                        Text(_fmt(dur),
                            style: TextStyle(
                                color:
                                    adaptive.withValues(alpha: 0.85))),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.playback, this.small = false});
  final PlaybackController playback;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconSize = small ? 28.0 : 36.0;
    final secondaryIconSize = small ? 22.0 : 26.0;
    final playSize = small ? 40.0 : 48.0;

    final repeatIcon = switch (playback.repeatMode) {
      PlaybackRepeatMode.off => Icons.repeat_rounded,
      PlaybackRepeatMode.all => Icons.repeat_rounded,
      PlaybackRepeatMode.one => Icons.repeat_one_rounded,
    };
    final repeatActive = playback.repeatMode != PlaybackRepeatMode.off;
    final shuffleActive = playback.shuffleEnabled;

    // Color activo (shuffle/repeat ON, no el play central): primary del
    // album con contraste garantizado. El play central conserva el bg
    // primary intencional (es el acento principal).
    final activeColor = ContrastUtils.ensureReadable(
      scheme.primary,
      scheme.surface,
      target: 4.5,
    );

    // AdaptiveColor sólo envuelve los iconos NO seleccionados (prev/next +
    // shuffle/repeat inactivos). Así cada uno muestra tinta clara/oscura
    // según la franja del bg que tiene detrás — útil cuando el album es
    // brillante en una parte y oscuro en otra.
    return AdaptiveColor(
      builder: (context, adaptive) {
        return Row(
          mainAxisAlignment:
              small ? MainAxisAlignment.center : MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: secondaryIconSize,
              tooltip: shuffleActive ? 'Aleatorio activado' : 'Aleatorio',
              color: shuffleActive ? activeColor : adaptive,
              onPressed: playback.toggleShuffle,
              icon: const Icon(Icons.shuffle_rounded),
            ),
            if (small) SizedBox(width: LayoutTokensScope.of(context).gapSm),
            IconButton(
              iconSize: iconSize,
              onPressed: playback.previous,
              color: adaptive,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            if (small) SizedBox(width: LayoutTokensScope.of(context).gap),
            Container(
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: playSize,
                color: scheme.onPrimary,
                onPressed: playback.togglePlayPause,
                icon: Icon(
                  playback.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
            ),
            if (small) SizedBox(width: LayoutTokensScope.of(context).gap),
            IconButton(
              iconSize: iconSize,
              onPressed: playback.next,
              color: adaptive,
              icon: const Icon(Icons.skip_next_rounded),
            ),
            if (small) SizedBox(width: LayoutTokensScope.of(context).gapSm),
            IconButton(
              iconSize: secondaryIconSize,
              tooltip: switch (playback.repeatMode) {
                PlaybackRepeatMode.off => 'Repetir',
                PlaybackRepeatMode.all => 'Repetir todo',
                PlaybackRepeatMode.one => 'Repetir una',
              },
              color: repeatActive ? activeColor : adaptive,
              onPressed: playback.cyclePlaybackRepeatMode,
              icon: Icon(repeatIcon),
            ),
          ],
        );
      },
    );
  }
}
