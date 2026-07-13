import 'dart:async';

import 'package:audio_service/audio_service.dart' show
    BaseAudioHandler,
    MediaItem,
    MediaControl,
    MediaAction,
    PlaybackState,
    AudioProcessingState;
import 'package:just_audio/just_audio.dart' as ja;

import '../providers/playback_controller.dart';
import '../core/dev_log.dart';

/// Puente entre [PlaybackController] y `audio_service`.
///
/// `audio_service` expone los controles de reproducción al sistema operativo:
/// notificación en la barra, lockscreen, controles de auriculares Bluetooth,
/// Android Auto, etc. Para que el sistema sepa qué mostrar y a quién enviar
/// los taps, hay que implementar un [BaseAudioHandler] que:
///   1. **Publique** estado al sistema vía `playbackState.add(...)` y
///      `mediaItem.add(...)` cada vez que algo cambia en la app.
///   2. **Reciba** acciones del sistema (`play`, `pause`, `skipToNext`...)
///      y las propague al controller de la app.
///
/// **Importante**: la fuente de verdad para `processingState` y `playing` es
/// el `playerStateStream` de just_audio, NO los flags `_loading`/`_isPlaying`
/// de PlaybackController. Sin esto, el icono de la notificación se quedaba
/// "stuck" en loading porque `_loading` solo lo maneja `playAt()` con un
/// flag manual que no refleja `buffering`/`ready` reales del player.
class MediaSessionHandler extends BaseAudioHandler {
  MediaSessionHandler(this._pb, this._player) {
    // Cambios en la metadata (cola, canción actual, posición/duración):
    // se reflejan vía PlaybackController.
    _pb.addListener(_publishMetadata);
    // Estado de reproducción real (idle/loading/buffering/ready/completed +
    // playing true/false): viene directo del player. Esto es lo que la
    // notificación usa para mostrar spinner vs play/pause.
    _playerStateSub = _player.playerStateStream.listen((_) => _publishState());
    _publishMetadata();
    _publishState();
  }

  final PlaybackController _pb;
  final ja.AudioPlayer _player;
  StreamSubscription<ja.PlayerState>? _playerStateSub;

  static const _stateMap = <ja.ProcessingState, AudioProcessingState>{
    ja.ProcessingState.idle: AudioProcessingState.idle,
    ja.ProcessingState.loading: AudioProcessingState.loading,
    ja.ProcessingState.buffering: AudioProcessingState.buffering,
    ja.ProcessingState.ready: AudioProcessingState.ready,
    ja.ProcessingState.completed: AudioProcessingState.completed,
  };

  /// Construye el MediaItem (lo que el sistema usa para pintar título,
  /// artista, carátula). Sin un MediaItem activo no sale notificación.
  void _publishMetadata() {
    final song = _pb.currentSong;
    if (song == null) return;
    mediaItem.add(MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: _pb.duration > Duration.zero ? _pb.duration : null,
      // Para streaming usamos la URL remota directamente. Para canciones
      // locales no seteamos artUri — los bytes están en memoria y meterlos
      // como data: URI suele exceder límites del sistema.
      artUri: (song.thumbnailUrl != null && song.thumbnailUrl!.isNotEmpty)
          ? Uri.tryParse(song.thumbnailUrl!)
          : null,
    ));
    // Republica el estado para refrescar la posición/duración del progress
    // bar de la notificación cuando avanza el track.
    _publishState();
  }

  /// Publica el playbackState al sistema. Lee directo de just_audio para
  /// que el icono de la notificación refleje el estado REAL (spinner
  /// durante loading/buffering, pause cuando está playing, play cuando no).
  void _publishState() {
    final hasPrev = _pb.queue.length > 1;
    final hasNext = _pb.queue.length > 1;
    final processing =
        _stateMap[_player.processingState] ?? AudioProcessingState.idle;

    playbackState.add(PlaybackState(
      controls: [
        if (hasPrev) MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        if (hasNext) MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
      },
      androidCompactActionIndices: [
        if (hasPrev) 0 else -1,
        hasPrev ? 1 : 0,
        if (hasNext) (hasPrev ? 2 : 1) else -1,
      ].where((i) => i >= 0).cast<int>().toList(),
      processingState: processing,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _pb.currentIndex >= 0 ? _pb.currentIndex : null,
    ));
  }

  // -------- Callbacks del sistema → PlaybackController --------

  @override
  Future<void> play() async {
    if (_pb.currentSong != null && !_pb.isPlaying) {
      await _pb.togglePlayPause();
    }
  }

  @override
  Future<void> pause() async {
    if (_pb.isPlaying) {
      await _pb.togglePlayPause();
    }
  }

  @override
  Future<void> skipToNext() => _pb.next();

  @override
  Future<void> skipToPrevious() => _pb.previous();

  @override
  Future<void> seek(Duration position) => _pb.seek(position);

  @override
  Future<void> stop() async {
    await _pb.stopAndClear();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // El usuario quitó la app de recientes — paramos para liberar recursos
    // y que el foreground service termine.
    try {
      await _pb.stopAndClear();
    } catch (e) {
      devLog('onTaskRemoved stop error: $e');
    }
    await super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // Usuario deslizó la notificación → para limpio.
    try {
      await _pb.stopAndClear();
    } catch (e) {
      devLog('onNotificationDeleted stop error: $e');
    }
  }

  /// Libera la suscripción al player cuando el handler ya no se usa. Como
  /// `BaseAudioHandler` no define un dispose estándar, esto se llama
  /// manualmente desde el shutdown de la app si es necesario.
  Future<void> dispose() async {
    _pb.removeListener(_publishMetadata);
    await _playerStateSub?.cancel();
    _playerStateSub = null;
  }
}
