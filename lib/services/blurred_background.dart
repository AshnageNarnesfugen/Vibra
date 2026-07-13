import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/dev_log.dart';

/// Pre-renderiza el fondo aplicándole blur UNA sola vez a una `ui.Image`,
/// y la expone como `ValueListenable`. Luego:
///   - La capa de fondo de la app pinta esta imagen directamente (en vez de
///     usar `BackdropFilter`).
///   - Los `GlassCard`s la samplean por su posición en pantalla via un
///     `CustomPainter` — efecto frosted glass SIN `BackdropFilter`.
///
/// Esto es lo que hace el proyecto Phantom y elimina el coste de blur en
/// runtime, que es el culpable principal del stutter en móvil.
///
/// Re-renderizamos cuando cambia:
///   - los bytes/source del fondo
///   - la intensidad del blur
///   - el tamaño de pantalla (para que la imagen tenga resolución correcta)
class BlurredBackgroundService extends ChangeNotifier {
  /// Imagen pre-blureada lista para sampling. `null` si aún no se ha
  /// generado o si no hay fondo blureable (modo color sólido, etc.).
  final ValueNotifier<ui.Image?> blurred = ValueNotifier(null);

  /// Hash de la última config renderizada — para evitar trabajo redundante.
  String? _lastKey;
  Timer? _debounce;

