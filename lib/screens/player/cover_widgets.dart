// Cover: video toggle, card-flip de info y shaped covers.
//
// `part` de player_screen.dart: las clases del player comparten
// estado privado entre sí, así que viven en una sola librería
// partida en archivos por concern (imports en el archivo raíz).
part of '../player_screen.dart';

/// Cover del PlayerScreen con toggle "Cover ↔ Video" overlay arriba-derecha
/// cuando hay music video disponible para la canción.
///
/// Dispara `videoAvailability.ensureChecked(streamingId)` para precargar la
/// verificación al entrar. El botón solo aparece cuando se confirma que hay
/// video — sin esto al usuario le aparecía/desaparecía un toggle según el
/// resultado tardío del check (mala UX).
class _CoverWithVideoToggle extends StatelessWidget {
  const _CoverWithVideoToggle({
    required this.song,
    this.fullscreenButtonAtTopLeft = false,
  });

  final Song song;

  /// Posición del botón de pantalla completa. En el layout HORIZONTAL la
  /// `_HorizontalControlsCard` se monta al fondo del cover y tapaba el
  /// botón abajo-derecha → ahí lo movemos arriba-izquierda. En portrait
  /// los controles van debajo del cover, así que abajo-derecha está libre.
  final bool fullscreenButtonAtTopLeft;

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
    if (!showVideo) return SongThumbnail(song: song);

    // Video activo: cover de video + botón de pantalla completa. El botón
    // SOLO aparece cuando se muestra video (no en modo carátula estática).
    return Stack(
      fit: StackFit.expand,
      children: [
        const MusicVideoCover(),
        Positioned(
          left: fullscreenButtonAtTopLeft ? 10 : null,
          right: fullscreenButtonAtTopLeft ? null : 10,
          top: fullscreenButtonAtTopLeft ? 10 : null,
          bottom: fullscreenButtonAtTopLeft ? null : 10,
          child: _FullscreenVideoButton(),
        ),
      ],
    );
  }
}

/// Botón que abre el music video a pantalla completa con controles.
/// Vive abajo-derecha del cover cuando hay video activo.
class _FullscreenVideoButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          final s = UiSettingsScope.of(context);
          Navigator.of(context, rootNavigator: true).pushAnimated(
            const VideoFullscreenScreen(),
            style: s.transitionStyle,
            durationMs: s.transitionDurationMs,
          );
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: const Icon(
            Icons.fullscreen_rounded,
            size: 22,
            color: Colors.white,
          ),
        ),
      ),
    );
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
