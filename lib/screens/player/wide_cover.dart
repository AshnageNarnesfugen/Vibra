// Cover ancho con controles flotantes (layout horizontal).
//
// `part` de player_screen.dart: las clases del player comparten
// estado privado entre sí, así que viven en una sola librería
// partida en archivos por concern (imports en el archivo raíz).
part of '../player_screen.dart';

/// Layout horizontal: cover full-size + card de controles flotante
/// minimizable. Cuando los controles están minimizados, solo aparece un
/// FAB pequeño en la esquina inferior-derecha que al tap los expande de
/// nuevo. La idea es que el usuario pueda ver el arte de la portada sin
/// que la card lo tape mientras escucha.
class _WideCoverWithControls extends StatefulWidget {
  const _WideCoverWithControls({
    required this.cover,
    required this.playback,
    required this.title,
    required this.artist,
    required this.radius,
    required this.outerPadding,
  });

  final Widget cover;
  final PlaybackController playback;
  final Widget title;
  final Widget artist;
  final BorderRadius radius;
  final EdgeInsetsGeometry outerPadding;

  @override
  State<_WideCoverWithControls> createState() => _WideCoverWithControlsState();
}

class _WideCoverWithControlsState extends State<_WideCoverWithControls> {
  bool _expanded = true;

  /// True cuando el back del card flip está visible (square) o el bottom
  /// sheet está abierto (CD/holo). Usado para ocultar los controles
  /// overlay del cover — sino la card de controles tapaba el panel de
  /// info reportado por el usuario.
  bool _coverInfoVisible = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.outerPadding,
      // Center + AspectRatio: la carátula se mantiene SIEMPRE cuadrada,
      // independiente de si los controles están expandidos o no, y
      // independiente de la altura disponible del panel. Antes el Stack
      // tomaba todo el Expanded del padre → el cover se estiraba con la
      // altura y se "deformaba" cuando los controles cambiaban de tamaño.
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            children: [
              // 1. Cover de fondo. Pasa por `_ShapedCover` para honrar
              // la selección de `coverShape` del usuario (cuadrado / CD /
              // holográfico) — antes solo aplicaba en portrait y en
              // landscape se veía el clip rectangular plano sin
              // animación, inconsistente.
              //
              // El scrim inferior (gradient negro abajo para legibilidad
              // de los controles) va DENTRO del child del _ShapedCover —
              // sino con holográfico el scrim queda como una capa estática
              // mientras el cover se inclina con el giroscopio, y se ve
              // como una sombra "despegada" de la portada. Embebido,
              // viaja con el tilt 3D y se siente parte del cover.
              Positioned.fill(
                child: Builder(builder: (ctx) {
                  final song = widget.playback.currentSong;
                  final ui = UiSettingsScope.of(ctx);
                  final shaped = _ShapedCover(
                    shape: ui.coverShape,
                    radius: widget.radius,
                    isPlaying: widget.playback.isPlaying,
                    holoTiltIntensity: ui.holoTiltIntensity,
                    holoParallaxIntensity: ui.holoParallaxIntensity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        widget.cover,
                        if (_expanded)
                          const IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0x99000000),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                  // Si no hay song activa (estado transitorio), devolvemos
                  // el shaped directo sin wrapping — el FlippableCover
                  // necesita una Song no-null.
                  if (song == null) return shaped;
                  return _FlippableCover(
                    song: song,
                    shape: ui.coverShape,
                    borderRadius: widget.radius,
                    front: shaped,
                    onInfoVisibilityChanged: (visible) {
                      if (mounted) {
                        setState(() => _coverInfoVisible = visible);
                      }
                    },
                  );
                }),
              ),
              // 3. Controles: dos Positioned independientes (uno para cada
              // estado) con AnimatedOpacity. Antes los envolvía un
              // AnimatedSwitcher pero su Stack interno descartaba los
              // Positioned → los controles flotaban en el centro vertical
              // en lugar de pegarse al fondo. Con dos Positioned separados,
              // cada uno mantiene su geometría y solo cambia la opacidad.
              //
              // Cuando el lado B del cover está visible (`_coverInfoVisible`),
              // ambos overlays (card grande y FAB mini) se ocultan — sino
              // tapan el panel de info reportado por el usuario.
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: IgnorePointer(
                  ignoring: !_expanded || _coverInfoVisible,
                  child: AnimatedOpacity(
                    opacity:
                        (_expanded && !_coverInfoVisible) ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: _HorizontalControlsCard(
                      playback: widget.playback,
                      title: widget.title,
                      artist: widget.artist,
                      onMinimize: () => setState(() => _expanded = false),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: IgnorePointer(
                  ignoring: _expanded || _coverInfoVisible,
                  child: AnimatedOpacity(
                    opacity:
                        (!_expanded && !_coverInfoVisible) ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: _MiniControlsFab(
                      playback: widget.playback,
                      onExpand: () => setState(() => _expanded = true),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// FAB compacto que aparece cuando los controles del modo horizontal
/// están minimizados: solo play/pause + un botón para re-expandir la
/// card completa. Para skip/prev/scrubber, el usuario expande de vuelta.
class _MiniControlsFab extends StatelessWidget {
  const _MiniControlsFab({required this.playback, required this.onExpand});
  final PlaybackController playback;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.78),
      shape: const StadiumBorder(),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Expandir controles',
              icon: const Icon(Icons.expand_less_rounded),
              onPressed: onExpand,
            ),
            Container(
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                iconSize: 28,
                color: scheme.onPrimary,
                onPressed: playback.togglePlayPause,
                icon: Icon(
                  playback.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Carta de controles para el modo horizontal: centrada y sin blur para no
/// tapar la carátula que tiene debajo.
class _HorizontalControlsCard extends StatelessWidget {
  const _HorizontalControlsCard({
    required this.playback,
    required this.title,
    required this.artist,
    this.onMinimize,
  });

  final PlaybackController playback;
  final Widget title;
  final Widget artist;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);

    // Usamos DecoratedBox en lugar de GlassCard para eliminar el blur
    // y mantener solo el tinte translúcido.
    return ClipRRect(
      borderRadius: tokens.radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(
            alpha: (settings.effectiveSurfaceOpacity * 0.8).clamp(0.0, 1.0),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Header con título centrado + botón "minimizar" a la derecha.
              // Stack para que el botón flote sin desplazar el título del
              // centro óptico.
              SizedBox(
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    title,
                    if (onMinimize != null)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: IconButton(
                          tooltip: 'Minimizar controles',
                          icon: const Icon(Icons.expand_more_rounded),
                          onPressed: onMinimize,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              artist,
              // Antes vivía aquí `_PlayerInfoChips()`. Movido al lado B
              // de la carátula — ver comentario equivalente en portrait.
              const SizedBox(height: 8),
              _Scrubber(playback: playback),
              _Transport(playback: playback, small: true),
            ],
          ),
        ),
      ),
    );
  }
}
