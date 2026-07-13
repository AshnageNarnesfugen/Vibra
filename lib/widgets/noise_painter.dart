import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Dibuja una capa de ruido/grano. Genera UNA imagen pequeña tileable y
/// la repite, en lugar de pintar miles de puntos por frame: barato y
/// determinístico.
class NoiseLayer extends StatefulWidget {
  const NoiseLayer({
    super.key,
    required this.intensity,
    this.tileSize = 128,
  });

  /// 0..1 — opacidad del overlay.
  final double intensity;

  /// Tamaño del tile generado en px (potencias de 2 son más eficientes).
  final int tileSize;

  @override
  State<NoiseLayer> createState() => _NoiseLayerState();
}

class _NoiseLayerState extends State<NoiseLayer> {
  ui.Image? _tile;
  int? _builtForSize;

  @override
  void initState() {
    super.initState();
    _buildTile();
  }

  @override
  void didUpdateWidget(covariant NoiseLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tileSize != widget.tileSize) _buildTile();
  }

  Future<void> _buildTile() async {
    final size = widget.tileSize;
    if (_builtForSize == size) return;
    _builtForSize = size;

    final rnd = math.Random(0xA17F0);
    final pixels = Uint8ListBuilder.zeroes(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      // Distribución triangular para que el grano se vea natural (no tan plano
      // como un random uniforme). Center=128, span=±100.
      final v = ((rnd.nextDouble() + rnd.nextDouble()) * 100).round();
      final lum = 28 + v.clamp(0, 200);
      final off = i * 4;
      pixels.data[off] = lum;
      pixels.data[off + 1] = lum;
      pixels.data[off + 2] = lum;
      pixels.data[off + 3] = 255;
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels.data,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final img = await completer.future;
    if (!mounted) return;
    setState(() => _tile = img);
  }

  @override
  void dispose() {
    _tile?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tile == null || widget.intensity <= 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: widget.intensity.clamp(0.0, 1.0),
        child: CustomPaint(
          painter: _TilePainter(_tile!),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _TilePainter extends CustomPainter {
  _TilePainter(this.tile);
  final ui.Image tile;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..blendMode = BlendMode.softLight
      ..filterQuality = FilterQuality.none
      ..shader = ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        Float64List.fromList([
          1, 0, 0, 0,
          0, 1, 0, 0,
          0, 0, 1, 0,
          0, 0, 0, 1,
        ]),
      );
    
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _TilePainter oldDelegate) =>
      oldDelegate.tile != tile;
}

/// Pequeño helper para evitar imports adicionales.
class Uint8ListBuilder {
  Uint8ListBuilder.zeroes(int length) : data = Uint8List(length);
  final Uint8List data;
}
