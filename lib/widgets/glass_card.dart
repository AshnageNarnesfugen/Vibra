import 'package:flutter/material.dart';

import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';
import 'frosted_surface.dart';
import 'noise_painter.dart';

/// Tarjeta frosted glass — wrapper sobre [FrostedSurface] que añade:
///   - Padding del sistema de tokens.
///   - InkWell (ripple en tap).
///   - Noise layer opcional según `settings.cardNoiseIntensity`.
///   - Hairline border + radius del sistema.
///
/// Toda la magia del frosted (sample del bg pre-blureado, parallax, repaint
/// en scroll) vive en [FrostedSurface] — ver ese archivo para el detalle del
/// patrón. Acá solo componemos el "estilo card" sobre esa superficie.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);

    // Border hairline para que la card sea visible incluso cuando el frosted
    // sobre bg uniforme la deja casi indistinguible. Material 3 usa
    // `outlineVariant` para este patrón.
    final border = Border.all(
      color: scheme.outlineVariant.withValues(alpha: 0.55),
      width: 0.5,
    );

    return FrostedSurface(
      borderRadius: tokens.radius,
      border: border,
      child: Stack(
        children: [
          // Noise opcional: Positioned.fill para que se estire al tamaño que
          // define el Material (non-positioned). Z-order: detrás del contenido.
          if (settings.cardNoiseIntensity > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: NoiseLayer(intensity: settings.cardNoiseIntensity),
              ),
            ),
          // Material es el non-positioned child → dimensiona el Stack al
          // contenido. Color transparente para no tapar el sampler/noise.
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: padding ?? tokens.cardPadding(),
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
