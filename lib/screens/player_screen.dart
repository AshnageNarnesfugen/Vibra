import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/settings/settings_controller.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/contrast.dart';
import '../core/theme/layout_tokens.dart';
import '../widgets/adaptive_color.dart';
import '../widgets/marquee_text.dart';
import '../models/song.dart';
import '../providers/lyrics_controller.dart';
import '../providers/playback_controller.dart';
import '../services/video_availability_controller.dart';
import '../core/theme/palette_signal.dart';
import '../widgets/cover_info_panel.dart';
import '../widgets/cover_shape_wrappers.dart';
import '../widgets/lyrics_panel.dart';
import '../widgets/music_video_cover.dart';
import '../widgets/palette_picker_sheet.dart';
import '../widgets/playback_params_sheet.dart';
import '../widgets/responsive_song_grid.dart';
import '../widgets/song_context_sheet.dart';
import '../widgets/song_thumbnail.dart';

import '../core/animations/page_transitions.dart';
import 'artist_screen.dart';
import 'home_screen.dart';
import 'video_fullscreen_screen.dart';

part 'player/portrait_player.dart';
part 'player/queue_widgets.dart';
part 'player/split_layout.dart';
part 'player/transport_widgets.dart';
part 'player/wide_cover.dart';
part 'player/cover_widgets.dart';

