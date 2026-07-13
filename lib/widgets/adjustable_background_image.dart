import 'dart:io';

import 'package:flutter/material.dart';

import '../core/settings/settings_controller.dart';
import '../core/settings/ui_settings.dart';

/// Vista NO-interactiva que pinta la imagen de fondo respetando la
/// transformación guardada en [UiSettings]. La usa el background real de la
/// app (full-bleed) y la previsualización del editor (dentro del marco de
/// teléfono).
class BackgroundImageView extends StatelessWidget {
  const BackgroundImageView({
    super.key,
    required this.path,
    required this.transform,
    required this.opacity,
  });

  final String path;
  final BackgroundImageTransform transform;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          // offsetX/Y están normalizados (-1..1). Los multiplicamos por la
          // mitad del lienzo para obtener desplazamiento en píxeles real.
          final dx = transform.offsetX * w / 2;
          final dy = transform.offsetY * h / 2;
          return ClipRect(
            child: OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: Transform.translate(
                offset: Offset(dx, dy),
                child: Transform.scale(
                  scale: transform.scale.clamp(1.0, 6.0),
                  child: Image.file(
                    File(path),
                    width: w,
                    height: h,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Colors.black12),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Editor estilo "publicación de red social":
///   - Una silueta de teléfono con la proporción real de tu pantalla.
///   - La imagen vive DENTRO del frame.
///   - Pinch-zoom con dos dedos para escalar (como Instagram al recortar).
///   - Drag con un dedo para reposicionar.
///   - Doble tap para resetear.
///
/// La transformación se persiste en tiempo real en [SettingsController], así
/// el background real (fuera del editor) refleja los cambios al instante.
class BackgroundImageEditor extends StatefulWidget {
  const BackgroundImageEditor({
    super.key,
    required this.controller,
  });

  final SettingsController controller;

  @override
  State<BackgroundImageEditor> createState() => _BackgroundImageEditorState();
}

class _BackgroundImageEditorState extends State<BackgroundImageEditor> {
  late BackgroundImageTransform _start;
  Offset _focalStart = Offset.zero;
  double _scaleStart = 1.0;

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.value;
    final path = settings.backgroundImagePath;
    if (path == null) {
      return const Center(
        child: Text('Selecciona una imagen de fondo primero.'),
      );
    }

    // Aspecto REAL del dispositivo (en orientación portrait), así lo que
    // ves en el editor es exactamente cómo se va a ver en pantalla. En
    // landscape invertimos para que el frame quede vertical igualmente.
    final mq = MediaQuery.sizeOf(context);
    final shortest = mq.shortestSide;
    final longest = mq.longestSide;
    final phoneAspect = shortest / longest; // p.ej. 9/19.5 ≈ 0.46

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculamos cuán grande puede ser el frame respetando ambos
        // constraints (ancho y alto) y la relación de aspecto real.
        final maxH = constraints.maxHeight;
        final maxW = constraints.maxWidth;
        double frameH = maxH;
        double frameW = frameH * phoneAspect;
        if (frameW > maxW) {
          frameW = maxW;
          frameH = frameW / phoneAspect;
        }

        return Center(
          child: SizedBox(
            width: frameW,
            height: frameH,
            child: _PhoneSilhouette(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (details) {
                  _start = settings.backgroundImageTransform;
                  _focalStart = details.focalPoint;
                  _scaleStart = _start.scale;
                },
                onScaleUpdate: (details) {
                  final delta = details.focalPoint - _focalStart;
                  final newScale = (_scaleStart * details.scale)
                      .clamp(1.0, 6.0)
                      .toDouble();
                  // Normalizamos delta al rango del frame (-1..1) sobre la
                  // mitad del frame visible — así el drag se siente 1:1
                  // dentro del editor, no respecto a la pantalla completa.
                  final newOffsetX =
                      (_start.offsetX + (delta.dx * 2 / frameW))
                          .clamp(-1.5, 1.5);
                  final newOffsetY =
                      (_start.offsetY + (delta.dy * 2 / frameH))
                          .clamp(-1.5, 1.5);
                  widget.controller.update(
                    (s) => s.copyWith(
                      backgroundImageTransform: BackgroundImageTransform(
                        scale: newScale,
                        offsetX: newOffsetX,
                        offsetY: newOffsetY,
                      ),
                    ),
                  );
                },
                onDoubleTap: () {
                  widget.controller.update(
                    (s) => s.copyWith(
                      backgroundImageTransform:
                          const BackgroundImageTransform(),
                    ),
                  );
                },
                child: BackgroundImageView(
                  path: path,
                  transform: settings.backgroundImageTransform,
                  // En el editor mostramos la imagen al 100% para que el
                  // usuario vea la composición real; la opacidad real se
                  // aplica fuera, en producción.
                  opacity: 1.0,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Marco visual de teléfono: rounded-rect con borde claro, dynamic-island
/// opcional arriba y home-indicator abajo. Recorta su `child` al borde.
class _PhoneSilhouette extends StatelessWidget {
  const _PhoneSilhouette({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      alignment: Alignment.center,
      children: [
        // Sombra suave alrededor del frame.
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
        // Borde del teléfono.
        ClipRRect(
          borderRadius: BorderRadius.circular(36),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: 0.25),
                width: 2,
              ),
            ),
            // Padding interno simulando los bezels — la imagen vive dentro.
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: child,
              ),
            ),
          ),
        ),
        // Dynamic-island indicator (arriba).
        Positioned(
          top: 12,
          child: Container(
            width: 80,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        // Home indicator (abajo).
        Positioned(
          bottom: 8,
          child: Container(
            width: 90,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }
}
