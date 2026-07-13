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
import '../widgets/song_thumbnail.dart';

import 'artist_screen.dart';
import 'home_screen.dart';

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

/// Portrait con animación "cover → mini" + queue list que crece desde abajo.
///
/// Estado colapsado (controller=0):
///   - Cover gigante centrado (estilo clásico).
///   - title / artist / scrubber / transport debajo.
///   - Handle pequeño "Tu fila · N" al final, tap o swipe up para expandir.
///
/// Estado expandido (controller=1):
///   - Cover reducido a tamaño mini.
///   - Mismos controles intermedios.
///   - Lista de la cola scrolleable ocupando el espacio liberado por el cover.
///
/// La interpolación es continua: el cover se reduce gradualmente y el espacio
/// liberado se asigna a la lista. Drag vertical sobre el handle ajusta el
/// controller en tiempo real, soltándolo se snapea al endpoint más cercano.
class _PortraitPlayer extends StatelessWidget {
  const _PortraitPlayer({
    required this.playback,
    required this.queueController,
  });

  final PlaybackController playback;
  final AnimationController queueController;

  /// Altura reservada para el handle "Tu fila" — siempre visible.
  static const double _handleHeight = 44.0;

  // Pesos del Flex que reparten el espacio sobrante entre el cover y la lista
  // de la cola. Usar flex evita depender de medidas hardcoded → cero overflow
  // aunque text-scale crezca o la pantalla cambie de alto.
  //
  // Colapsado: cover toma casi todo el espacio, queue ≈0 (1/1000).
  // Expandido: cover 70% / queue 30% — el banner del cover toma el grueso
  // del espacio (estilo YT Music donde la portada llega hasta la app bar
  // arriba y se extiende hacia abajo hasta el título), la cola queda como
  // sección scrolleable corta abajo.
  static const double _coverFlexCollapsed = 999.0;
  static const double _coverFlexExpanded = 700.0;
  // Estado 2 (mini player bar): cover Expanded sigue presente (Expanded.flex
  // ≥ 1) pero con flex 1 vs queue flex 10000 → cover toma 1/10001 del
  // espacio restante = una fracción de pixel, debajo del umbral
  // perceptible. Sumado al surface overlay que se mete en el Stack del
  // cover (ColoredBox surface con alpha=phase2), la franja residual
  // queda pintada del mismo color que el bg → invisible.
  static const double _coverFlexMini = 1.0;
  static const double _queueFlexCollapsed = 1.0;
  static const double _queueFlexExpanded = 300.0;
  static const double _queueFlexMini = 10000.0;

  void _onHandleDragUpdate(DragUpdateDetails d, double travel) {
    if (travel <= 0) return;
    // dy negativo (swipe up) → expandir. Cada "fase" del controller
    // consume `travel` pixels de drag: así el usuario tiene que
    // deslizar el doble para pasar 0→2 que para 0→1, lo que evita
    // entrar al estado mini accidentalmente con un swipe normal.
    final delta = -(d.primaryDelta ?? 0) / travel;
    queueController.value =
        (queueController.value + delta).clamp(0.0, 2.0);
  }

  void _onHandleDragEnd(DragEndDetails d) {
    final velocity = d.velocity.pixelsPerSecond.dy;
    final value = queueController.value;
    if (velocity.abs() > 320) {
      // Fling: respetar dirección, ir AL siguiente snap point en esa
      // dirección. Up → siguiente estado más expandido; down → más cerrado.
      if (velocity > 0) {
        _animateTo(value > 1.0 ? 1.0 : 0.0);
      } else {
        _animateTo(value < 1.0 ? 1.0 : 2.0);
      }
    } else {
      // Sin fling: snap al endpoint MÁS cercano de {0, 1, 2}.
      final target =
          value < 0.5 ? 0.0 : (value < 1.5 ? 1.0 : 2.0);
      _animateTo(target);
    }
  }

  void _animateTo(double target) {
    queueController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = playback.currentSong!;
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);
    final showLyrics =
        context.select<LyricsController, bool>((c) => c.showLyrics);

    final cover = RepaintBoundary(child: _CoverWithVideoToggle(song: song));

    final title = MarqueeText(
      song.title,
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );

