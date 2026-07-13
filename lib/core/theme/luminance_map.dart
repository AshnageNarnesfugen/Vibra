import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Mapa de luminancia downsampled del fondo de la app. Cada celda contiene
/// la luminancia promedio (0..255) de su región del bg, en coordenadas
/// normalizadas (0..1).
///
/// Sirve para que widgets individuales decidan su color de tinta (claro u
/// oscuro) según lo que tienen DETRÁS específicamente — no según el promedio
/// global. Resuelve el caso: portada con cielo brillante arriba y bosque
/// oscuro abajo → un botón arriba se ve mal en blanco, uno abajo se ve mal
/// en negro. Con esta utilidad, cada uno se adapta a SU área.
///
/// Granularidad por defecto: 16x16 = 256 celdas. Sampleo cheap (O(N) con N
/// pequeño en `avgInNormRect`) y suficiente para discriminar las zonas
/// típicas del UI (mini-player, AppBar, bottom nav).
@immutable
class LuminanceMap {
  const LuminanceMap(this.grid, this.cols, this.rows);

  final Uint8List grid;
  final int cols;
  final int rows;

  static const _defaultDim = 16;

  /// Luma GAMMA-space (0..1) de un color — la MISMA escala que produce el
  /// sampleo de imagen en [fromImage] (BT.601 sobre bytes sRGB crudos).
  ///
  /// ⚠️ NO usar `computeLuminance()` para poblar el grid: esa devuelve
  /// luminancia LINEAL (mid-gray sRGB ≈ 0.216) mientras el path de imagen
  /// produce luma gamma (mid-gray ≈ 0.5). Mezclar ambas escalas hacía que
  /// el threshold de AdaptiveColor significara cosas distintas según si el
  /// fondo era sólido/gradiente o imagen → fondos sólidos claros
  /// clasificados como "oscuros" → tinta blanca ilegible.
  static double gammaLuma(Color c) =>
      0.299 * c.r + 0.587 * c.g + 0.114 * c.b;

  /// Map uniforme con la luminancia del color dado. Lo usamos cuando el
  /// bg es un sólido (no necesitamos sampleo real).
  factory LuminanceMap.uniform(Color color, {int dim = _defaultDim}) {
    final lum = (gammaLuma(color) * 255).round().clamp(0, 255);
    final cells = dim * dim;
    return LuminanceMap(
      Uint8List.fromList(List.filled(cells, lum)),
      dim,
      dim,
    );
  }

  /// Map de un gradiente vertical entre los colores dados (top → bottom).
  /// Aproximación buena para shaders animados sin pagar el coste real de
  /// renderizarlos y muestrearlos.
  factory LuminanceMap.gradient(List<Color> colors,
      {int dim = _defaultDim}) {
    if (colors.isEmpty) return LuminanceMap.uniform(Colors.black, dim: dim);
    if (colors.length == 1) return LuminanceMap.uniform(colors.first, dim: dim);
    final grid = Uint8List(dim * dim);
    for (var r = 0; r < dim; r++) {
      final t = r / (dim - 1);
      // Mezcla lineal entre los colores según `t`.
      final pos = t * (colors.length - 1);
      final i = pos.floor().clamp(0, colors.length - 1);
      final j = (i + 1).clamp(0, colors.length - 1);
      final localT = pos - i;
      final c = Color.lerp(colors[i], colors[j], localT)!;
      final lum = (gammaLuma(c) * 255).round().clamp(0, 255);
      for (var col = 0; col < dim; col++) {
        grid[r * dim + col] = lum;
      }
    }
    return LuminanceMap(grid, dim, dim);
  }

  /// Construye el map desde una [ui.Image] muestreando con [toByteData].
  /// Operación pesada (proporcional al área de la imagen) — usar solo
  /// cuando el bg cambia, no por frame.
  static Future<LuminanceMap?> fromImage(ui.Image image,
      {int dim = _defaultDim}) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final bytes = data.buffer.asUint8List();
      final w = image.width;
      final h = image.height;
      if (w <= 0 || h <= 0) return null;

