import 'package:flutter/material.dart';

/// Helpers de contraste basados en WCAG (relative luminance + ratio).
///
/// El objetivo es: dado un fondo arbitrario, devolver un color de texto/acento
/// que mantenga legibilidad (>= 4.5:1 cuando es posible).
class ContrastUtils {
  /// Luminancia relativa según WCAG 2.x.
  static double relativeLuminance(Color c) => c.computeLuminance();

  /// Ratio de contraste WCAG entre dos colores. Devuelve un valor en [1, 21].
  static double contrastRatio(Color a, Color b) {
    final la = relativeLuminance(a);
    final lb = relativeLuminance(b);
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Devuelve blanco o negro, lo que mejor contraste con [bg].
  static Color onColorFor(Color bg) {
    return relativeLuminance(bg) > 0.5
        ? const Color(0xFF0A0A0A)
        : const Color(0xFFFFFFFF);
  }

  /// Ajusta [foreground] sobre [background] hasta alcanzar [target] de
  /// contraste, oscureciendo o aclarando según convenga. Si no se puede,
  /// cae a blanco/negro.
  static Color ensureReadable(
    Color foreground,
    Color background, {
    double target = 4.5,
  }) {
    if (contrastRatio(foreground, background) >= target) return foreground;

    final hsl = HSLColor.fromColor(foreground);
    final bgIsDark = relativeLuminance(background) < 0.5;
    // Empujamos lightness en la dirección que aumenta contraste.
    for (var i = 1; i <= 20; i++) {
      final l = bgIsDark
          ? (hsl.lightness + 0.05 * i).clamp(0.0, 1.0)
          : (hsl.lightness - 0.05 * i).clamp(0.0, 1.0);
      final candidate = hsl.withLightness(l).toColor();
      if (contrastRatio(candidate, background) >= target) return candidate;
    }
    return onColorFor(background);
  }

  /// Mezcla [a] con [b] al [t] (0..1). Útil para superficies derivadas.
  static Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
}
