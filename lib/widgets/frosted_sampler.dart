import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Painter que dibuja un "trozo" de la imagen pre-blureada del fondo según
/// la posición global del widget en pantalla. Es la técnica de Phantom:
///   - El fondo ya está blureado UNA vez (offscreen) en `BlurredBackgroundService`.
///   - Cada card calcula su rect global con `RenderBox.localToGlobal` y
///     pinta solo el sub-rect que cae "detrás" de ella.
///   - Resultado visual: idéntico a `BackdropFilter` pero con ZERO coste de
///     blur en runtime.
///
/// Requiere conocer el `screenSize` (logical px) para hacer el mismo
/// BoxFit.cover que la capa de fondo aplica.
class FrostedSamplerPainter extends CustomPainter {
  FrostedSamplerPainter({
    required this.blurredBg,
    required this.screenSize,
    required this.tint,
    required this.getBox,
    this.parallaxOffset = Offset.zero,
    this.overscale = 1.0,
    this.maxPx = 0.0,
    Listenable? repaintWhen,
  }) : super(repaint: repaintWhen);

  final ui.Image blurredBg;
  final Size screenSize;
  final Color tint;
  final RenderBox? Function() getBox;
  final Offset parallaxOffset;
  final double overscale;
  final double maxPx;

  @override
  void paint(Canvas canvas, Size size) {
    try {
      final box = getBox();
      if (box == null || !box.attached || !box.hasSize) {
        _drawTintOnly(canvas, size);
        return;
      }
      if (screenSize.width <= 0 || screenSize.height <= 0) {
        _drawTintOnly(canvas, size);
        return;
      }

      final imgW = blurredBg.width.toDouble();
      final imgH = blurredBg.height.toDouble();
      if (imgW <= 0 || imgH <= 0) {
        _drawTintOnly(canvas, size);
        return;
      }

      final scrW = screenSize.width;
      final scrH = screenSize.height;

      // 1. Calculamos la transformación del background widget.
      // El background se escala desde el centro por `overscale`.
      // Y se desplaza por `parallaxOffset * maxPx`.
      final dx = parallaxOffset.dx * maxPx;
      final dy = parallaxOffset.dy * maxPx;

      // 2. Mapeamos la posición de la card al lienzo del background widget.
      // USAMOS localToGlobal para encontrar la posición real en la pantalla.
      final gp = box.localToGlobal(Offset.zero, ancestor: null); // Forzamos espacio de pantalla
      
      final center = Offset(scrW / 2, scrH / 2);
      
      // La posición relativa al centro de la pantalla es lo que manda el parallax
      final gpRel = gp - center;

      // El background en pantalla es: Translate(Center) * Scale(S) * Translate(T) * Content
      // Por lo tanto, la posición en el contenido es: (gpRel / S) - T
      final pRel = gpRel / overscale - Offset(dx, dy);
      final pLogical = center + pRel;

      // 3. Mapeamos de logical DP a image pixels usando BoxFit.cover.
      final scale = imgW / scrW > imgH / scrH ? scrH / imgH : scrW / imgW;
      final ox = (scrW - imgW * scale) / 2;
      final oy = (scrH - imgH * scale) / 2;

      final src = Rect.fromLTWH(
        (pLogical.dx - ox) / scale,
        (pLogical.dy - oy) / scale,
        (size.width / overscale) / scale,
        (size.height / overscale) / scale,
      );

      // Clamping robusto para evitar el efecto "miniature burned" si las 
      // coordenadas se salen por precisión o bordes del overscale.
      final imgRect = Rect.fromLTWH(0, 0, imgW, imgH);
      final clampedSrc = src.intersect(imgRect);

      if (clampedSrc.width <= 0 || clampedSrc.height <= 0) {
        _drawTintOnly(canvas, size);
        return;
      }

      // Si el src fue clipeado, ajustamos el dst para mantener proporción.
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);

      // Dibujamos la imagen blureada OPACA — esa es la sustancia del efecto
      // "frosted glass": el área de la card se ve realmente difuminada.
      // El control de "qué tanto se ve el blur vs el tinte" se hace ÚNICAMENTE
      // con el alpha del tinte (escalado en GlassCard). Si el alpha del
      // tinte es bajo, el blureado domina visualmente (efecto fuerte).
      canvas.drawImageRect(
        blurredBg,
        clampedSrc,
        dst,
        Paint()
          ..filterQuality = FilterQuality.low
          ..isAntiAlias = false,
      );
      // Tinte sutil encima — alpha del usuario ya escalado en GlassCard
      // (típicamente ~0.17 cuando frosted está activo).
      canvas.drawRect(dst, Paint()..color = tint);
    } catch (_) {
      _drawTintOnly(canvas, size);
    }
  }

  void _drawTintOnly(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = tint);
  }

  @override
  bool shouldRepaint(covariant FrostedSamplerPainter old) =>
      old.blurredBg != blurredBg ||
      old.tint != tint ||
      old.screenSize != screenSize ||
      old.parallaxOffset != parallaxOffset ||
      old.overscale != overscale;
}