      final grid = Uint8List(dim * dim);
      // Cada celda promedia los pixels de su sub-rect en la imagen.
      // Para velocidad muestreamos un sub-grid de pixels (no todos).
      const samplesPerCell = 4; // 4x4 = 16 samples por celda.
      for (var ry = 0; ry < dim; ry++) {
        final y0 = (ry * h ~/ dim).clamp(0, h - 1);
        final y1 = (((ry + 1) * h ~/ dim) - 1).clamp(0, h - 1);
        final yStep = ((y1 - y0) ~/ samplesPerCell).clamp(1, h);
        for (var rx = 0; rx < dim; rx++) {
          final x0 = (rx * w ~/ dim).clamp(0, w - 1);
          final x1 = (((rx + 1) * w ~/ dim) - 1).clamp(0, w - 1);
          final xStep = ((x1 - x0) ~/ samplesPerCell).clamp(1, w);
          int sum = 0, count = 0;
          for (var y = y0; y <= y1; y += yStep) {
            for (var x = x0; x <= x1; x += xStep) {
              final idx = (y * w + x) * 4;
              if (idx + 3 >= bytes.length) continue;
              final r = bytes[idx];
              final g = bytes[idx + 1];
              final b = bytes[idx + 2];
              // Luminancia ITU-R BT.601 (rápida; BT.709 sería más correcta
              // pero la diferencia es imperceptible para nuestro uso).
              sum += (r * 299 + g * 587 + b * 114) ~/ 1000;
              count++;
            }
          }
          grid[ry * dim + rx] = count == 0 ? 128 : (sum ~/ count);
        }
      }
      return LuminanceMap(grid, dim, dim);
    } catch (_) {
      return null;
    }
  }

  /// Estadísticas de luminancia del rect normalizado: promedio + mínimo +
  /// máximo de las celdas cubiertas (todo en 0..1, escala gamma).
  ///
  /// El min/max permite detectar fondos MIXTOS (mitad cielo claro, mitad
  /// sombra) donde el promedio miente: avg=0.5 sugiere "gris medio" pero
  /// en realidad ninguna tinta única funciona sobre toda el área. El
  /// consumidor (AdaptiveColor) usa el rango para decidir si necesita un
  /// halo de protección detrás del contenido.
  ({double avg, double min, double max}) statsInNormRect(Rect r) {
    final c0 = (r.left * cols).clamp(0.0, cols.toDouble()).floor();
    final c1 = (r.right * cols).clamp(0.0, cols.toDouble()).ceil();
    final r0 = (r.top * rows).clamp(0.0, rows.toDouble()).floor();
    final r1 = (r.bottom * rows).clamp(0.0, rows.toDouble()).ceil();
    if (c1 <= c0 || r1 <= r0) {
      final v = avgInNormRect(r);
      return (avg: v, min: v, max: v);
    }
    int sum = 0, count = 0, lo = 255, hi = 0;
    for (var row = r0; row < r1; row++) {
      for (var col = c0; col < c1; col++) {
        final v = grid[row * cols + col];
        sum += v;
        count++;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (count == 0) return (avg: 0.5, min: 0.5, max: 0.5);
    return (avg: (sum / count) / 255.0, min: lo / 255.0, max: hi / 255.0);
  }

  /// Luminancia promedio (0..1) del rect normalizado (todos sus componentes
  /// en [0..1] respecto al bg completo).
  double avgInNormRect(Rect r) {
    final c0 = (r.left * cols).clamp(0.0, cols.toDouble()).floor();
    final c1 = (r.right * cols).clamp(0.0, cols.toDouble()).ceil();
    final r0 = (r.top * rows).clamp(0.0, rows.toDouble()).floor();
    final r1 = (r.bottom * rows).clamp(0.0, rows.toDouble()).ceil();
    if (c1 <= c0 || r1 <= r0) {
      // Rect degenerado — devolvemos el sample del centro.
      final cx = ((r.left + r.right) / 2 * cols)
          .clamp(0.0, cols - 1.0)
          .floor();
      final cy = ((r.top + r.bottom) / 2 * rows)
          .clamp(0.0, rows - 1.0)
          .floor();
      return grid[cy * cols + cx] / 255.0;
    }
    int sum = 0, count = 0;
    for (var row = r0; row < r1; row++) {
      for (var col = c0; col < c1; col++) {
        sum += grid[row * cols + col];
        count++;
      }
    }
    return count == 0 ? 0.5 : (sum / count) / 255.0;
  }
}
