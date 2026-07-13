import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyrics.dart';
import '../models/song.dart';
import '../services/lyrics_service.dart';
import 'playback_controller.dart';
import '../core/dev_log.dart';

enum LyricsStatus { idle, loading, loaded, notFound, error }

/// Estado de la letra para la canción actual.
///
/// **Estructura del notificador**:
///   - El `ChangeNotifier` principal notifica cuando cambia el estado
///     (loading → loaded), las letras cargadas o el flag `showLyrics`.
///   - `activeIndex` es un `ValueNotifier<int>` separado que se actualiza
///     en cada tick del audio (varias veces por segundo). Esto permite al
///     panel rebuildar solo la línea activa sin reconstruir todo el árbol.
class LyricsController extends ChangeNotifier {
  LyricsController({required this.service, required this.playback}) {
    playback.addListener(_onPlaybackChanged);
    playback.positionNotifier.addListener(_updateActiveIndex);
    // Estado inicial.
    _onPlaybackChanged();
  }

  final LyricsService service;
  final PlaybackController playback;

  /// videoId / fallback key → Lyrics (null = checked y no hay). Cache
  /// en memoria para no re-fetchear al volver a la misma canción.
  final Map<String, Lyrics?> _cache = {};
  String? _loadingKey;

  LyricsStatus _status = LyricsStatus.idle;
  LyricsStatus get status => _status;

  Lyrics? _current;
  Lyrics? get current => _current;

  /// Toggle global: si está OFF, el panel no se monta. Si está ON, el
  /// player oculta la carátula y muestra el LyricsPanel en su lugar.
  bool _showLyrics = false;
  bool get showLyrics => _showLyrics;
  void setShowLyrics(bool v) {
    if (_showLyrics == v) return;
    _showLyrics = v;
    notifyListeners();
  }

  void toggleShowLyrics() => setShowLyrics(!_showLyrics);

  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(-1);
  ValueListenable<int> get activeIndex => _activeIndex;

  String _keyFor(Song s) =>
      s.streamingId ?? '${s.title.toLowerCase()}|${s.artist.toLowerCase()}';

  void _onPlaybackChanged() {
    final song = playback.currentSong;
    if (song == null) {
      _setState(LyricsStatus.idle, null);
      return;
    }
    final key = _keyFor(song);
    if (_cache.containsKey(key)) {
      final cached = _cache[key];
      _setState(
        cached == null ? LyricsStatus.notFound : LyricsStatus.loaded,
        cached,
      );
      return;
    }
    if (_loadingKey == key) return;
    _loadingKey = key;
    _setState(LyricsStatus.loading, null);
    _fetch(song, key);
  }

  /// Re-intenta fetch para la canción actual (botón "reintentar" en el
  /// estado notFound/error). Invalida la entry del cache antes.
  void retry() {
    final song = playback.currentSong;
    if (song == null) return;
    final key = _keyFor(song);
    _cache.remove(key);
    _loadingKey = null;
    _onPlaybackChanged();
  }

  Future<void> _fetch(Song song, String key) async {
    try {
      final duration = playback.duration > Duration.zero
          ? playback.duration
          : null;
      final lyrics = await service.fetch(
        title: song.title,
        artist: song.artist,
        album: song.album.isNotEmpty ? song.album : null,
        duration: duration,
      );
      // Mientras el await corría, la canción puede haber cambiado. Solo
      // aplicamos el resultado si todavía es relevante.
      if (_loadingKey != key) return;
      _cache[key] = lyrics;
      _loadingKey = null;
      _setState(
        lyrics == null ? LyricsStatus.notFound : LyricsStatus.loaded,
        lyrics,
      );
    } catch (e) {
      devLog('LyricsController fetch failed: $e');
      if (_loadingKey != key) return;
      _loadingKey = null;
      _setState(LyricsStatus.error, null);
    }
  }

  void _setState(LyricsStatus status, Lyrics? lyrics) {
    _status = status;
    _current = lyrics;
    notifyListeners();
    _updateActiveIndex();
  }

  /// Recalcula qué línea está activa según `playback.position`. Solo notifica
  /// si el índice realmente cambió → el panel no se rebuild en cada tick si
  /// la línea sigue siendo la misma (caso normal para líneas de ~3s).
  void _updateActiveIndex() {
    final lyrics = _current;
    if (lyrics == null || !lyrics.synced || lyrics.isEmpty) {
      if (_activeIndex.value != -1) _activeIndex.value = -1;
      return;
    }
    final posMs = playback.position.inMilliseconds;
    // Búsqueda binaria del último timestamp <= posMs.
    int lo = 0, hi = lyrics.lines.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lyrics.lines[mid].time.inMilliseconds <= posMs) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (_activeIndex.value != idx) _activeIndex.value = idx;
  }

  @override
  void dispose() {
    playback.removeListener(_onPlaybackChanged);
    playback.positionNotifier.removeListener(_updateActiveIndex);
    _activeIndex.dispose();
    super.dispose();
  }
}
