import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/animations/parallax_controller.dart';
import '../core/settings/ui_settings.dart';
import '../services/blurred_background.dart';
import 'customized_background.dart';
import 'frosted_sampler.dart';

/// Superficie frosted glass reutilizable — el "ladrillo" base de todo el
/// sistema de cristal de la app (cards, tab bars, search fields, headers...).
///
/// **Patrón** (mismo que [GlassCard], extraído para que cualquier widget pueda
/// usarlo sin recrear la maquinaria):
///   1. `BlurredBackgroundService` pre-renderea el bg blureado UNA vez a una
///      `ui.Image`.
///   2. Esta superficie sampla el sub-rect que cae detrás de ella vía
///      `RenderBox.localToGlobal` + [FrostedSamplerPainter].
///   3. El painter se invalida cuando:
///       - cambia el offset de parallax,
///       - cambia el offset del Scrollable ancestro (si está dentro de uno),
///       - cambia la imagen pre-blureada.
///
/// **Por qué no `BackdropFilter`**: BackdropFilter samplea el backdrop en
/// tiempo real → en listas virtualizadas / sub-rutas dispara "warmup flash"
/// al entrar al viewport y "sticky" cuando la card se mueve. El sampler es
/// estable y mucho más barato.
///
/// Si el usuario tiene `cardBlurEnabled = false` o no hay `BlurredBackgroundService`,
/// la superficie cae al tinte sólido — el resto del estilo (border, radius)
/// se mantiene idéntico.
class FrostedSurface extends StatefulWidget {
  const FrostedSurface({
    super.key,
    this.child,
    this.borderRadius,
    this.border,
    this.tintScale = 1.0,
    this.tintOverride,
    this.clipBehavior = Clip.antiAlias,
  });

  /// Contenido dibujado encima del sample + tinte.
  final Widget? child;

  /// Radio de las esquinas. Si es null no se clipea.
  final BorderRadiusGeometry? borderRadius;

  /// Borde dibujado en foreground (encima del clipping) para que el hairline
  /// no quede cortado por las esquinas redondeadas.
  final BoxBorder? border;

  /// Multiplicador sobre el alpha del tinte. Útil para superficies que
  /// requieren más "densidad" que las cards (tab bars, headers) sin redefinir
  /// el sistema de tintes.
  final double tintScale;

  /// Sobreescribe completamente el tinte calculado del theme. Si se pasa,
  /// [tintScale] se ignora.
  final Color? tintOverride;

  /// Comportamiento del clipping cuando hay borderRadius. Por defecto
  /// antiAlias para mantener bordes suaves.
  final Clip clipBehavior;

  @override
  State<FrostedSurface> createState() => _FrostedSurfaceState();
}