/// Vista del reproductor con dos modos:
///   - Vertical / pantallas estrechas → cover + metadata + transport apilados,
///     con la cola integrada debajo que se anima de mini-handle a lista
///     completa (estilo YT Music: el cover se reduce arriba y deja paso a
///     la cola en lugar de quedar tapado por un sheet flotante).
///   - Horizontal / anchas (>= 720dp) → split en dos columnas: player a la
///     izquierda, cola completa a la derecha (con la grilla responsive de la
///     biblioteca, así columnas se adaptan al espacio disponible).
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  /// Umbral de anchura a partir del cual el layout pasa a split-view.
  static const double _kSplitThreshold = 720.0;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  // Animación de la cola en portrait: 0 = cover full + handle pequeño,
  // 1 = cover mini arriba + lista de cola dominando abajo. Se controla
  // tanto desde el botón del AppBar como desde el drag handle.
  late final AnimationController _queueAnim;

  @override
  void initState() {
    super.initState();
    _queueAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 280),
      // 3 estados snap: 0 = full player, 1 = banner+queue, 2 = mini
      // player bar + queue dominante (estilo YT Music). Para llegar al
      // estado 2 el usuario tiene que SEGUIR deslizando arriba después
      // de pasar por 1 — el botón del AppBar solo alterna 0↔1.
      upperBound: 2.0,
    );
  }

  @override
  void dispose() {
    _queueAnim.dispose();
    super.dispose();
  }

  void _toggleQueue() {
    if (_queueAnim.isAnimating) return;
    // El botón solo alterna entre 0 (full) y 1 (banner+queue). El estado
    // 2 (mini player) es accesible solo por gesto — es un "extra" para
    // power users que quieren más cola visible.
    if (_queueAnim.value > 0.5) {
      _queueAnim.animateTo(0.0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInCubic);
    } else {
      _queueAnim.animateTo(1.0,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pb = context.watch<PlaybackController>();
    final song = pb.currentSong;

    if (song == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('Nada en reproducción.')),
      );
    }

    final isWide =
        MediaQuery.sizeOf(context).width >= PlayerScreen._kSplitThreshold;

    final lyrics = context.watch<LyricsController>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      // En portrait el cover en modo expanded se extiende DETRÁS del AppBar
      // (banner edge-to-edge tipo YT Music: la portada sigue visible bajo
      // los iconos de back/cola/letra). En landscape mantenemos el AppBar
      // sobre el body para no romper la geometría del split.
      extendBodyBehindAppBar: !isWide,
      appBar: AppBar(
        // Transparente + sin elevación así el cover se ve a través del
        // AppBar cuando está en modo expanded. Los iconos siguen visibles
        // (AdaptiveColor les da contraste sobre el cover).
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // El AppBar del player va sobre la portada (con o sin blur). Sus
        // iconos necesitan contraste contra el área superior del bg, que
        // puede ser brillante (cielo, fondo blanco) u oscuro (sombras).
        // Wrap independiente por icono → cada uno samplea su columna.
        leading: AdaptiveColor(
          builder: (context, color) => IconButton(
            icon: const Icon(Icons.expand_more_rounded),
            color: color,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: AdaptiveColor(
          builder: (context, color) => Text(
            'Reproduciendo',
            style: TextStyle(
              color: color,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
        ),
        actions: [
          // Solo mostramos el botón "cola" en portrait — en landscape la
          // cola ya está siempre visible en el split right panel. El icono
          // rota con la animación para feedback visual del estado.
          if (!isWide)
            AdaptiveColor(
              builder: (context, color) => AnimatedBuilder(
                animation: _queueAnim,
                builder: (context, _) => IconButton(
                  tooltip: _queueAnim.value > 0.5 ? 'Ocultar cola' : 'Ver cola',
                  onPressed: _toggleQueue,
                  icon: Transform.rotate(
                    angle: _queueAnim.value * math.pi,
                    child: const Icon(Icons.expand_less_rounded),
                  ),
                  color: _queueAnim.value > 0.5
                      ? Theme.of(context).colorScheme.primary
                      : color,
                ),
              ),
            ),
          // Toggle Cover ↔ Video: solo aparece si el track tiene videoId y
          // YT Music confirma que existe un video disponible. Antes vivía
          // como overlay encima de la portada — lo movimos al AppBar para
          // no tapar la imagen ni interferir con el banner en expanded.
          if (song.streamingId != null)
            Consumer<VideoAvailabilityController>(
              builder: (context, availability, _) {
                final videoId = song.streamingId!;
                if (!availability.isAvailable(videoId)) {
                  return const SizedBox.shrink();
                }
                final showVideo = availability.showAsCover;
                return AdaptiveColor(
                  builder: (context, color) => IconButton(
                    tooltip: showVideo ? 'Ver carátula' : 'Ver video',
                    onPressed: () =>
                        availability.setShowAsCover(!showVideo),
                    icon: Icon(
                      showVideo
                          ? Icons.image_rounded
                          : Icons.play_circle_outline_rounded,
                      color: showVideo
                          ? Theme.of(context).colorScheme.primary
                          : color,
                    ),
                  ),
                );
              },
            ),
          // Palette swap: abre un panel con los swatches detectados en
          // la portada para que el usuario pueda elegir manualmente el
          // dominant si no le gustó el pick automático. No se muestra
          // cuando hay video activo (en ese modo la paleta la dicta el
          // ambient mode, no la portada estática).
          Consumer2<VideoAvailabilityController, PaletteSignal>(
            builder: (context, availability, palette, _) {
              final videoId = song.streamingId;
              final showingVideo = videoId != null &&
                  availability.isAvailable(videoId) &&
                  availability.showAsCover;
              if (showingVideo) return const SizedBox.shrink();
              if (palette.availableSwatches.length < 2) {
                return const SizedBox.shrink();
              }
              return AdaptiveColor(
                builder: (context, color) => IconButton(
                  tooltip: 'Cambiar color',
                  onPressed: () => PalettePickerSheet.show(context),
                  icon: Icon(Icons.palette_rounded, color: color),
                ),
              );
            },
          ),
          AdaptiveColor(
            builder: (context, color) => IconButton(
              tooltip: lyrics.showLyrics ? 'Ocultar letra' : 'Ver letra',
              onPressed: lyrics.toggleShowLyrics,
              icon: Icon(
                lyrics.showLyrics
                    ? Icons.lyrics_rounded
                    : Icons.lyrics_outlined,
                // Si lyrics activo: primary (acento del album). Sino: color
                // adaptativo según el bg detrás del icono.
                color: lyrics.showLyrics
                    ? Theme.of(context).colorScheme.primary
                    : color,
              ),
            ),
          ),
          // Speed / pitch. Mismo patrón que palette/lyrics: icono coloreado
          // primary cuando los params no son neutrales para que el usuario
          // vea de un vistazo que algo está modificado sin tener que abrir
          // el sheet. Tap → bottom sheet con los sliders.
          Builder(builder: (ctx) {
            final s = UiSettingsScope.of(ctx);
            final modified = playbackParamsAreModified(
              speed: s.playbackSpeed,
              pitchSemitones: s.playbackPitchSemitones,
            );
            return AdaptiveColor(
              builder: (context, color) => IconButton(
                tooltip: modified
                    ? 'Velocidad/tono: ${playbackParamsPillText(
                        speed: s.playbackSpeed,
                        pitchSemitones: s.playbackPitchSemitones,
                      )}'
                    : 'Velocidad y tono',
                onPressed: () => showPlaybackParamsSheet(context),
                icon: Icon(
                  Icons.speed_rounded,
                  color: modified
                      ? Theme.of(context).colorScheme.primary
                      : color,
                ),
              ),
            );
          }),
          // Menú de contexto de la canción actual — las mismas acciones
          // que el hold / 3-puntitos de las listas (guardar en playlist,
          // descargar, ir al álbum/artista, reproducir a continuación…).
          AdaptiveColor(
            builder: (context, color) => IconButton(
              tooltip: 'Más opciones',
              onPressed: () =>
                  showSongContextSheet(context, songs: [song]),
              icon: Icon(Icons.more_vert_rounded, color: color),
            ),
          ),
        ],
      ),
      body: isWide
          ? SafeArea(child: _SplitLayout(playback: pb))
          : Stack(
              children: [
                // Capa de fondo opaca (scheme.surface) que aparece
                // gradualmente al expandir la cola. En colapsado (alpha
                // 0) deja ver el customized_background blureado detrás;
                // en expandido (alpha 1) lo oculta. Esto resuelve el
                // escalón visible entre el bottom del cover banner
                // (que termina con surface 1.0 por el scrim inferior) y
                // la zona de controles que arriba mostraba el bg
                // blureado de la misma carátula → ahora ambos son el
                // mismo surface color cuando expandido, fusión limpia.
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _queueAnim,
                    builder: (context, _) {
                      final scheme = Theme.of(context).colorScheme;
                      return ColoredBox(
                        color: scheme.surface
                            .withValues(alpha: _queueAnim.value),
                      );
                    },
                  ),
                ),
                _PortraitPlayer(
                  playback: pb,
                  queueController: _queueAnim,
                ),
              ],
            ),
    );
  }
}
