import 'package:flutter/foundation.dart';

import 'network_quality_resolver.dart';
import 'streaming/streaming_service.dart';
import '../core/dev_log.dart';

/// Cache compartido de "¿hay video para este videoId?" + URL del video.
///
/// Lo usan dos consumidores:
///   1. `MusicVideoBackgroundLayer` — fondo global cuando el setting
///      `useVideoBackgroundIfAvailable` está activo.
///   2. `PlayerScreen` — para mostrar un toggle "Cover ↔ Video" en la cover
///      cuando se detecta video para la canción actual, y para reproducirlo
///      como cover cuando el usuario lo activa.
///
/// Centralizar evita pedir 2 veces la misma URL (player endpoint es caro,
/// suele tardar 1-2s y tiene cuota).
class VideoAvailabilityController extends ChangeNotifier {
  VideoAvailabilityController(this._streaming, {NetworkQualityResolver? network})
      : _network = network;

  final StreamingService _streaming;

  /// Resuelve el ajuste "Calidad de video" (WiFi vs datos) al momento de
  /// pedir el stream. Nullable para tests / plataformas sin connectivity:
  /// sin resolver se usa el tope histórico de 720p.
  final NetworkQualityResolver? _network;

  /// videoId → info del stream (null = checked y no tiene video).
  /// Antes guardábamos solo la URL — necesitamos también `hasAudio` para que
  /// `MusicVideoPlayer` decida si mutea el audio principal cuando el usuario
  /// activa el toggle "ver video": si el stream no trae pista de audio, NO
  /// debe mutear (sino → silencio).
  final Map<String, VideoStreamInfo?> _cache = {};
  final Set<String> _inFlight = {};

  /// Toggle de "mostrar video en la cover del PlayerScreen". Per-session
  /// (no persistido) — el usuario lo cambia con un botón en la cover.
  bool _showAsCover = false;
  bool get showAsCover => _showAsCover;

  void setShowAsCover(bool value) {
    if (_showAsCover == value) return;
    _showAsCover = value;
    notifyListeners();
  }

  /// `true` si ya verificamos este videoId (positivo o negativo).
  bool isChecked(String videoId) => _cache.containsKey(videoId);

  /// `true` si verificado Y hay video disponible.
  bool isAvailable(String videoId) => _cache[videoId] != null;

  /// URL del video si está disponible (null si no se ha checked o no hay).
  String? urlFor(String videoId) => _cache[videoId]?.url;

  /// `true` si el stream del video trae audio embebido (formato combinado).
  /// Si es `false`, el caller debe mantener el audio principal (los streams
  /// video-only no tienen pista de audio).
  bool hasAudioFor(String videoId) => _cache[videoId]?.hasAudio ?? false;

  /// Verifica si hay video para [videoId]. Idempotente — usa cache. Notifica
  /// cuando el cache cambia para que la UI reaccione (botón toggle aparece /
  /// desaparece según resultado).
  Future<void> ensureChecked(String videoId) async {
    if (_cache.containsKey(videoId)) return;
    if (_inFlight.contains(videoId)) return;
    _inFlight.add(videoId);
    try {
      final info = await _streaming.resolveVideoUrl(
        videoId,
        maxHeightPx: _network?.videoQuality.maxVideoHeightPx ?? 720,
      );
      _cache[videoId] = info;
      notifyListeners();
    } catch (e) {
      devLog('VideoAvailability ensureChecked $videoId error: $e');
      _cache[videoId] = null;
      notifyListeners();
    } finally {
      _inFlight.remove(videoId);
    }
  }
}