class _FrostedSurfaceState extends State<FrostedSurface> {
  // GlobalKey para que el painter pueda resolver la posición global de la
  // superficie en pantalla cada repaint vía `findRenderObject`.
  final GlobalKey _renderKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);
    final blurService =
        Provider.of<BlurredBackgroundService?>(context, listen: false);

    final useFrosted = settings.cardBlurEnabled &&
        settings.cardBlurIntensity > 0 &&
        blurService != null;

    final baseAlpha = settings.effectiveSurfaceOpacity;
    // Tint del color del tema (accent del album palette procesado por
    // AppThemeBuilder) en lugar de un neutro `onSurface`/`surface`. Así
    // las cards toman la "vibra" del album: portada amarilla → cards
    // con tinte amarillo, portada azul → cards con tinte azul.
    //
    // Cuando frosted está activo, el sampler del bg blureado ya pinta el
    // "fondo" de la card → el tint solo añade un velo de color sobre eso.
    // Antes lo escalábamos × 0.12 → el slider de surface solo movía el
    // alpha entre 3.6% (slider en 0.3) y 12% (en 1.0). Diferencia
    // imperceptible. Subido a 0.40 para que el slider tenga rango útil:
    // ~12% en mínimo, 40% en máximo — un cambio visible y graduado.
    final tintBase = scheme.primary;
    final rawAlpha =
        (useFrosted ? baseAlpha * 0.40 : baseAlpha) * widget.tintScale;
    final tint = widget.tintOverride ??
        tintBase.withValues(alpha: rawAlpha.clamp(0.0, 1.0));

    final parallax =
        Provider.of<ParallaxController>(context, listen: false);
    final parallaxIntensity = settings.parallaxEnabled
        ? settings.parallaxIntensity.clamp(0.0, 1.0)
        : 0.0;

    // El Stack se dimensiona a su child NO-positionado (el `widget.child` si
    // existe). El sampler va con Positioned.fill para estirarse a ese tamaño.
    // Esto preserva intrinsic sizing — útil para GlassCard, que se autoajusta
    // a su contenido. Si el caller no pasa child, debe envolver él mismo en
    // un SizedBox/Expanded para darle tamaño.
    Widget body = Stack(
      key: _renderKey,
      children: [
        if (useFrosted)
          Positioned.fill(
            child: _SamplerLayer(
              service: blurService,
              tint: tint,
              parallaxOffsetListenable: parallax.offset,
              parallaxIntensity: parallaxIntensity,
              getBox: () =>
                  _renderKey.currentContext?.findRenderObject() as RenderBox?,
            ),
          )
        else
          Positioned.fill(child: ColoredBox(color: tint)),
        if (widget.child != null) widget.child!,
      ],
    );

    if (widget.borderRadius != null) {
      body = ClipRRect(
        borderRadius: widget.borderRadius!,
        clipBehavior: widget.clipBehavior,
        child: body,
      );
    }

    if (widget.border != null) {
      // El border va en foreground para que NO se clipee con el borderRadius
      // del ClipRRect — Material 3 hairline pattern.
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius is BorderRadius
              ? widget.borderRadius as BorderRadius
              : null,
          border: widget.border,
        ),
        position: DecorationPosition.foreground,
        child: body,
      );
    }

    return body;
  }
}

/// Capa que muestra el bg pre-blureado samplado por la posición del widget.
/// Compartida por [FrostedSurface] y (transitivamente) por todas las cards y
/// elementos de chrome de la app.
///
/// **Repaint signal**: el painter se invalida con la unión de:
///   - `ScrollPosition` del Scrollable ancestro (si existe) → cubre el caso
///     "card scrolleando dentro de un ListView".
///   - `ValueListenable<Offset>` del parallax → cubre el caso "el bg se mueve
///     por inclinación del dispositivo".
class _SamplerLayer extends StatelessWidget {
  const _SamplerLayer({
    required this.service,
    required this.tint,
    required this.parallaxOffsetListenable,
    required this.parallaxIntensity,
    required this.getBox,
  });

  final BlurredBackgroundService service;
  final Color tint;
  final ValueListenable<Offset> parallaxOffsetListenable;
  final double parallaxIntensity;
  final RenderBox? Function() getBox;

  @override
  Widget build(BuildContext context) {
    // El painter computa la posición global de la superficie dentro de
    // `paint()` con `RenderBox.localToGlobal`. Eso NO es una prop → sin una
    // señal externa el painter no se entera de que la card scrolleó. Por eso
    // nos suscribimos al ScrollPosition del ancestro.
    final scrollable = Scrollable.maybeOf(context);
    final Listenable? scrollListenable = scrollable?.position;

    return ValueListenableBuilder<ui.Image?>(
      valueListenable: service.blurred,
      builder: (context, img, _) {
        if (img == null) {
          // Aún no se generó el pre-render — fallback a tinte sólido.
          return ColoredBox(color: tint);
        }
        if (parallaxIntensity <= 0) {
          return CustomPaint(
            painter: FrostedSamplerPainter(
              blurredBg: img,
              screenSize: MediaQuery.sizeOf(context),
              tint: tint,
              getBox: getBox,
              repaintWhen: scrollListenable,
            ),
            size: Size.infinite,
          );
        }
        return ValueListenableBuilder<Offset>(
          valueListenable: parallaxOffsetListenable,
          builder: (context, offset, _) {
            return CustomPaint(
              painter: FrostedSamplerPainter(
                blurredBg: img,
                screenSize: MediaQuery.sizeOf(context),
                tint: tint,
                getBox: getBox,
                parallaxOffset: offset * parallaxIntensity,
                maxPx: CustomizedBackground.kMaxParallaxPx,
                overscale: CustomizedBackground.kParallaxOverscale,
                repaintWhen: scrollListenable,
              ),
              size: Size.infinite,
            );
          },
        );
      },
    );
  }
}
