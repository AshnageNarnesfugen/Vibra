// Layout vertical: cover + metadata + transport + cola integrada.
//
// `part` de player_screen.dart: las clases del player comparten
// estado privado entre sí, así que viven en una sola librería
// partida en archivos por concern (imports en el archivo raíz).
part of '../player_screen.dart';

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

    // Hold sobre el título → menú de contexto de la canción (mismo gesto
    // que en las listas). El botón ⋮ del AppBar hace lo mismo.
    final title = GestureDetector(
      onLongPress: () => showSongContextSheet(context, songs: [song]),
      child: MarqueeText(
        song.title,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
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
