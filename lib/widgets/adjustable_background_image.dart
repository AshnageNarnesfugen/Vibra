import 'dart:io';

import 'package:flutter/material.dart';

import '../core/settings/settings_controller.dart';
import '../core/settings/ui_settings.dart';

/// Vista NO-interactiva que pinta la imagen de fondo respetando la
/// transformación guardada en [UiSettings]. La usa el background real de la
/// app (full-bleed), la preview de ajustes y el editor fullscreen.
///
/// Semántica del transform (cambiada en 1.3.2):
///   - Base `BoxFit.contain` a scale 1.0 → la imagen ENTERA visible,
///     centrada. Nada de auto-crop: el usuario compone el encuadre él
///     mismo con pinch-zoom en el editor.
///   - `scale` va de 0.35 (más chica que la pantalla) a 8.0 (zoom fuerte),
///     así que cubrir la pantalla completa (el viejo "cover") es solo un
///     encuadre más de los posibles.
///   - `offsetX/Y` normalizados: 1.0 = media pantalla de desplazamiento.
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

  /// Rango de zoom permitido. Compartido con el editor para que lo que se
  /// edita sea exactamente lo que se renderiza.
  static const double minScale = 0.35;
  static const double maxScale = 8.0;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          // offsetX/Y están normalizados (-1..1 ≈ media pantalla). Los
          // multiplicamos por la mitad del lienzo para obtener px reales.
          final dx = transform.offsetX * w / 2;
          final dy = transform.offsetY * h / 2;
          return ClipRect(
            child: OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: Transform.translate(
                offset: Offset(dx, dy),
                child: Transform.scale(
                  scale: transform.scale.clamp(minScale, maxScale),
                  child: Image.file(
                    File(path),
                    width: w,
                    height: h,
                    fit: BoxFit.contain,
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

/// Editor de posición del fondo a PANTALLA COMPLETA, estilo "recortar foto
/// de perfil": fondo negro, la imagen entera al abrir, y el usuario compone
/// el encuadre con gestos — la pantalla completa ES el marco, así que lo
/// que se ve al darle "Listo" es exactamente cómo queda el fondo.
///
///   - Pinch con dos dedos → zoom anclado al punto del pellizco.
///   - Drag (1 o 2 dedos) → reposicionar.
///   - Doble tap → resetear (imagen entera centrada).
///
/// Los cambios viven en estado local: "Listo" persiste, "Cancelar"/back
/// descarta (el editor viejo persistía cada frame del gesto — imposible
/// arrepentirse).
class BackgroundImageEditorScreen extends StatefulWidget {
  const BackgroundImageEditorScreen({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<BackgroundImageEditorScreen> createState() =>
      _BackgroundImageEditorScreenState();
}

class _BackgroundImageEditorScreenState
    extends State<BackgroundImageEditorScreen> {
  late BackgroundImageTransform _transform;
  BackgroundImageTransform _gestureStart = const BackgroundImageTransform();
  Offset _focalStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _transform = widget.controller.value.backgroundImageTransform;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStart = _transform;
    _focalStart = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w / 2, h / 2);

    final s1 = _gestureStart.scale;
    final s2 = (s1 * details.scale)
        .clamp(BackgroundImageView.minScale, BackgroundImageView.maxScale)
        .toDouble();

    // Zoom anclado al focal: el punto de la imagen bajo los dedos se queda
    // bajo los dedos. Con render = translate(offset) ∘ scale(s) alrededor
    // del centro, un punto de pantalla x cumple x = offset + s·v (v = vector
    // imagen desde el centro). Para mantener x fijo al pasar de s1 → s2:
    //   offset₂ = f − (f − offset₁)·(s2/s1)      con f = focal − centro
    // y el pan es sumar el desplazamiento del focal.
    final offset1 = Offset(
      _gestureStart.offsetX * w / 2,
      _gestureStart.offsetY * h / 2,
    );
    final f = _focalStart - center;
    final zoomed = f - (f - offset1) * (s2 / s1);
    final panned = zoomed + (details.localFocalPoint - _focalStart);

    setState(() {
      _transform = BackgroundImageTransform(
        scale: s2,
        offsetX: (panned.dx / (w / 2)).clamp(-2.5, 2.5),
        offsetY: (panned.dy / (h / 2)).clamp(-2.5, 2.5),
      );
    });
  }

  void _reset() {
    setState(() => _transform = const BackgroundImageTransform());
  }

  void _save() {
    widget.controller.update(
      (s) => s.copyWith(backgroundImageTransform: _transform),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.controller.value.backgroundImagePath;
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: path == null
          ? const Center(
              child: Text(
                'Selecciona una imagen de fondo primero.',
                style: TextStyle(color: Colors.white70),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                // ─── La imagen, editable a pantalla completa ───
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: (d) => _onScaleUpdate(d, size),
                  onDoubleTap: _reset,
                  child: BackgroundImageView(
                    path: path,
                    transform: _transform,
                    // Composición al 100% — la opacidad real se aplica en
                    // producción, aquí el usuario necesita ver la imagen.
                    opacity: 1.0,
                  ),
                ),

                // ─── Controles (no interceptan gestos fuera de sí) ───
                SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Cancelar',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded,
                                  color: Colors.white),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white10,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _reset,
                              icon: const Icon(
                                  Icons.center_focus_strong_rounded,
                                  size: 18),
                              label: const Text('Centrar'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: Colors.white10,
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: _save,
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Listo'),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      // Hint de gestos abajo, sobre scrim para legibilidad.
                      // IgnorePointer: el scrim NO debe robar el drag/pinch
                      // cuando el gesto empieza en la franja inferior.
                      IgnorePointer(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 14),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x00000000), Color(0x99000000)],
                            ),
                          ),
                          child: const Text(
                            'Pellizca para hacer zoom · arrastra para mover · '
                            'doble tap para ver la imagen entera',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
