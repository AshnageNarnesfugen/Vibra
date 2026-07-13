import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Placeholder pulsante para hidratación de UI durante cargas — el shape
/// se mantiene fijo y su brillo sube y baja en loop (estilo Facebook /
/// Twitter / YT Music). Es un `StatefulWidget` independiente por
/// instancia, pero todas se ven sincronizadas porque cada controller
/// arranca desde la misma fase (0.0) y usa la misma duración.
///
/// Uso típico:
///   ```dart
///   Column(children: [
///     Skeleton(height: 18, width: 120),  // título
///     SizedBox(height: 8),
///     Skeleton(height: 14, width: 80),   // subtítulo
///   ])
///   ```
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  /// Si `null`, se estira al ancho disponible del padre.
  final double? width;

  /// Si `null`, se estira al alto disponible del padre.
  final double? height;

  /// Para `BoxShape.rectangle`. Si `null`, se usa un radio chico (6).
  final BorderRadius? borderRadius;

  /// `BoxShape.circle` ignora [borderRadius] — sirve para thumbnails
  /// circulares o avatares.
  final BoxShape shape;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          // Curve ease-in-out para que el pulso se sienta orgánico (no
          // lineal). Alpha de 0.06 → 0.16 sobre onSurface = gris oscuro
          // pulsante sobre el bg.
          final t = Curves.easeInOut.transform(_ctrl.value);
          final alpha = ui.lerpDouble(0.06, 0.16, t)!;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: alpha),
              borderRadius: widget.shape == BoxShape.rectangle
                  ? (widget.borderRadius ?? BorderRadius.circular(6))
                  : null,
              shape: widget.shape,
            ),
          );
        },
      ),
    );
  }
}

/// Helper para skeletons en grilla de song tiles — replica el layout
/// típico de la home (thumbnail cuadrado + 2 líneas de texto debajo).
class SkeletonSongTile extends StatelessWidget {
  const SkeletonSongTile({super.key, this.tileSize = 140});

  final double tileSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: tileSize,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Skeleton(
            width: tileSize,
            height: tileSize,
            borderRadius: BorderRadius.circular(10),
          ),
          const SizedBox(height: 8),
          const Skeleton(height: 14, width: 110),
          const SizedBox(height: 6),
          const Skeleton(height: 12, width: 80),
        ],
      ),
    );
  }
}

/// Helper para skeletons de un shelf horizontal entero — un title arriba
/// y una fila scrollable de song-tiles. Útil para llenar la home
/// mientras se cargan los shelves reales.
class SkeletonShelf extends StatelessWidget {
  const SkeletonShelf({
    super.key,
    this.tileCount = 5,
    this.tileSize = 140,
  });

  final int tileCount;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Skeleton del título del shelf.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Skeleton(height: 22, width: 160),
        ),
        const SizedBox(height: 12),
        // Fila horizontal de tiles.
        SizedBox(
          height: tileSize + 60, // tile + 2 líneas de texto + gaps
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: tileCount,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, _) => SkeletonSongTile(tileSize: tileSize),
          ),
        ),
      ],
    );
  }
}