    final artistStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.7),
          decoration:
              song.artistBrowseId != null ? TextDecoration.underline : null,
        );
    final artist = GestureDetector(
      onTap: () {
        if (song.isStreaming && song.artistBrowseId != null) {
          final browseId = song.artistBrowseId!;
          Navigator.of(context).pop();
          TabNavigation.pushInActiveTab(
            ArtistScreen(browseId: browseId),
            style: settings.transitionStyle,
            durationMs: settings.transitionDurationMs,
          );
        }
      },
      child: MarqueeText(song.artist, style: artistStyle),
    );

    // Valores que NO dependen de la animación: se computan una vez por
    // rebuild del padre, no por frame.
    final pagePadH = tokens.pagePadding().horizontal / 2;
    final mq = MediaQuery.of(context);
    final topInset = mq.padding.top + kToolbarHeight;
    final bottomInset = mq.viewPadding.bottom;
    // Travel del handle (drag): valor que da un drag "natural" sin
    // depender del alto real → constante porque el efecto visual es la
    // proporción dy / travel, no el pixel exacto.
    const travel = 320.0;

    Widget padX(Widget c) => Padding(
          padding: EdgeInsets.symmetric(horizontal: pagePadH),
          child: c,
        );

    // ───────── Subárboles ESTÁTICOS ─────────
    // Estos se construyen 1 vez por rebuild del padre (al cambiar canción,
    // queue, lyrics, etc.) y se pasan al AnimatedBuilder por referencia.
    // Entre frames de animación NO se reconstruyen — el AnimatedBuilder
    // diff los detecta como mismo widget instance → sin trabajo de
    // build/layout en swipes, eso elimina la mayor fuente de stutter.
    final controlsBlock = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: tokens.gapLg), // gap entre cover y título (fijo)
        padX(title),
        SizedBox(height: tokens.gapSm),
        padX(artist),
        // Antes vivía aquí `_PlayerInfoChips()` con bitrate/speed/bit-perfect.
        // Movido al lado B de la carátula (card flip en cuadrado, bottom
        // sheet en CD/holo) — el usuario reportó que esos chips
        // amontonaban el layout en vertical y empujaban controles.
        SizedBox(height: tokens.gap),
        padX(_Scrubber(playback: playback)),
        SizedBox(height: tokens.gap),
        padX(_Transport(playback: playback)),
        SizedBox(height: tokens.gapSm),
        padX(_QueueHandle(
          queueLength: playback.queue.length,
          queueAnim: queueController,
          // Tap alterna entre 0 ↔ 1 (no entra al estado 2 mini, igual que
          // el botón del AppBar). Antes usaba forward()/reverse() que con
          // upperBound=2.0 saltaba directo al estado mini → bug. El
          // estado 2 sigue siendo accesible solo por gesto de drag.
          onTap: () => _animateTo(queueController.value > 0.5 ? 0.0 : 1.0),
          onVerticalDragUpdate: (d) => _onHandleDragUpdate(d, travel),
          onVerticalDragEnd: _onHandleDragEnd,
        )),
      ],
    );

    final queueList = RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: pagePadH),
        child: ClipRect(child: _QueueListView(playback: playback)),
      ),
    );

    final lyricsOverlay = AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: showLyrics
          ? _LyricsOverlay(
              key: const ValueKey('lyrics'),
              radius: tokens.radiusLg,
            )
          : const SizedBox.shrink(key: ValueKey('lyrics-off')),
    );

    // Mini player bar (estado 2): Row compacto con thumbnail + título +
    // artista + play/pause. Se renderiza siempre pero su opacidad la
    // controla el AnimatedBuilder (phase2). Construido fuera del builder
    // → no rebuild en frames de animación, solo cuando cambia la canción.
    final miniPlayerBar = _MiniPlayerBar(song: song, playback: playback);

    return AnimatedBuilder(
      animation: queueController,
      // controlsBlock se pasa por `child` → AnimatedBuilder garantiza que
      // se reutiliza por referencia entre frames (no rebuild).
      child: controlsBlock,
      builder: (context, child) {
        // El controller va 0..2. Lo separamos en dos fases lineales
        // independientes para que cada transición visual viva en su
        // propio rango y sea más fácil de razonar:
        //   phase1 = t.clamp(0, 1)  → estado 0 (full) → 1 (banner+queue)
        //   phase2 = (t-1).clamp(0, 1) → estado 1 → 2 (mini bar + queue)
        final raw = queueController.value;
        final phase1 = Curves.easeOutCubic.transform(raw.clamp(0.0, 1.0));
        final phase2 =
            Curves.easeOutCubic.transform((raw - 1.0).clamp(0.0, 1.0));

        // Flex del cover: interpolación en dos tramos.
        //   phase1: 999 → 700 (cover full → banner ocupando 70%)
        //   phase2: 700 → 100 (banner → mini bar pequeña arriba)
        final coverFlex = ui
            .lerpDouble(
              ui.lerpDouble(
                  _coverFlexCollapsed, _coverFlexExpanded, phase1)!,
              _coverFlexMini,
              phase2,
            )!
            .round()
            .clamp(1, 10000);
        final queueFlex = ui
            .lerpDouble(
              ui.lerpDouble(
                  _queueFlexCollapsed, _queueFlexExpanded, phase1)!,
              _queueFlexMini,
              phase2,
            )!
            .round()
            .clamp(1, 10000);
        final coverHorizontalPad = ui.lerpDouble(pagePadH, 0.0, phase1)!;
        final coverRadius = BorderRadius.lerp(
          tokens.radiusLg,
          BorderRadius.zero,
          phase1,
        )!;
        // Gap ARRIBA del cover: 0 cuando banner (phase1=1) para que llegue
        // al status bar. En estado 2 (mini) no aporta — los iconos del
        // AppBar reclaman la franja superior, no la portada.
        final coverGapTop = ui.lerpDouble(tokens.gapLg, 0.0, phase1)!;
        // padTop: V-shape sobre las tres fases.
        //   raw=0: topInset → cover debajo del AppBar (clásico).
        //   raw=1: 0 → cover banner detrás del AppBar (edge-to-edge).
        //   raw=2: kToolbarHeight + gap → mini bar debajo del AppBar con
        //          respiro visual del tamaño estándar de spacing (gap),
        //          consistente con el resto del layout. El extra `gap`
        //          evita que el mini bar quede pegado a los iconos del
        //          AppBar mientras mantiene la posición predecible.
        final padTop = ui.lerpDouble(
          ui.lerpDouble(topInset, 0.0, phase1)!,
          kToolbarHeight + tokens.gap,
          phase2,
        )!;
        // SizeFactor de los controles: 1 → 0 a lo largo de phase2 → el
        // bloque entero (title/artist/scrubber/transport/handle) colapsa
        // verticalmente liberando espacio para la cola.
        final controlsSizeFactor = 1.0 - phase2;
        // Scrim alpha: presente en estado 1 (banner) para fusionarse con
        // el AppBar transparente, ausente en estado 2 (mini bar tiene su
        // propio bg surface opaco, los scrims sobrarían y oscurecen el
        // mini bar).
        final scrimAlpha = phase1 * (1.0 - phase2);

        // Altura aproximada del mini player bar (thumbnail 44 + IconButton
        // 48 max child + padding vertical 16). Usada para reservar
        // espacio en el Column cuando phase2 > 0 → así el mini bar
        // overlay (Stack) no se solapa con el queue list.
        const miniBarHeight = 64.0;
        // Espacio que reserva el Column para el mini bar overlay.
        // En estado 0/1 = 0 (no hay overlay). En estado 2 = miniBarHeight.
        final miniBarSlot = phase2 * miniBarHeight;

        return Padding(
          padding: EdgeInsets.only(top: padTop, bottom: bottomInset),
          // Stack para forzar al mini bar al top: 0 absoluto del area
          // dentro del Padding → con padTop=topInset eso es justo
          // debajo del AppBar. Si el dispositivo del usuario tiene
          // medidas raras de safe area o Material 3 changes el AppBar
          // height, esta posición explícita es robusta.
          child: Stack(
            children: [
              Column(
                children: [
                  // Reserva el espacio del mini bar overlay para que el
                  // resto del layout (cover/queue) no quede debajo de él.
                  SizedBox(height: miniBarSlot),
                  SizedBox(height: coverGapTop),
                  // Cover. Phase 1: cuadrado → banner full-width. Phase 2: el
              // banner se reduce a una bar tipo mini-player (altura del
              // Expanded baja drásticamente con coverFlex).
              Expanded(
                flex: coverFlex,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: coverHorizontalPad,
                  ),
                  child: LayoutBuilder(
                    builder: (ctx, c) {
                      final h = c.maxHeight;
                      final fullW = c.maxWidth;
                      final squareSide = math.min(h, fullW);
                      final w = ui.lerpDouble(squareSide, fullW, phase1)!;
                      final hFinal = ui.lerpDouble(squareSide, h, phase1)!;
                      return Center(
                        child: SizedBox(
                          width: w,
                          height: hFinal,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _FlippableCover(
                                song: song,
                                shape: settings.coverShape,
                                borderRadius: coverRadius,
                                // El botón "i" solo aparece en estado 0
                                // (cover full). En banner/mini hay poco
                                // espacio y compite con scrims + queue
                                // handle.
                                showInfoButton: phase1 < 0.05,
                                front: _ShapedCover(
                                  shape: settings.coverShape,
                                  radius: coverRadius,
                                  isPlaying: playback.isPlaying,
                                  // Tilt 3D solo activo en estado 0 del
                                  // queue. Al expandirse a banner (phase1
                                  // > 0), el 3D se desvanece — sino el
                                  // cover en banner mode pelearía con el
                                  // queue list y el giroscopio haría
                                  // saltar el banner. `(1 - phase1)` da
                                  // el fade continuo durante la transición.
                                  //
                                  // Parallax (shift de bandas del shader)
                                  // se preserva entero — el "movimiento
                                  // holográfico" sigue vivo aunque el
                                  // queue esté expandido, como pidió el
                                  // usuario.
                                  holoTiltIntensity:
                                      settings.holoTiltIntensity *
                                          (1.0 - phase1),
                                  holoParallaxIntensity:
                                      settings.holoParallaxIntensity,
                                  child: cover,
                                ),
                              ),
                              // Scrim superior (legibilidad iconos AppBar).
                              if (scrimAlpha > 0)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  height:
                                      mq.padding.top + kToolbarHeight + 16,
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            scheme.surface.withValues(
                                                alpha: 0.45 * scrimAlpha),
                                            scheme.surface
                                                .withValues(alpha: 0.0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              // Scrim inferior (fusión cover→controles).
                              if (scrimAlpha > 0)
                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  height: hFinal * 0.5,
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: [
                                            scheme.surface.withValues(
                                                alpha: scrimAlpha),
                                            scheme.surface
                                                .withValues(alpha: 0.0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              lyricsOverlay,
                              // Surface overlay: fade-in con phase2 →
                              // oculta la franja sub-pixel del cover
                              // Expanded en estado 2 (donde flex 1
                              // vs 10000 produce ~0px pero rounding
                              // puede dejar 1px visible). El color
                              // exacto del bg (scheme.surface) hace
                              // que la franja sea indistinguible del
                              // ColoredBox del body.
                              if (phase2 > 0)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: ColoredBox(
                                      color: scheme.surface.withValues(
                                          alpha: phase2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Bloque controles estático: colapsa verticalmente en
              // phase2 vía Align(heightFactor) → encoge desde arriba
              // para que el queue list parezca subir.
              ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: controlsSizeFactor.clamp(0.0, 1.0),
                  child: child!,
                ),
              ),
              // Queue list. Corners superiores redondeados que aparecen
              // solo en estado 2 (queue dominante con mini-player bar
              // arriba). En estados 0 y 1 los corners están planos
              // porque el queue está pegado al borde inferior del cover
              // o de los controles — un radio ahí daría un "hueco" feo.
              // En estado 2 el queue se separa del mini-player → el
              // radio le da forma de "sheet" levantada.
              //
              // Color del sheet: `surfaceContainerHighest` (Material 3) —
              // tono distinto a `surface` que el resto del player usa,
              // específicamente diseñado para "elevated containers" que
              // necesitan distinción visual sin contraste alto. Antes
              // usábamos `surface` con alpha y el sheet se confundía con
              // el bg del player en estado 2 → los corners no se notaban.
              Expanded(
                flex: queueFlex,
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(20 * phase2),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest
                          .withValues(alpha: phase2 * 0.92),
                    ),
                    child: queueList,
                  ),
                ),
              ),
            ],
          ),
              // Mini player bar overlay: posicionado ABSOLUTAMENTE en
              // top: 0 del Stack (que está dentro de Padding(top:
              // padTop)) → mini bar arranca en y=padTop de la
              // pantalla, justo debajo del AppBar. ClipRect+Align
              // hacen el fade-in vía heightFactor (grow desde arriba).
              if (phase2 > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ClipRect(
                    child: Align(
                      alignment: Alignment.topCenter,
                      heightFactor: phase2.clamp(0.0, 1.0),
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onVerticalDragUpdate: (d) =>
                            _onHandleDragUpdate(d, travel),
                        onVerticalDragEnd: _onHandleDragEnd,
                        child: miniPlayerBar,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Bar tipo mini-player que se monta encima del cover cuando el queue
/// está en estado 2 (deslizar al máximo arriba). Layout estilo YT Music:
/// thumbnail pequeño a la izquierda + título/artista + play/pause.
class _MiniPlayerBar extends StatelessWidget {
  const _MiniPlayerBar({required this.song, required this.playback});

  final Song song;
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = LayoutTokensScope.of(context);
    return DecoratedBox(
      // Fondo opaco surface → cubre la portada que está debajo cuando
      // el mini bar está visible. La transición de fade-in con phase2
      // hace que vaya apareciendo gradualmente sobre el banner.
      decoration: BoxDecoration(color: scheme.surface),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.space(12),
          vertical: tokens.space(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: tokens.radiusSm,
              child: SongThumbnail(song: song, size: 44),
            ),
            SizedBox(width: tokens.gap),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText(
                    song.title,
                    textAlign: TextAlign.left,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  MarqueeText(
                    song.artist,
                    textAlign: TextAlign.left,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.70),
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Anterior',
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: playback.previous,
            ),
            IconButton(
              iconSize: 32,
              tooltip: playback.isPlaying ? 'Pausa' : 'Reanudar',
              icon: Icon(
                playback.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              onPressed: playback.togglePlayPause,
            ),
            IconButton(
              tooltip: 'Siguiente',
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: playback.next,
            ),
          ],
        ),
      ),
    );
  }
}

/// Handle del queue: caret animado + "Tu fila · N". El widget no tiene fondo
/// para no romper la integración con la paleta del bg; sólo respeta el
/// gesture área completo (vertical drag + tap).
class _QueueHandle extends StatelessWidget {
  const _QueueHandle({
    required this.queueLength,
    required this.queueAnim,
    required this.onTap,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
  });

  final int queueLength;
  final Animation<double> queueAnim;
  final VoidCallback onTap;
  final GestureDragUpdateCallback onVerticalDragUpdate;
  final GestureDragEndCallback onVerticalDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: SizedBox(
        height: _PortraitPlayer._handleHeight,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Barrita "drag indicator" estilo iOS — hint visual fuerte
            // de que el panel es deslizable vertical. Material la usa en
            // sus modal sheets; replicamos el patrón aquí para que el
            // usuario sepa al instante que la franja del queue es
            // interactiva con swipe up/down.
            //
            // 36px de ancho × 4px de alto es la spec de Material para
            // drag handles. El color va con onSurface a baja opacidad
            // así no compite con el contenido pero sigue visible.
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            AdaptiveColor(
              builder: (context, adaptive) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: queueAnim,
                    builder: (_, _) => Transform.rotate(
                      angle: queueAnim.value * math.pi,
                      child: Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 20,
                        color: adaptive,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Tu fila',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      letterSpacing: 0.2,
                      color: adaptive,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '· $queueLength',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lista scrolleable de la cola usada por el portrait expandido.
/// Reusa `_QueueTile` para mantener idéntico look con el panel wide.
class _QueueListView extends StatelessWidget {
  const _QueueListView({required this.playback});

  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final queue = playback.queue;
    final currentId = playback.currentSong?.id;
    // Keys ESTABLES por ocurrencia: `id` solo no alcanza (la misma canción
    // puede estar 2+ veces en la cola → keys duplicadas → exception), pero
    // `id+index` rompe el reorder (al soltar el drag, todos los items
    // desplazados cambian de índice → de key → Flutter no los matchea
    // entre frames y la animación de drop glitchea). La key correcta es
    // `id + número de ocurrencia`: la 2ª aparición de la canción X mantiene
    // su key sin importar a qué índice se mueva.
    final occurrence = <String, int>{};
    final keys = List<String>.generate(queue.length, (i) {
      final id = queue[i].id;
      final n = occurrence[id] = (occurrence[id] ?? 0) + 1;
      return 'queue-$id-$n';
    });
    // ReorderableListView en lugar de ListView para soportar el drag &
    // drop por handle. La animación nativa de Material levanta el tile
    // con elevación y desliza el resto suavemente — se siente como
    // una app dedicada de música.
    return ReorderableListView.builder(
      padding: EdgeInsets.zero,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: queue.length,
      // buildDefaultDragHandles: false → no queremos el handle invisible
      // que cubre todo el tile. Nuestro handle es un IconButton específico
      // al final del tile (envuelto en ReorderableDragStartListener).
      buildDefaultDragHandles: false,
      // Proxy "levantado" cuando se está arrastrando: replica el tile
      // sin fondo translúcido y con un borde sutil para que parezca
      // "despegado" del resto de la lista.
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final scheme = Theme.of(context).colorScheme;
            final elevation =
                Curves.easeInOut.transform(animation.value) * 6;
            return Material(
              elevation: elevation,
              color: scheme.surfaceContainerHighest
                  .withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(10),
              child: child,
            );
          },
        );
      },
      // `onReorderItem` (más nuevo) ajusta `newIndex` internamente, pero
      // nuestro `reorderQueue` ya hace ese ajuste explícito + maneja el
      // `_index` activo y la cola original de shuffle. Mantener `onReorder`
      // hasta que migremos toda la lógica al nuevo callback.
      // ignore: deprecated_member_use
      onReorder: playback.reorderQueue,
      itemBuilder: (context, i) {
        final song = queue[i];
        final isCurrent = song.id == currentId;
        return _QueueTile(
          // Key estable por ocurrencia (ver cálculo de `keys` arriba).
          key: ValueKey(keys[i]),
          index: i,
          song: song,
          isCurrent: isCurrent,
          onTap: () => playback.playAt(i),
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.index,
    required this.song,
    required this.isCurrent,
    required this.onTap,
  });

  /// Posición del tile en la cola — necesaria para el
  /// `ReorderableDragStartListener` que envuelve el handle.
  final int index;
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Highlight de la canción activa: fondo ligeramente más oscuro
    // + borde izquierdo de color primary como acento. Hace que el item
    // activo se distinga al instante incluso con scroll rápido.
    final highlightBg = isCurrent
        ? scheme.onSurface.withValues(alpha: 0.08)
        : Colors.transparent;

    return Material(
      color: highlightBg,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: isCurrent
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: scheme.primary,
                      width: 3,
                    ),
                  ),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SongThumbnail(song: song, size: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.equalizer_rounded,
                      size: 18, color: scheme.primary),
                ),
              // Handle de drag — SOLO esta zona inicia el reorder gesture.
              // El resto del tile sigue respondiendo al tap (play). El
              // `ReorderableDragStartListener` es la API oficial para
              // restringir la activación del drag a un sub-widget.
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6),
                  child: Icon(
                    Icons.drag_handle_rounded,
                    size: 22,
                    color: scheme.onSurface.withValues(alpha: 0.45),
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

class _SplitLayout extends StatelessWidget {
  const _SplitLayout({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showLyrics = context.select<LyricsController, bool>(
      (c) => c.showLyrics,
    );
    return Row(
      children: [
        // Player ocupa ~45% — el cover suele ser cuadrado y necesita altura.
        Expanded(
          flex: 45,
          child: _PlayerPanel(playback: playback),
        ),
        Container(
          width: 0.5,
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
        // Panel derecho: alterna entre cola y letra. AnimatedSwitcher
        // hace un fade suave en vez del salto duro.
        Expanded(
          flex: 55,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: showLyrics
                ? const Padding(
                    key: ValueKey('lyrics-panel-wide'),
                    padding: EdgeInsets.all(12),
                    child: LyricsPanel(),
                  )
                : _QueuePanel(
                    key: const ValueKey('queue-panel-wide'),
                    playback: playback,
                  ),
          ),
        ),
      ],
    );
  }
}

class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final song = playback.currentSong!;
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);

    // Cover con toggle Cover ↔ Video — gestionado por
    // VideoAvailabilityController. Si la canción no tiene video o el
    // toggle está OFF, muestra SongThumbnail clásico.
    // RepaintBoundary aísla el coste de repintado del video/imagen del
    // resto del player (transport controls, scrubber, etc.).
    final cover = RepaintBoundary(child: _CoverWithVideoToggle(song: song));

    final title = MarqueeText(
      song.title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );

    final artistStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.7),
          decoration:
              song.artistBrowseId != null ? TextDecoration.underline : null,
        );
    final artist = GestureDetector(
      onTap: () {
        if (song.isStreaming && song.artistBrowseId != null) {
          final browseId = song.artistBrowseId!;
          Navigator.of(context).pop();
          TabNavigation.pushInActiveTab(
            ArtistScreen(browseId: browseId),
            style: settings.transitionStyle,
            durationMs: settings.transitionDurationMs,
          );
        }
      },
      child: MarqueeText(
        song.artist,
        style: artistStyle,
      ),
    );

    return _WideCoverWithControls(
      cover: cover,
      playback: playback,
      title: title,
      artist: artist,
      radius: tokens.radiusLg,
      outerPadding: EdgeInsets.all(tokens.gap),
    );
  }
}

/// Overlay del panel de lyrics en portrait: scrim oscuro sobre el cover +
/// LyricsPanel encima. La carátula queda visible como "lienzo" detrás de
/// las líneas, en lugar de desaparecer. El scrim garantiza legibilidad
/// aunque la portada sea muy brillante o de colores complejos.
class _LyricsOverlay extends StatelessWidget {
  const _LyricsOverlay({super.key, required this.radius});
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Scrim con el color `surface` del tema (que ya viene del album
          // palette procesado por AppThemeBuilder). El gradient vertical
          // tiene el centro más opaco para que la línea activa tenga
          // mejor fondo que las pasadas/futuras de los bordes.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surface.withValues(alpha: 0.78),
                  scheme.surface.withValues(alpha: 0.92),
                  scheme.surface.withValues(alpha: 0.78),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: LyricsPanel(transparent: true),
          ),
        ],
      ),
    );
  }
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({super.key, required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            tokens.space(20),
            tokens.gap,
            tokens.space(20),
            tokens.gapSm,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Cola',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
            ),
          ),
        ),
        ResponsiveSongSliverGrid(
          songs: playback.queue,
          minTileWidth: settings.songTileMinWidth,
          selectedSongId: playback.currentSong?.id,
          onTap: (song, _) async {
            final i = playback.queue.indexOf(song);
            if (i >= 0) await playback.playAt(i);
          },
        ),
        SliverToBoxAdapter(child: SizedBox(height: tokens.gapLg)),
      ],
    );
  }
}

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

