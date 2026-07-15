import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/dev_log.dart';
import '../core/settings/settings_controller.dart';
import '../core/settings/ui_settings.dart';

/// Resuelve la calidad de stream/descarga a usar según el tipo de red
/// activa y los ajustes del usuario. Cachea el tipo de red detectado
/// para no hacer un syscall por cada `playAt`.
///
/// Refresca el cache cuando el `Connectivity` emite cambio (cambio de
/// WiFi → datos, modo avión, etc.) — sin esto, si el usuario salía de
/// WiFi a celular el player seguiría usando la calidad alta hasta el
/// próximo restart.
class NetworkQualityResolver {
  NetworkQualityResolver(this._settings) {
    // Init asíncrono — el constructor no espera. Si el plugin no está
    // disponible (desktop sin permisos, plataforma sin soporte), el
    // resolver cae a default `_NetType.wifi` y devuelve la calidad de
    // WiFi configurada por el usuario sin reventar.
    _init();
  }

  final SettingsController _settings;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  _NetType _current = _NetType.wifi;

  void _init() {
    try {
      _sub = Connectivity().onConnectivityChanged.listen(
        (results) {
          _current = _detectFrom(results);
          devLog('[NET] connectivity changed → ${_current.name}');
        },
        onError: (e) {
          devLog('[NET] connectivity stream error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      devLog('[NET] Connectivity listen failed: $e');
    }
    // ignore: discarded_futures
    _refresh();
  }

  /// Calidad de audio efectiva en la red actual.
  MediaQuality get audioQuality {
    final s = _settings.value;
    return _current == _NetType.wifi
        ? s.audioQualityWifi
        : s.audioQualityCellular;
  }

  /// Calidad de video efectiva en la red actual.
  MediaQuality get videoQuality {
    final s = _settings.value;
    return _current == _NetType.wifi
        ? s.videoQualityWifi
        : s.videoQualityCellular;
  }

  /// Calidad fija para descargas — el archivo se queda en el device,
  /// no consume datos cada vez que reproduce, así que el ajuste es uno
  /// solo (no depende del tipo de red activa al momento de descargar).
  MediaQuality get downloadQuality => _settings.value.downloadQuality;

  Future<void> _refresh() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _current = _detectFrom(results);
    } catch (e) {
      devLog('[NET] checkConnectivity failed: $e');
    }
  }

  _NetType _detectFrom(List<ConnectivityResult> results) {
    // WiFi tiene prioridad sobre mobile cuando ambos están reportados
    // (raro pero pasa en algunos devices con cellular fallback activo
    // en background).
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return _NetType.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return _NetType.cellular;
    }
    // Sin red conocida → asumimos "wifi" para no penalizar la calidad
    // de descargas offline / desktop. El caller maneja la falta real
    // de red vía los errores HTTP.
    return _NetType.wifi;
  }

  void dispose() {
    _sub?.cancel();
  }
}

enum _NetType { wifi, cellular }

/// Bitrate aprox máximo (en bps) por nivel de calidad. Usado como
/// target del picker — el picker busca el format con bitrate ≤ target
/// y MÁS cercano. Si no hay nada ≤ target, cae al más bajo disponible.
extension MediaQualityBitrate on MediaQuality {
  int get targetBitrateBps {
    switch (this) {
      case MediaQuality.low:
        return 96000; // 96kbps (Opus 64-96 / AAC LC 96)
      case MediaQuality.medium:
        return 160000; // 160kbps (Opus 128 / AAC 128-160)
      case MediaQuality.high:
        return 1 << 30; // sin tope efectivo — toma el más alto
    }
  }

  String get label {
    switch (this) {
      case MediaQuality.low:
        return 'Baja (~96 kbps)';
      case MediaQuality.medium:
        return 'Media (~160 kbps)';
      case MediaQuality.high:
        return 'Alta';
    }
  }

  /// Resolución máxima (height en px) del stream de VIDEO por nivel. El
  /// picker busca el format con height ≤ tope más cercano al tope; si
  /// nada queda ≤ tope, cae al más bajo disponible.
  int get maxVideoHeightPx {
    switch (this) {
      case MediaQuality.low:
        return 360;
      case MediaQuality.medium:
        return 720;
      case MediaQuality.high:
        return 1 << 30; // sin tope — toma la resolución más alta que haya
    }
  }

  /// Label para los selectores de VIDEO — en video lo que se elige es
  /// resolución de imagen, no bitrate de audio.
  String get videoLabel {
    switch (this) {
      case MediaQuality.low:
        return 'Baja (360p)';
      case MediaQuality.medium:
        return 'Media (720p)';
      case MediaQuality.high:
        return 'Alta (máxima disponible)';
    }
  }
}
