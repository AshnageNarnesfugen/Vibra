import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme/luminance_map.dart';
import '../core/dev_log.dart';

/// Mantiene un [LuminanceMap] del bg actual y notifica cuando cambia.
///
/// Lo alimenta `CustomizedBackground` cada vez que la fuente del bg cambia
/// (canción nueva → nueva portada, settings → nuevo color sólido, etc.).
/// Los widgets `AdaptiveColor` lo consumen para decidir light/dark según
/// SU área específica de la pantalla.
///
/// **Debounce de 120ms** para no recomputar el map por cada update granular
/// (la portada llega primero como URL, después como bytes, después se
/// extrae la palette → 3 cambios en cascada para la misma canción).
class AdaptiveLuminanceService extends ChangeNotifier {
  LuminanceMap _map = LuminanceMap.uniform(const Color(0xFF101015));
  LuminanceMap get map => _map;

  Timer? _debounce;
  int _genToken = 0;

  // Tracking del input previo para dedupe: si el caller pide el mismo
  // input que ya está aplicado, no recomputamos el map ni notificamos.
  // Sin esto, los rebuilds del `CustomizedBackground` (varios por segundo
  // con ambient mode) disparaban notify → más rebuilds → loop.
  int? _lastUniformARGB;
  String? _lastGradientKey;
  int? _lastBytesHash;

  /// Set inmediato a un map uniforme — útil para fallbacks sin async.
  void setUniform(Color color) {
    final argb = color.toARGB32();
    if (_lastUniformARGB == argb) return;
    _lastUniformARGB = argb;
    _lastGradientKey = null;
    _lastBytesHash = null;
    _map = LuminanceMap.uniform(color);
    notifyListeners();
  }

  /// Set inmediato a un gradiente vertical.
  void setGradient(List<Color> colors) {
    final key = colors.map((c) => c.toARGB32()).join(',');
    if (_lastGradientKey == key) return;
    _lastGradientKey = key;
    _lastUniformARGB = null;
    _lastBytesHash = null;
    _map = LuminanceMap.gradient(colors);
    notifyListeners();
  }

  /// Schedule un cálculo async desde bytes. El primer tipo válido se procesa
  /// (los demás se ignoran). Si todos son null, no cambia el map.
  void scheduleFromBytes(Uint8List bytes) {
    // Hash barato de los primeros 256 bytes — suficiente para detectar
    // que es la misma imagen entre rebuilds sin escanear todo el buffer.
    final hash = Object.hashAll(bytes.take(256));
    if (_lastBytesHash == hash) return;
    _lastBytesHash = hash;
    _lastUniformARGB = null;
    _lastGradientKey = null;
    final token = ++_genToken;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      try {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 64,
        );
        final frame = await codec.getNextFrame();
        final img = frame.image;
        final next = await LuminanceMap.fromImage(img);
        img.dispose();
        if (token != _genToken || next == null) return;
        _map = next;
        notifyListeners();
      } catch (e) {
        devLog('AdaptiveLuminanceService scheduleFromBytes error: $e');
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