  /// Pide pre-renderizar con los inputs dados. El render real va al siguiente
  /// frame y está debounced — múltiples cambios en sucesión se compactan.
  ///
  /// **gradientColors**: si se pasa una lista de 2-3 colores, el bg se
  /// renderea como un gradiente lineal/diagonal con esos colores. Útil para
  /// modo `animatedGradient` — sin esto, el sampler mostraría un color
  /// uniforme y las cards se verían como bloques planos sin la sensación
  /// de "frosted" sobre el degradado.
  void schedule({
    Uint8List? sourceBytes, // bytes JPEG/PNG del fondo (album art)
    String? sourcePath, // ruta de archivo local (user image)
    String? sourceUrl, // URL remota (streaming art inmediato)
    required Color solidColor, // fondo sólido (cuando no hay imagen)
    List<Color>? gradientColors, // gradiente de paleta (modo gradiente)
    required double sigma,
    required Size targetSize,
  }) {
    final gradientKey = gradientColors
            ?.map((c) => c.toARGB32().toRadixString(16))
            .join('-') ??
        'null';
    final key = '${sourceBytes?.hashCode ?? "null"}|'
        '${sourcePath ?? "null"}|'
        '${sourceUrl ?? "null"}|'
        '${solidColor.toARGB32()}|'
        'g:$gradientKey|'
        '${sigma.toStringAsFixed(2)}|'
        '${targetSize.width.toStringAsFixed(0)}x${targetSize.height.toStringAsFixed(0)}';
    // Skip silencioso si el key no cambió — antes loggeábamos cada skip,
    // pero con CustomizedBackground rebuildeando varias veces por segundo
    // (ambient mode, palette ticks, etc.) los logs se inundaban con
    // cientos de líneas "schedule skipped" sin valor.
    if (key == _lastKey) return;
    assert(() {
      devLog('[BLUR] schedule queued: bytes=${sourceBytes != null} '
          'path=$sourcePath url=${sourceUrl != null} '
          'grad=${gradientColors?.length ?? 0}');
      return true;
    }());
    _pendingKey = key;
    _debounce?.cancel();
    // Debounce más largo (250ms): cambios de modo bg en sucesión (tap
    // rápido entre gradient/solid/image) se consolidan en UN render en
    // vez de N. Antes con 80ms cada tap disparaba un render full
    // (decode + saveLayer + toImage), todos compitiendo por main thread
    // → Davey! 1+s en startup y stutter en cada switch.
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _render(sourceBytes, sourcePath, sourceUrl, solidColor, gradientColors,
          sigma, targetSize, key);
    });
  }

  /// Key del próximo render programado — usado dentro de [_render] para
  /// bailout temprano si llegó otro `schedule` más reciente: ya no tiene
  /// sentido terminar de procesar un render obsoleto si igual el nuevo
  /// va a sobrescribir su resultado.
  String? _pendingKey;

  Future<void> _render(
    Uint8List? sourceBytes,
    String? sourcePath,
    String? sourceUrl,
    Color solidColor,
    List<Color>? gradientColors,
    double sigma,
    Size size,
    String key,
  ) async {
    ui.Image? src;
    ui.Picture? pic;
    try {
      // Bailout: si llegó otro schedule más reciente, no hacer este
      // trabajo — el resultado quedaría sobrescrito al instante.
      if (_pendingKey != null && _pendingKey != key) return;
      // 720 en vez de 1080: el bg está SIEMPRE blureado, el detalle no
      // se nota a partir de cierto punto. Reduce el área a decodificar/
      // rasterizar a ~44% del original (720² vs 1080²) → toImage muy
      // más barato → menos Davey en startup y en cada switch de modo.
      const maxSide = 720.0;
      final scale = size.longestSide > maxSide ? maxSide / size.longestSide : 1.0;
      final w = (size.width * scale).round();
      final h = (size.height * scale).round();
      if (w <= 0 || h <= 0) return;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));

      if (sourceBytes != null || sourcePath != null || sourceUrl != null) {
        if (sourceBytes != null) {
          src = await _decode(sourceBytes);
        } else if (sourcePath != null) {
          final file = File(sourcePath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            src = await _decode(bytes);
          }
        } else if (sourceUrl != null) {
          try {
            final res = await http.get(Uri.parse(sourceUrl));
            if (res.statusCode == 200) {
              src = await _decode(res.bodyBytes);
            }
          } catch (_) {}
        }

        if (src != null) {
          final srcRect = _coverSrcRect(
            Size(src.width.toDouble(), src.height.toDouble()),
            Size(w.toDouble(), h.toDouble()),
          );
          final dstRect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());

          // RECETA PHANTOM: el blur se aplica vía `saveLayer` con el
          // `imageFilter` puesto en la PAINT del layer. Al hacer `restore()`,
          // Skia/Impeller compone la capa aplicando el blur — esto genera
          // una `ui.Image` con el blur ya horneado.
          //
          // Importante: pasar `imageFilter` directamente en el `Paint` de
          // `drawImageRect` NO siempre lo aplica (es ambiguo en la spec).
          // El saveLayer es el camino oficial y consistente.
          if (sigma > 0) {
            canvas.saveLayer(
              dstRect,
              Paint()
                ..imageFilter = ui.ImageFilter.blur(
                  sigmaX: sigma * scale,
                  sigmaY: sigma * scale,
                  tileMode: TileMode.clamp,
                ),
            );
            canvas.drawImageRect(
              src,
              srcRect,
              dstRect,
              Paint()..filterQuality = FilterQuality.medium,
            );
            canvas.restore();
          } else {
            canvas.drawImageRect(
              src,
              srcRect,
              dstRect,
              Paint()..filterQuality = FilterQuality.medium,
            );
          }
        }
      } else if (gradientColors != null && gradientColors.isNotEmpty) {
        // Gradiente diagonal: 2-3 colores en una banda. El blur posterior
        // suaviza las transiciones aún más → cuando el sampler lee un trozo
        // pequeño (área de una card), el usuario ve colores mezclados de la
        // paleta — efecto "frosted" sobre el gradiente animado real.
        final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
        final colors = gradientColors.length == 1
            ? <Color>[gradientColors[0], gradientColors[0]]
            : gradientColors;
        // `ui.Gradient.linear` exige length EXACTAMENTE 2 cuando colorStops
        // es null. Con 3+ colores hay que generar stops espaciados o tirar
        // ArgumentError → si tiramos, `_lastKey` no se actualiza y el sampler
        // sigue mostrando la imagen anterior (bug visible: cards conservan
        // la imagen al cambiar a gradiente).
        final stops = colors.length == 2
            ? null
            : List<double>.generate(
                colors.length, (i) => i / (colors.length - 1));
        final paint = Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 0),
            Offset(w.toDouble(), h.toDouble()),
            colors,
            stops,
          );
        // Fondo negro debajo para no ver transparencia si los colores tienen
        // alpha bajo (paleta de albums oscuros, por ejemplo).
        canvas.drawRect(rect, Paint()..color = Colors.black);
        canvas.drawRect(rect, paint);
      } else {
        canvas.drawRect(
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint()..color = solidColor,
        );
      }

      // Segundo bailout: el decode/http puede haber tardado >250ms y en
      // ese tiempo el usuario tapeó otro modo bg → el key cambió.
      // `toImage` es el paso más caro (raster en GPU + alloc de
      // textura), no vale gastar ese coste para un resultado que va a
      // ser sobrescrito antes de pintarse.
      if (_pendingKey != null && _pendingKey != key) return;
      pic = recorder.endRecording();
      final img = await pic.toImage(w, h);

      final pathRendered = sourceBytes != null
          ? 'bytes'
          : sourcePath != null
              ? 'path'
              : sourceUrl != null
                  ? 'url'
                  : gradientColors != null
                      ? 'gradient'
                      : 'solid';
      devLog('[BLUR] rendered via $pathRendered → ${img.width}x${img.height}');

      // Diferimos el dispose de la imagen vieja por 2s. Disposear demasiado
      // pronto crashea la raster thread si los widgets aún están pintando
      // con la textura vieja (ValueListenableBuilder rebuild + paint no
      // siempre completa antes del siguiente tick).
      final old = blurred.value;
      blurred.value = img;
      _lastKey = key;
      if (old != null) {
        Timer(const Duration(seconds: 2), () {
          try {
            old.dispose();
          } catch (_) {}
        });
      }
    } catch (e) {
      devLog('BlurredBackgroundService render error: $e');
    } finally {
      pic?.dispose();
      src?.dispose();
    }
  }

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Calcula el rect del source que debe leer para hacer BoxFit.cover sobre
  /// el destino.
  static Rect _coverSrcRect(Size src, Size dst) {
    final srcAspect = src.width / src.height;
    final dstAspect = dst.width / dst.height;
    if (srcAspect > dstAspect) {
      // src más ancho que dst — recortamos lados
      final newW = src.height * dstAspect;
      final dx = (src.width - newW) / 2;
      return Rect.fromLTWH(dx, 0, newW, src.height);
    } else {
      final newH = src.width / dstAspect;
      final dy = (src.height - newH) / 2;
      return Rect.fromLTWH(0, dy, src.width, newH);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    blurred.value?.dispose();
    blurred.dispose();
    super.dispose();
  }
}