/// Cover del PlayerScreen con toggle "Cover ↔ Video" overlay arriba-derecha
/// cuando hay music video disponible para la canción.
///
/// Dispara `videoAvailability.ensureChecked(streamingId)` para precargar la
/// verificación al entrar. El botón solo aparece cuando se confirma que hay
/// video — sin esto al usuario le aparecía/desaparecía un toggle según el
/// resultado tardío del check (mala UX).
class _CoverWithVideoToggle extends StatelessWidget {
  const _CoverWithVideoToggle({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final availability = context.watch<VideoAvailabilityController>();

    // Para canciones no-streaming no hay videoId que checkear → cover normal.
    final videoId = song.streamingId;
    if (videoId == null) {
      return SongThumbnail(song: song);
    }

    // Dispara la verificación si aún no se hizo. Idempotente.
    if (!availability.isChecked(videoId)) {
      // ignore: discarded_futures
      availability.ensureChecked(videoId);
    }

    final hasVideo = availability.isAvailable(videoId);
    final showVideo = hasVideo && availability.showAsCover;

    // El toggle Cover ↔ Video ya no se monta encima de la portada — vive
    // en el AppBar junto a los botones de cola y letra. Aquí solo
    // decidimos qué media renderizar según el flag.
    return showVideo ? const MusicVideoCover() : SongThumbnail(song: song);
  }
}

/// Wrapper de UN NIVEL ARRIBA del cover que añade el "lado B" con info
/// técnica + metadata. Reemplaza la fila de chips que vivía debajo del
/// título — el usuario reportó que se amontonaban en vertical y
/// empujaban el resto del layout.
///
/// Presentación según [shape]:
///   - **square**: card flip 3D al hacer swipe horizontal o tap del
///     botón "i". El back del card es el [CoverInfoPanel] compacto. Swipe
///     o tap de nuevo voltea de regreso.
///   - **cd / holográfico**: el cover gira (CD) o tiene shader (holo) —
///     un flip 3D adicional pelearía con esas animaciones. En su lugar,
///     swipe o botón "i" abren un bottom sheet con el [CoverInfoPanel]
///     en tamaño completo, con X o tap-fuera para cerrar.
///
/// El botón "i" se oculta cuando [showInfoButton] es false (típicamente
/// cuando el cover está en modo banner/mini durante queue expandido).
class _FlippableCover extends StatefulWidget {
  const _FlippableCover({
    required this.song,
    required this.front,
    required this.shape,
    required this.borderRadius,
    this.showInfoButton = true,
    this.onInfoVisibilityChanged,
  });

