import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/theme/palette_signal.dart';
import 'music_video_player.dart';
import 'video_frame_sampler.dart';

/// "Ambient mode" estilo YouTube: muestrea las esquinas del music video que
/// se está reproduciendo y filtra esos colores a la UI completa (bg, theme,
/// AdaptiveLuminance). La paleta se interpola SUAVEMENTE entre frames
/// para que la UI cambie como una luz ambiente que sigue el video, sin
/// cortes bruscos.
///
/// Flow:
///   1. Algún widget (típicamente `MusicVideoBackgroundLayer`) registra
///      su `GlobalKey<RepaintBoundary>` con [registerVideoKey].
///   2. Cuando `MusicVideoPlayer.controller` está activo y `enabled` es
///      true, inicia un `Timer.periodic(2s)` que captura un sample.
///   3. Cada sample dispara una animación de 1.5s que interpola desde el
///      sample anterior al nuevo (Tween + AnimationController).
///   4. Cada tick aplica la paleta interpolada al `PaletteSignal` como
///      override. Cuando termina o se desactiva, libera el override.
///
/// Coste estimado: ~10ms por sample en hardware mid-range. Cada 2s →
/// despreciable. La animación corre en el ticker de Flutter sin trabajo
/// extra (solo Color.lerp).
class AmbientVideoPaletteService extends ChangeNotifier {
  AmbientVideoPaletteService({
    required this.videoPlayer,
    required this.paletteSignal,
  }) {
    _ticker = Ticker(_onTick);
    videoPlayer.addListener(_evaluate);
  }

  final MusicVideoPlayer videoPlayer;
  final PaletteSignal paletteSignal;

  late final Ticker _ticker;
  Duration? _animStart;
  // Throttle: solo aplicamos la paleta interpolada cada 250ms (4Hz). El
  // ojo no nota la diferencia con 10Hz pero el theme/shader rebuild es
  // muy caro (Davey 1s+ por canción cuando estaba a 100ms). El usuario
  // pidió que NO sea necesario sync exacto al video — preferimos perf.
  Duration _lastApply = Duration.zero;
  static const _animDuration = Duration(milliseconds: 2500);
  static const _applyInterval = Duration(milliseconds: 250);
  GlobalKey? _videoKey;
  Timer? _sampleTimer;

  // Estabilidad de paleta: para evitar que la UI haga "flicker" cuando el
  // video tiene cortes/flashes bruscos, comparamos cada sample con el
  // último que aplicamos en espacio HSL (hue es el predictor más
  // perceptual de "cambio de tinta"). Si la diferencia supera el
  // umbral, no aplicamos directo: lo dejamos como "candidato pendiente"
  // y solo cuando un segundo sample confirma que la nueva tinta es
  // estable (consecutivos similares) hacemos el cambio. Cortes
  // momentáneos no pasan el filtro porque el siguiente sample vuelve
  // al color original → el candidato queda descartado.
  //
  // Threshold 0.30 en el score combinado HSL:
  //   - blue → red (hue ≈120° delta): score ~0.47 → triggers.
  //   - blue → teal (hue ≈60° delta): score ~0.23 → NO triggers (drift).
  //   - shift dentro de un mismo cuadrante (~20°): score ~0.08 → ignorado.
  static const double _stabilityThreshold = 0.30;
  VideoEdgeSample? _lastApplied;
  VideoEdgeSample? _pendingCandidate;

