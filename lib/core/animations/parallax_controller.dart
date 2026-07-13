import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Convierte la inclinación física del dispositivo (acelerómetro) en un
/// [Offset] suavizado en el rango (-1..1, -1..1) que la UI multiplica por
/// los píxeles de desplazamiento que quiere aplicar al fondo.
///
/// **Importante para rendimiento:** El offset se publica vía
/// `ValueListenable<Offset>` y NO vía notifyListeners de la propia clase.
/// Así, los consumidores que usan `ValueListenableBuilder` (la capa de
/// background) se reconstruyen sin disparar rebuild del árbol entero a 60Hz.
/// El propio ChangeNotifier solo notifica cuando cambia `enabled` (raro),
/// así que el sistema de provider/InheritedNotifier no se dispara cada frame.
class ParallaxController extends ChangeNotifier {
  ParallaxController();

  static const _samplingPeriod =
      SensorInterval.uiInterval; // ~16ms / 60Hz
  static const _smoothing = 0.10; // 0..1 → mayor = menos inercia

  StreamSubscription<AccelerometerEvent>? _sub;
  final ValueNotifier<Offset> _offset = ValueNotifier<Offset>(Offset.zero);
  bool _enabled = false;

  /// Listenable para que la UI consuma el offset sin causar rebuilds globales.
  /// Lo correcto es: `ValueListenableBuilder<Offset>(valueListenable: parallax.offset, builder: ...)`.
  ValueListenable<Offset> get offset => _offset;

  /// Acceso inmediato al valor (útil en builds esporádicos).
  Offset get currentOffset => _offset.value;

  bool get isRunning => _sub != null;

  /// Activa o desactiva la suscripción al sensor. Idempotente.
  ///
  /// **No** llamamos `notifyListeners` aquí: nada en la app observa la prop
  /// `enabled`; lo único interesante es el `offset` (vía su ValueListenable).
  /// Notificar dentro del flujo de build de Flutter dispara assertions y
  /// puede tumbar la app en debug. Si en el futuro necesitas reaccionar a
  /// enabled, hazlo diferido con `WidgetsBinding.instance.addPostFrameCallback`.
  void setEnabled(bool enabled) {
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) {
      _start();
    } else {
      _stop();
    }
  }

  void _start() {
    _sub = accelerometerEventStream(samplingPeriod: _samplingPeriod).listen(
      _onSample,
      onError: (_) {
        // Algunos dispositivos / emuladores no exponen acelerómetro: caemos
        // a parallax inactivo silenciosamente.
        _stop();
      },
      cancelOnError: false,
    );
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    if (_offset.value != Offset.zero) {
      _offset.value = Offset.zero;
    }
  }

  void _onSample(AccelerometerEvent e) {
    // El acelerómetro mide gravedad + aceleración del usuario. En reposo,
    // |g| ≈ 9.8 m/s². Normalizamos por g y clampeamos a (-1..1).
    final tx = (-e.x / 9.8).clamp(-1.0, 1.0);
    final ty = (e.y / 9.8).clamp(-1.0, 1.0);

    final cur = _offset.value;
    final next = Offset(
      cur.dx * (1 - _smoothing) + tx * _smoothing,
      cur.dy * (1 - _smoothing) + ty * _smoothing,
    );

    // Evita publicar por sub-pixel-changes para ahorrar rebuilds.
    if ((next - cur).distance < 0.002) return;
    _offset.value = next;
  }

  @override
  void dispose() {
    _stop();
    _offset.dispose();
    super.dispose();
  }
}