  /// La canción actual — el panel necesita acceso a metadata.
  final Song song;

  /// La carátula ya envuelta en su shape (output de [_ShapedCover]).
  final Widget front;

  /// Forma actual — define si se flipea o se abre sheet.
  final CoverShape shape;

  /// Border radius para el back del card flip (debe matchear el del front).
  final BorderRadius borderRadius;

  /// Mostrar el botón "i" arriba-derecha del cover. Falso cuando el
  /// cover está en modo mini (queue expandido), porque no hay espacio
  /// visual claro para el botón.
  final bool showInfoButton;

  /// Callback que dispara con `true` cuando el panel de info aparece
  /// (back del card o sheet abierto) y `false` cuando vuelve a estado
  /// neutral. Útil para que el parent oculte controles que tapen el
  /// panel (caso horizontal — la card de controles overlay del cover
  /// bloqueaba la info reportado por el usuario).
  final ValueChanged<bool>? onInfoVisibilityChanged;

  @override
  State<_FlippableCover> createState() => _FlippableCoverState();
}

class _FlippableCoverState extends State<_FlippableCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flipCtrl;
  bool _showingBack = false;

  @override
  void initState() {
    super.initState();
    _flipCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 540),
    );
  }

  @override
  void dispose() {
    _flipCtrl.dispose();
    super.dispose();
  }

  void _onTrigger() {
    if (widget.shape == CoverShape.square) {
      _flipCard();
    } else {
      _openSheet();
    }
  }

  void _flipCard() {
    setState(() => _showingBack = !_showingBack);
    if (_showingBack) {
      _flipCtrl.forward();
    } else {
      _flipCtrl.reverse();
    }
    widget.onInfoVisibilityChanged?.call(_showingBack);
  }

  Future<void> _openSheet() async {
    // Capturamos providers/notifiers ANTES del showModalBottomSheet —
    // dentro del builder el context es nuevo (root navigator) y no
    // hereda el provider tree del player_screen.
    final playback = context.read<PlaybackController>();
    final settings = context.read<SettingsController>();

    // Avisamos al parent que la info está visible — el horizontal usa
    // esto para ocultar la card de controles que tapaba el sheet.
    widget.onInfoVisibilityChanged?.call(true);
    final mq = MediaQuery.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Root navigator: que el sheet quede sobre el queue handle y la
      // bottom bar de Home.
      useRootNavigator: true,
      builder: (ctx) {
        // Re-inyectamos los providers que el panel necesita.
        return MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: settings),
          ],
          builder: (ctx, _) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  bottom: 16 + mq.viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  // Limitar altura para que no tape toda la pantalla en
                  // tablets. 75% del alto disponible es el límite.
                  constraints: BoxConstraints(
                    maxHeight: mq.size.height * 0.75,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      // Frosted glass — match el resto de sheets de la app.
                      filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: ColoredBox(
                        color: Theme.of(ctx)
                            .colorScheme
                            .surface
                            .withValues(alpha: 0.75),
                        child: CoverInfoPanel(
                          song: widget.song,
                          compact: false,
                          onDismiss: () => Navigator.of(ctx).pop(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    // Sheet cerrado (por X, drag-down o tap-outside): notificamos
    // que la info ya no está visible.
    if (!mounted) return;
    widget.onInfoVisibilityChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Swipe horizontal en cualquier dirección dispara el trigger.
      // Threshold por velocidad → swipes lentos no disparan (el usuario
      // puede estar arrastrando el cover sin intención de voltearlo).
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() > 280) _onTrigger();
      },
      // behavior: opaque para que el tap NO interfiera con el child
      // (video toggle, tap para play). El swipe solo activa con velocity.
      behavior: HitTestBehavior.deferToChild,
      // `StackFit.expand` CRÍTICO: sin esto el child del front (la
      // carátula) se sizea a su contenido natural y NO llena el SizedBox
      // que define el contenedor padre. Síntoma reportado: en estado 1
      // (banner) el cover quedaba pegado a la izquierda con espacio
      // vacío a la derecha porque ni el cover ni el `_ShapedCover`
      // tienen sizing intrínseco que ocupe el ancho disponible.
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Para shape != square, el child es solo el cover.
          // Para square, alternamos front/back con flip 3D.
          if (widget.shape == CoverShape.square)
            _buildFlipping()
          else
            widget.front,

          if (widget.showInfoButton)
            Positioned(
              top: 10,
              right: 10,
              child: _CoverInfoButton(
                isShowingBack: _showingBack,
                onTap: _onTrigger,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFlipping() {
    return AnimatedBuilder(
      animation: _flipCtrl,
      builder: (context, _) {
        // 0 → pi rotación Y. En 0..π/2 mostramos front; en π/2..π mostramos back.
        final angle = _flipCtrl.value * math.pi;
        final showingFront = _flipCtrl.value < 0.5;
        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0012) // perspective
          ..rotateY(angle);
        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: showingFront
              ? widget.front
              : Transform(
                  // El back está pre-rotado 180° para que cuando lo
                  // veamos (con la card rotada >90°) salga orientado
                  // correctamente, no espejado.
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(math.pi),
                  child: _buildBackCard(),
                ),
        );
      },
    );
  }

  Widget _buildBackCard() {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.85),
            border: Border.all(
              color: scheme.outline.withValues(alpha: 0.25),
            ),
            borderRadius: widget.borderRadius,
          ),
          child: CoverInfoPanel(
            song: widget.song,
            compact: true,
          ),
        ),
      ),
    );
  }
}

