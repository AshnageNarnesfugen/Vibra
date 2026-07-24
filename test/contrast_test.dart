import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:vibra/core/theme/contrast.dart';

void main() {
  group('ContrastUtils', () {
    test('contrastRatio: blanco sobre negro es 21:1', () {
      final ratio = ContrastUtils.contrastRatio(
        const Color(0xFFFFFFFF),
        const Color(0xFF000000),
      );
      expect(ratio, closeTo(21.0, 0.1));
    });

    test('contrastRatio es simétrico', () {
      const a = Color(0xFF3366AA);
      const b = Color(0xFFDDEEFF);
      expect(
        ContrastUtils.contrastRatio(a, b),
        ContrastUtils.contrastRatio(b, a),
      );
    });

    test('onColorFor elige blanco sobre fondos oscuros y negro sobre claros',
        () {
      final onDark = ContrastUtils.onColorFor(const Color(0xFF101015));
      final onLight = ContrastUtils.onColorFor(const Color(0xFFF6F6F8));
      expect(onDark.computeLuminance(), greaterThan(0.5));
      expect(onLight.computeLuminance(), lessThan(0.5));
    });

    test('ensureReadable alcanza el ratio pedido contra el fondo', () {
      // Un gris casi idéntico al fondo — ilegible sin corrección.
      const bg = Color(0xFF202020);
      const fg = Color(0xFF303030);
      final fixed = ContrastUtils.ensureReadable(fg, bg, target: 4.5);
      expect(
        ContrastUtils.contrastRatio(fixed, bg),
        greaterThanOrEqualTo(4.4), // margen numérico pequeño
      );
    });

    test('ensureReadable no toca colores que ya cumplen', () {
      const bg = Color(0xFF000000);
      const fg = Color(0xFFFFFFFF);
      final result = ContrastUtils.ensureReadable(fg, bg, target: 4.5);
      expect(result, fg);
    });

    test('mix interpola entre los dos extremos', () {
      const a = Color(0xFF000000);
      const b = Color(0xFFFFFFFF);
      expect(ContrastUtils.mix(a, b, 0), a);
      expect(ContrastUtils.mix(a, b, 1), b);
    });
  });
}