  /// Toggle global. Si es false, no se hace nada — el feature queda OFF.
  bool _enabled = true;
  bool get enabled => _enabled;
  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    _evaluate();
    notifyListeners();
  }

  VideoEdgeSample? _from;
  VideoEdgeSample? _to;

  /// Registra el [RepaintBoundary] del que se va a samplear. Si ya hay
  /// uno registrado, lo reemplaza — sirve para que cualquiera de los dos
  /// lugares donde se renderea el video (cover o bg) sea la fuente.
  void registerVideoKey(GlobalKey key) {
    _videoKey = key;
    _evaluate();
  }

  void unregisterVideoKey(GlobalKey key) {
    if (_videoKey == key) {
      _videoKey = null;
      _stopSampling();
    }
  }

  void _evaluate() {
    if (!_enabled) {
      _stopSampling();
      return;
    }
    final controller = videoPlayer.controller;
    final hasVideo = controller != null && controller.value.isInitialized;
    if (hasVideo && _videoKey != null) {
      _startSampling();
    } else {
      _stopSampling();
    }
  }

  void _startSampling() {
    if (_sampleTimer?.isActive ?? false) return;
    // Primer sample con 500ms para dejar que el primer frame del video se
    // renderice; siguientes cada 4s — menos churn de palette → menos
    // rebuilds del theme/shader → mejor FPS. La transición entre samples
    // dura 2.5s (animDuration), entonces hay solapamiento corto pero el
    // ojo no nota saltos.
    Timer(const Duration(milliseconds: 500), _sampleNow);
    _sampleTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _sampleNow());
  }

  void _stopSampling() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    if (_ticker.isActive) _ticker.stop();
    _animStart = null;
    _lastApplied = null;
    _pendingCandidate = null;
    if (_from != null || _to != null) {
      _from = null;
      _to = null;
      paletteSignal.setAmbientOverride(null);
      notifyListeners();
    }
  }

  Future<void> _sampleNow() async {
    final key = _videoKey;
    if (key == null) return;
    final next = await VideoFrameSampler.sampleEdges(key);
    if (next == null) return;

    // Filtro de estabilidad. Tres caminos:
    //   1. No hay paleta aplicada todavía → aplicar directo (primer frame).
    //   2. El sample nuevo es similar al último aplicado (drift suave) →
    //      aplicar y descartar candidato pendiente.
    //   3. El sample nuevo es distinto al último aplicado: no aplicar
    //      ahora; guardarlo como candidato. Solo cuando un sample
    //      SIGUIENTE sea similar a ese candidato (=la tinta nueva es
    //      estable, no un flash) se aplica → cortes momentáneos del
    //      video no llegan a la UI.
    if (_lastApplied != null) {
      final diffFromApplied = _avgDistance(next, _lastApplied!);
      if (diffFromApplied >= _stabilityThreshold) {
        // Color distinto: ¿lo confirma el candidato anterior?
        if (_pendingCandidate == null ||
            _avgDistance(next, _pendingCandidate!) >= _stabilityThreshold) {
          // Sin confirmación → guardamos como candidato y esperamos.
          _pendingCandidate = next;
          return;
        }
        // Candidato confirmado: la tinta nueva persiste, vale aplicarla.
      }
    }
    _pendingCandidate = null;
    _lastApplied = next;

    // El sample previo se vuelve el punto inicial; el nuevo es el target.
    _from = _to ?? next;
    _to = next;
    _animStart = null;
    if (_ticker.isActive) _ticker.stop();
    _ticker.start();
  }

  /// Distancia perceptual entre dos samples en HSL — captura "cambios
  /// de tinta" mejor que RGB. Usa el `average` (más estable que
  /// esquinas individuales). Score 0..1 normalizado.
  ///
  /// El hue domina (peso 0.7) porque shifts de hue (azul→rojo) son los
  /// "drástricos" que el usuario percibe como cambio real de escena.
  /// La saturación (0.2) y la lightness (0.1) son secundarias — capturan
  /// matices (color saturado vs lavado, oscuro vs claro) que SI cuentan
  /// pero menos.
  ///
  /// **Caso especial gris/desaturado**: si ambos samples son grises
  /// (saturación < 0.15), el hue pierde significado (un gris azulado y un
  /// gris rojizo se ven iguales) → solo medimos lightness. Sin este
  /// branch, ruido de hue en grises disparaba candidatos falsos.
  double _avgDistance(VideoEdgeSample a, VideoEdgeSample b) {
    final ha = HSLColor.fromColor(a.average);
    final hb = HSLColor.fromColor(b.average);
    // Hue es circular: la max distancia es 180° (rojo en 0° vs cyan en
    // 180°). Normalizamos a 0..1.
    final hueRaw = (ha.hue - hb.hue).abs();
    final hueDelta = (hueRaw > 180 ? 360 - hueRaw : hueRaw) / 180.0;
    final satDelta = (ha.saturation - hb.saturation).abs();
    final lightDelta = (ha.lightness - hb.lightness).abs();
    if (ha.saturation < 0.15 && hb.saturation < 0.15) {
      // Ambos grises → ignora hue, solo lightness importa.
      return lightDelta;
    }
    return hueDelta * 0.7 + satDelta * 0.2 + lightDelta * 0.1;
  }

  void _onTick(Duration elapsed) {
    if (_from == null || _to == null) return;
    _animStart ??= elapsed;
    final dt = elapsed - _animStart!;
    final raw =
        (dt.inMicroseconds / _animDuration.inMicroseconds).clamp(0.0, 1.0);
    final isFinal = raw >= 1.0;
    // Throttle: skipear ticks intermedios si el último apply fue hace
    // menos de 100ms — pero SIEMPRE aplicamos el frame final (raw=1.0)
    // para que la paleta quede exactamente en el target.
    if (!isFinal && (elapsed - _lastApply) < _applyInterval) return;
    _lastApply = elapsed;
    final t = Curves.easeInOutCubic.transform(raw);
    final blended = _from!.lerpTo(_to!, t);
    paletteSignal.setAmbientOverride(_toAlbumPalette(blended));
    if (isFinal) {
      _ticker.stop();
      _animStart = null;
    }
  }

  /// Mapea las esquinas a una `AlbumPalette` compatible con todo el
  /// sistema (theme, shader, AdaptiveLuminance):
  ///   - `dominant`: average (es lo que mejor representa "el ambiente").
  ///   - `accent` + `vibrant`: la esquina con mayor saturación.
  ///   - `lightVibrant/darkVibrant`: la más clara y la más oscura de las
  ///     esquinas → eso da contraste para los shaders palette-aware.
  AlbumPalette _toAlbumPalette(VideoEdgeSample s) {
    final corners = [s.topLeft, s.topRight, s.bottomLeft, s.bottomRight];
    // Por saturación HSL.
    corners.sort((a, b) {
      final sa = HSLColor.fromColor(a).saturation;
      final sb = HSLColor.fromColor(b).saturation;
      return sb.compareTo(sa);
    });
    final mostSat = corners.first;
    // Por luminancia.
    final byLum = [...corners]
      ..sort((a, b) => a.computeLuminance().compareTo(b.computeLuminance()));
    return AlbumPalette(
      dominant: s.average,
      accent: mostSat,
      vibrant: mostSat,
      lightVibrant: byLum.last,
      darkVibrant: byLum.first,
    );
  }

  @override
  void dispose() {
    _stopSampling();
    videoPlayer.removeListener(_evaluate);
    _ticker.dispose();
    paletteSignal.setAmbientOverride(null);
    super.dispose();
  }
}