/// Botón "i" semi-transparente en la esquina del cover. Cambia el icono
/// según si el front o el back están visibles para que el usuario sepa
/// qué hace tap.
class _CoverInfoButton extends StatelessWidget {
  const _CoverInfoButton({
    required this.isShowingBack,
    required this.onTap,
  });

  final bool isShowingBack;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Icon(
            isShowingBack
                ? Icons.close_rounded
                : Icons.info_outline_rounded,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Aplica el wrapper de forma de carátula según el [shape] elegido por el
/// usuario en ajustes. Centraliza el branching aquí para que el render
/// principal del player_screen no tenga conditionals dispersos.
class _ShapedCover extends StatelessWidget {
  const _ShapedCover({
    required this.shape,
    required this.radius,
    required this.isPlaying,
    required this.child,
    this.holoTiltIntensity = 1.0,
    this.holoParallaxIntensity = 1.0,
  });

  final CoverShape shape;
  final BorderRadius radius;
  final bool isPlaying;
  final Widget child;

  /// Intensidad del tilt 3D cuando [shape] es holográfico. Permite al
  /// caller (portrait con queue expandido) apagar el tilt sin tocar el
  /// resto del shader.
  final double holoTiltIntensity;

  /// Intensidad del parallax del shader (shift de bandas iridiscentes
  /// con el ángulo del device). Independiente del tilt 3D.
  final double holoParallaxIntensity;

  @override
  Widget build(BuildContext context) {
    switch (shape) {
      case CoverShape.square:
        return ClipRRect(borderRadius: radius, child: child);
      case CoverShape.cd:
        // El disco usa su propio ClipPath (annulus). Sigue girando solo
        // cuando hay reproducción para reforzar la metáfora analógica.
        return CdCoverWrapper(spinning: isPlaying, child: child);
      case CoverShape.holographic:
        // Paleta-aware: el shader interpola entre 3 colores del album
        // (primary, secondary, tertiary del ColorScheme derivado del
        // PaletteSignal) → el holo viste la portada en tonos del track,
        // no en un rainbow neón ajeno.
        final scheme = Theme.of(context).colorScheme;
        return HolographicCoverWrapper(
          borderRadius: radius,
          color1: scheme.primary,
          color2: scheme.secondary,
          color3: scheme.tertiary,
          tiltIntensity: holoTiltIntensity,
          parallaxIntensity: holoParallaxIntensity,
          child: child,
        );
    }
  }
}

