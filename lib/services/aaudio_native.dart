import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/dev_log.dart';

/// Capacidades que reporta el dispositivo para audio AAudio EXCLUSIVE.
@immutable
class AAudioCapability {
  const AAudioCapability({
    required this.exclusiveSupported,
    required this.preferredSampleRate,
    required this.supportedSampleRates,
    required this.preferredBurstFrames,
    required this.deviceName,
  });

  /// True si el device permite stream `EXCLUSIVE` (bypassa AudioFlinger).
  /// API 26+ generalmente, pero los OEMs lo restringen — algunos solo
  /// permiten exclusive con USB DAC, otros nunca.
  final bool exclusiveSupported;

  /// Sample rate "nativo" del device (lo que usa internamente sin resample).
  final int preferredSampleRate;

  /// Lista de sample rates donde el device puede correr sin resampling.
  /// Para hi-res, queremos que coincida con la fuente.
  final List<int> supportedSampleRates;

  /// Tamaño de buffer (en frames) que el SO recomienda para latencia
  /// mínima sin underruns.
  final int preferredBurstFrames;

  /// Nombre del device de output activo (ej: "AudioDeck USB DAC", "Pixel speaker").
  final String deviceName;

  static const AAudioCapability empty = AAudioCapability(
    exclusiveSupported: false,
    preferredSampleRate: 0,
    supportedSampleRates: [],
    preferredBurstFrames: 0,
    deviceName: '',
  );

  Map<String, dynamic> toMap() => {
        'exclusiveSupported': exclusiveSupported,
        'preferredSampleRate': preferredSampleRate,
        'supportedSampleRates': supportedSampleRates,
        'preferredBurstFrames': preferredBurstFrames,
        'deviceName': deviceName,
      };

  factory AAudioCapability.fromMap(Map<dynamic, dynamic> m) =>
      AAudioCapability(
        exclusiveSupported: m['exclusiveSupported'] as bool? ?? false,
        preferredSampleRate:
            (m['preferredSampleRate'] as num?)?.toInt() ?? 0,
        supportedSampleRates: ((m['supportedSampleRates'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        preferredBurstFrames:
            (m['preferredBurstFrames'] as num?)?.toInt() ?? 0,
        deviceName: m['deviceName'] as String? ?? '',
      );
}

/// Wrapper del plugin nativo Kotlin `vibra/aaudio` que expone AAudio
/// EXCLUSIVE / sample rate matching / PCM_FLOAT.
///
/// **Estado actual**: scaffolding. El plugin nativo está implementado en
/// `android/app/src/main/kotlin/com/dreadashes/vibra/AAudioPlugin.kt` con
/// `queryCapability` y `isAvailable` funcionales. Falta el path completo
/// de playback EXCLUSIVE — la idea es que el plugin pueda *reemplazar*
/// al ExoPlayer para tracks específicos cuando el modo bit-perfect está
/// activo y el archivo es lossless.
///
/// Por ahora, en Dart usamos `queryCapability` para mostrar al usuario
/// qué soporta su device, y dejamos el switch real para una fase futura.
class AAudioNative {
  AAudioNative._();

  static const _channel = MethodChannel('vibra/aaudio');

  /// Reporta si el plugin nativo está disponible en el device. En non-Android
  /// siempre false. En Android < 8 false (AAudio fue introducido en API 26).
  static Future<bool> isAvailable() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('isAvailable');
      return v ?? false;
    } catch (e) {
      devLog('AAudioNative.isAvailable failed: $e');
      return false;
    }
  }

  /// Consulta capabilities del output device activo. Útil para mostrar al
  /// usuario "tu device soporta EXCLUSIVE mode hasta 192kHz" o "tu device
  /// no soporta exclusive, fallback a SHARED".
  static Future<AAudioCapability> queryCapability() async {
    if (kIsWeb || !Platform.isAndroid) return AAudioCapability.empty;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'queryCapability');
      if (raw == null) return AAudioCapability.empty;
      return AAudioCapability.fromMap(raw);
    } catch (e) {
      devLog('AAudioNative.queryCapability failed: $e');
      return AAudioCapability.empty;
    }
  }
}
