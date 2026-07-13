import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../core/dev_log.dart';

/// Resultado de samplear un frame de video: los 4 colores de las esquinas
/// + el promedio. Modelados como una struct para que el caller los use
/// flexiblemente (gradiente desde las esquinas, paleta para tema, etc.).
@immutable
class VideoEdgeSample {
  const VideoEdgeSample({
    required this.topLeft,
    required this.topRight,
    required this.bottomLeft,
    required this.bottomRight,
    required this.average,
  });

  final Color topLeft;
  final Color topRight;
  final Color bottomLeft;
  final Color bottomRight;
  final Color average;

  /// Interpolación lineal entre dos samples por cada esquina.
  VideoEdgeSample lerpTo(VideoEdgeSample other, double t) {
    return VideoEdgeSample(
      topLeft: Color.lerp(topLeft, other.topLeft, t)!,
      topRight: Color.lerp(topRight, other.topRight, t)!,
      bottomLeft: Color.lerp(bottomLeft, other.bottomLeft, t)!,
      bottomRight: Color.lerp(bottomRight, other.bottomRight, t)!,
      average: Color.lerp(average, other.average, t)!,
    );
  }
}

/// Captura un frame del [RepaintBoundary] cuya [GlobalKey] se pasa y
/// extrae el color promedio de cada esquina + el global.
///
/// Costo: `toImage(pixelRatio: 0.12)` para tener una imagen MUY pequeña
/// (típicamente ~60-80px de lado), seguido de `toByteData(rawRgba)` y
/// sampleo de las 4 esquinas. En total ~5-15ms en hardware mid-range —
/// barato si se llama cada 1.5-2s, prohibitivo si fuera por frame.
///
/// Used by `AmbientVideoPaletteService` para alimentar la "iluminación
/// cinematográfica" (ambient mode estilo YouTube) que sigue el color del
/// music video.
class VideoFrameSampler {
  VideoFrameSampler._();

  /// Pixel ratio del capture. 0.12 = imagen ~60×34 a partir de un video
  /// 500×280 lógico. Suficiente para colores promedio de esquinas.
  static const double _captureScale = 0.12;

  /// Tamaño de cada esquina como fracción del frame (0..1). 0.25 = la
  /// esquina abarca el 25% × 25% del rect → es la "iluminación periférica"
  /// que se ve detrás del video real en el ambient mode de YouTube.
  static const double _cornerFraction = 0.25;

  static Future<VideoEdgeSample?> sampleEdges(GlobalKey key) async {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    ui.Image? img;
    try {
      img = await ro.toImage(pixelRatio: _captureScale);
      final byteData =
          await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      final bytes = byteData.buffer.asUint8List();
      final w = img.width;
      final h = img.height;
      if (w < 4 || h < 4) return null;

      final qw = (w * _cornerFraction).round().clamp(1, w);
      final qh = (h * _cornerFraction).round().clamp(1, h);

      Color sampleRect(int x0, int y0, int x1, int y1) {
        int r = 0, g = 0, b = 0, count = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final i = (y * w + x) * 4;
            if (i + 2 >= bytes.length) continue;
            r += bytes[i];
            g += bytes[i + 1];
            b += bytes[i + 2];
            count++;
          }
        }
        if (count == 0) return const Color(0xFF000000);
        return Color.fromARGB(
            255, r ~/ count, g ~/ count, b ~/ count);
      }

      final tl = sampleRect(0, 0, qw, qh);
      final tr = sampleRect(w - qw, 0, w, qh);
      final bl = sampleRect(0, h - qh, qw, h);
      final br = sampleRect(w - qw, h - qh, w, h);
      final avg = Color.fromARGB(
        255,
        (((tl.r + tr.r + bl.r + br.r) * 255) ~/ 4).clamp(0, 255),
        (((tl.g + tr.g + bl.g + br.g) * 255) ~/ 4).clamp(0, 255),
        (((tl.b + tr.b + bl.b + br.b) * 255) ~/ 4).clamp(0, 255),
      );
      return VideoEdgeSample(
        topLeft: tl,
        topRight: tr,
        bottomLeft: bl,
        bottomRight: br,
        average: avg,
      );
    } catch (e) {
      devLog('VideoFrameSampler.sampleEdges error: $e');
      return null;
    } finally {
      img?.dispose();
    }
  }
}
