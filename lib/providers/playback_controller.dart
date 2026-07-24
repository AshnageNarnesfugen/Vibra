import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings/settings_controller.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/palette_signal.dart';
import '../models/song.dart';
import '../services/audio_metadata.dart';
import '../services/audio_service.dart';
import '../services/download_service.dart';
import '../services/dsd_decoder.dart';
import '../services/library_service.dart';
import '../services/network_quality_resolver.dart';
import '../services/streaming/streaming_service.dart';
import '../core/dev_log.dart';

/// Modos de repetición del reproductor.
enum PlaybackRepeatMode {
  /// Sin repetición: al terminar la cola, para.
  off,

  /// Repite TODA la cola: al terminar el último, vuelve al primero.
  all,

  /// Repite la canción actual indefinidamente.
  one,
}

/// Estado de reproducción y cola. Cuando cambia la fuente de la biblioteca
/// (auto / manual / streaming) detenemos lo que esté sonando y limpiamos la
/// cola — antes pasaba que el track local seguía cuando ibas a streaming.
/// Los errores de reproducción (URL caducada, sin conexión, etc.) se
/// publican vía [errors] para que la UI los pueda enseñar.
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.audio,
    required this.library,
    required this.palette,
    required this.streaming,
    required this.settings,
    this.network,
    this.downloads,
  }) {
    _wireListeners();
    _lastSource = settings.value.librarySource;
    settings.addListener(_onSettingsChanged);
    // Aplicar speed/pitch UNA VEZ al arrancar. settings.addListener no
    // dispara para el estado inicial, así que sin esto el primer track
    // de la sesión arrancaría a 1.0/1.0 aunque el usuario tenga otro
    // valor guardado. just_audio preserva ambos entre setAudioSource, así
    // que solo necesitamos sembrarlo aquí.
    // ignore: discarded_futures
    applyPlaybackParams();
  }

  final AudioService audio;
  final LibraryService library;
  final PaletteSignal palette;
  final StreamingService streaming;
  final SettingsController settings;
  /// Opcional para entornos donde no hay connectivity (desktop tests).
  /// Cuando null, se pide a YT el bitrate más alto disponible.
  final NetworkQualityResolver? network;
  final DownloadService? downloads;

  /// Stream para mensajes de error visibles (la UI los muestra en SnackBar).
  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errors => _errorController.stream;

  /// Wrapper seguro de `_errorController.add`: los errores del player
  /// llegan por callbacks async que pueden disparar DESPUÉS del dispose
  /// (que cierra el StreamController). `.add()` sobre un controller
  /// cerrado lanza StateError — un crash silencioso en background que
  /// solo se ve en Sentry. Con el guard, el error tardío simplemente
  /// se descarta (ya no hay UI que lo muestre de todos modos).
  void _emitError(String msg) {
    if (_errorController.isClosed) return;
    _errorController.add(msg);
  }

  late LibrarySource _lastSource;

  final List<Song> _queue = [];
  int _index = -1;

  /// Cola original (sin barajar) — guardada cuando se activa shuffle para
  /// poder restaurar el orden al desactivarlo.
  List<Song>? _originalQueue;

  bool _shuffle = false;
  bool get shuffleEnabled => _shuffle;

  PlaybackRepeatMode _repeat = PlaybackRepeatMode.off;
  PlaybackRepeatMode get repeatMode => _repeat;

  Song? get currentSong =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  List<Song> get queue => List.unmodifiable(_queue);
  int get currentIndex => _index;

  // ─── Persistencia de la sesión (cola + índice + posición) ───
  // La cola sobrevive cierres de app: se guarda debounceada en cada
  // notifyListeners y se restaura al arrancar SIN reproducir — el mini
  // player aparece con la última canción lista y el primer play retoma
  // donde ibas. Sin esto, cerrar la app perdía la cola completa.
  static const _kSessionKey = 'vibra.queueSession.v1';

  /// Cap de canciones persistidas — con autoplay la cola puede crecer
  /// indefinidamente; guardamos una ventana alrededor de lo relevante.
  static const _kSessionMaxSongs = 300;

  Timer? _persistDebounce;

  /// `true` cuando la cola viene de una restauración y AÚN no se cargó
  /// ninguna fuente de audio. El primer play (togglePlayPause) carga la
  /// canción y hace seek a la posición guardada. Se limpia en cuanto el
  /// usuario reproduce cualquier cosa.
  bool _restorePending = false;
  int _restorePositionMs = 0;

  @override
  void notifyListeners() {
    super.notifyListeners();
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 1), () {
      // ignore: discarded_futures
      _persistSession();
    });
  }

  Future<void> _persistSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_queue.isEmpty) {
        await prefs.remove(_kSessionKey);
        return;
      }
      var songs = _queue;
      var index = _index;
      if (songs.length > _kSessionMaxSongs) {
        // Ventana centrada en la canción actual.
        final start = (index - 50).clamp(0, songs.length - _kSessionMaxSongs);
        songs = songs.sublist(start, start + _kSessionMaxSongs);
        index = (index - start).clamp(0, songs.length - 1);
      }
      await prefs.setString(
        _kSessionKey,
        jsonEncode({
          'songs': [for (final s in songs) s.toJson()],
          'index': index,
          'positionMs': _positionNotifier.value.inMilliseconds,
        }),
      );
    } catch (e) {
      devLog('persistSession failed: $e');
    }
  }

  /// Restaura la última sesión guardada. Llamar UNA vez al arrancar,
  /// después de construir el controller. No reproduce nada — solo deja
  /// la cola lista y el mini player visible.
  Future<void> restoreSession() async {
    if (_queue.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSessionKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic>) return;
      final rawSongs = m['songs'];
      if (rawSongs is! List || rawSongs.isEmpty) return;
      final songs = <Song>[
        for (final s in rawSongs)
          if (s is Map<String, dynamic>) Song.fromJson(s),
      ];
      if (songs.isEmpty) return;
      // El usuario pudo empezar a reproducir mientras leíamos prefs.
      if (_queue.isNotEmpty) return;
      _queue.addAll(songs);
      _index = ((m['index'] as num?)?.toInt() ?? 0)
          .clamp(0, _queue.length - 1);
      _restorePositionMs = (m['positionMs'] as num?)?.toInt() ?? 0;
      _restorePending = true;
      devLog('restoreSession: ${songs.length} canciones, index=$_index');
      notifyListeners();
    } catch (e) {
      devLog('restoreSession failed: $e');
    }
  }

  // ─── Sleep timer ───
  // Dos modos excluyentes: por minutos (pausa con fade al vencer) o
  // "al terminar la canción actual". Estado en el controller para que
  // sobreviva a cerrar/abrir el sheet y se vea desde cualquier UI.
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  bool _sleepAtTrackEnd = false;

  /// Hora a la que se pausará (modo minutos), o null.
  DateTime? get sleepDeadline => _sleepDeadline;

  /// `true` si se pausará al terminar la canción actual.
  bool get sleepAtTrackEnd => _sleepAtTrackEnd;
  bool get sleepTimerActive => _sleepDeadline != null || _sleepAtTrackEnd;

  void startSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    _sleepAtTrackEnd = false;
    _sleepDeadline = DateTime.now().add(d);
    _sleepTimer = Timer(d, () async {
      _sleepDeadline = null;
      _sleepTimer = null;
      // Pausa con el fade configurado — cortar la música en seco es lo
      // contrario del objetivo de un sleep timer.
      await _fadeOutAndPause();
      notifyListeners();
    });
    notifyListeners();
  }

  void setSleepAtTrackEnd() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _sleepAtTrackEnd = true;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _sleepAtTrackEnd = false;
    notifyListeners();
  }

  /// Primer play tras una restauración: carga la fuente y retoma en la
  /// posición guardada.
  Future<void> _resumeRestored() async {
    _restorePending = false;
    final pos = _restorePositionMs;
    _restorePositionMs = 0;
    await playAt(_index);
    if (pos > 3000) {
      try {
        await seek(Duration(milliseconds: pos));
      } catch (_) {}
    }
  }

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  /// Info técnica de formato del archivo actual (codec, bit depth,
  /// sample rate, hi-res). Solo se computa para canciones locales — para
  /// streaming la URI es una placeholder `ytmusic://` y no podemos leer
  /// headers sin descargar. Null mientras no haya canción o mientras se
  /// está leyendo.
  ///
  /// Los listeners de UI (badge en el player) usan este ValueNotifier
  /// directo, sin pasar por notifyListeners() del controller — así no
  /// disparamos rebuilds del player en cada cambio de formato.
  final ValueNotifier<AudioFormatInfo?> currentFormat =
      ValueNotifier<AudioFormatInfo?>(null);

  /// True mientras estamos transcodificando un archivo DSD a PCM antes
  /// de cargarlo al player. La UI muestra un loading + texto explicativo
  /// durante este tiempo (puede tardar varios segundos según tamaño).
  final ValueNotifier<bool> isDecodingDsd = ValueNotifier<bool>(false);

  /// Mute/unmute SIN cambiar el estado de play/pause. Lo usa
  /// `MusicVideoPlayer` cuando el usuario activa "ver video": el audio del
  /// video reemplaza al de la canción, así que muteamos el audio principal
  /// para evitar duplicados. Como no pausa, no dispara cascadas de UI
  /// (notificación de sistema sigue mostrando "Reproduciendo", botón sigue
  /// en pause, scrubber sigue avanzando — todo coherente con el video).
  void setMuted(bool muted) {
    try {
      audio.player.setVolume(muted ? 0.0 : 1.0);
    } catch (_) {}
  }

  /// Posición vive en un `ValueNotifier` separado del ChangeNotifier
  /// principal — sino `notifyListeners` se disparaba ~10 veces por segundo
  /// por los ticks del player, y CADA notify rebuildea TODA la UI que
  /// observa `PlaybackController` (PlayerScreen, mini-player, queue list,
  /// shuffle/repeat icons, etc.). Resultado: stuttering visible.
  ///
  /// Patrón: el Scrubber (único widget que necesita position fresca) usa
  /// `ValueListenableBuilder<Duration>(valueListenable: pb.positionNotifier)`
  /// y rebuildea solo a sí mismo. El resto de UI sigue observando el
  /// ChangeNotifier que solo notifica en cambios de estado reales (song,
  /// play/pause, queue).
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier<Duration>(Duration.zero);
  ValueListenable<Duration> get positionNotifier => _positionNotifier;
  Duration get position => _positionNotifier.value;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  bool _loading = false;
  bool get isLoading => _loading;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlaybackEvent>? _eventSub;

  // Contador de fallos consecutivos para auto-skip por errores de
  // streaming (timeout HTTP, socket cerrado, URL expirada, etc.). Si
  // varias canciones seguidas fallan asumimos que es un problema mayor
  // (sin red, banneo) y paramos en vez de saltar la cola completa.
  int _consecutiveErrorCount = 0;
  static const int _maxConsecutiveErrors = 3;

  // Flag para evitar re-entrar al manejador mientras estamos haciendo el
  // re-resolve+retry de una URL expirada. Sin esto un segundo error
  // disparado por el reintento volvería a entrar al handler y se
  // generaría un loop / doble skip.
  bool _retryingCurrent = false;

  void _wireListeners() {
    _stateSub = audio.playerStateStream.listen((s) {
      _isPlaying = s.playing;
      // Track reproduciéndose OK → resetea el contador de fallos. Sin
      // esto, un error aislado quedaría guardado y el siguiente fallo
      // (días después) lo trataría como "segundo consecutivo".
      if (s.playing && s.processingState == ProcessingState.ready) {
        _consecutiveErrorCount = 0;
      }
      if (s.processingState == ProcessingState.completed) {
        // En repeat-one la lógica está en _onTrackComplete: re-seek a 0 y
        // play en vez de avanzar. En repeat-all y off, avanza con la lógica
        // estándar (que en repeat-off no envuelve al final de la cola).
        _onTrackComplete();
      }
      notifyListeners();
    });
    // Errores de runtime del player (SocketTimeout, Source error, etc.)
    // llegan por playbackEventStream.onError. Sin este listener el error
    // queda silencioso y la canción se "muere" sin avanzar — el usuario
    // tiene que tap manualmente al siguiente. Auto-skip lo arregla.
    _eventSub = audio.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        devLog('player runtime error: $e');
        // Reportamos a Sentry para tracking pero NO bloqueamos — el
        // handler maneja UX (retry+skip). Sentry queda no-op si no hay
        // DSN configurado. fire-and-forget.
        // ignore: discarded_futures
        Sentry.captureException(e, stackTrace: st);
        // ignore: discarded_futures
        _handlePlaybackError(e);
      },
    );
    // Position va al ValueNotifier separado — NO disparamos notifyListeners
    // global aquí. Solo el Scrubber rebuildea por cada tick (vía
    // ValueListenableBuilder en pb.positionNotifier).
    _posSub = audio.position.listen((p) {
      _positionNotifier.value = p;
    });
    _durSub = audio.totalDuration.listen((d) {
      _duration = d ?? Duration.zero;
      notifyListeners();
    });
  }

  /// Maneja un error de runtime del player. Flujo:
  ///   1. Si el error es de red en una canción streaming Y no estamos
  ///      ya reintentando, hace un `forceRefresh` de la URL y reintenta
  ///      una vez (URL probablemente expirada por throttling de YT).
  ///   2. Si el retry falla o el error no es de red, surfacea mensaje
  ///      y auto-skip a la siguiente.
  ///   3. Si superamos N fallos consecutivos (probable problema mayor
  ///      sin red, IP banneada, etc.), pausamos para no quemar la cola.
  Future<void> _handlePlaybackError(Object e) async {
    if (_retryingCurrent) return;
    _consecutiveErrorCount++;
    final song = currentSong;
    if (_consecutiveErrorCount >= _maxConsecutiveErrors) {
      _emitError(
        'Reproducción detenida tras varios errores seguidos. '
        'Verifica tu conexión.',
      );
      try {
        await audio.player.pause();
      } catch (_) {}
      return;
    }

    // Detectamos errores que típicamente significan "URL expirada":
    // SocketTimeout, Socket closed, Source error. En esos casos vale
    // pedir una URL fresca al endpoint /player y reintentar UNA vez
    // antes de saltar.
    final errStr = e.toString().toLowerCase();
    final looksLikeExpiredUrl = errStr.contains('timeout') ||
        errStr.contains('socket') ||
        errStr.contains('source error');
    if (song != null &&
        song.isStreaming &&
        song.streamingId != null &&
        looksLikeExpiredUrl) {
      _retryingCurrent = true;
      try {
        _emitError('URL expirada — refrescando…');
        final freshUrl = await streaming.resolveStreamUrl(
          song.streamingId!,
          forceRefresh: true,
          targetBitrateBps:
              network?.audioQuality.targetBitrateBps ?? (1 << 30),
        );
        await audio.setUri(freshUrl);
        await audio.player.play();
        _retryingCurrent = false;
        return; // éxito, no saltamos
      } catch (_) {
        // Falló el retry — caemos a auto-skip abajo.
      } finally {
        _retryingCurrent = false;
      }
    }

    _emitError(
      song != null
          ? 'No se pudo reproducir "${song.title}". Pasando a la siguiente…'
          : 'Error de reproducción. Pasando a la siguiente…',
    );
    await next();
  }

  void _onSettingsChanged() {
    final src = settings.value.librarySource;
    if (src != _lastSource) {
      _lastSource = src;
      // Cambio de fuente → cualquier cosa que estuviera sonando deja de tener
      // sentido. Paramos limpio.
      // ignore: discarded_futures
      stopAndClear();
    }
    // Speed/pitch viven en settings — al cambiar el usuario en el sheet,
    // este listener se dispara y aplica al player en vivo. No es el único
    // punto: también se llama en cada source change para asegurar que un
    // track nuevo arranca con los valores del usuario (algunos backends
    // resetean los AudioFx al cargar fuente).
    // ignore: discarded_futures
    applyPlaybackParams();
  }

  // Últimos valores efectivamente aplicados al player. Evita llamadas
  // redundantes al MethodChannel: `_onSettingsChanged` se dispara por
  // CUALQUIER cambio de settings (arrastrar el slider de blur emite
  // decenas de updates por segundo) y sin este guard cada uno producía
  // un par setSpeed+setPitch hacia el lado nativo.
  double? _appliedSpeed;
  double? _appliedPitchMul;

  /// Velocidad de reproducción efectiva actual. La consume el
  /// MusicVideoPlayer para que el video corra al MISMO ritmo que el audio
  /// — sin esto, con velocidad ≠ 1× el video derivaba constantemente y el
  /// sync timer vivía haciendo seeks.
  double get currentSpeed => _appliedSpeed ?? 1.0;

  /// Aplica `playbackSpeed` y `playbackPitchSemitones` (convertido a
  /// multiplicador) al player. Llamar después de cada `setAudioSource` y
  /// cuando el usuario cambie los sliders del sheet. Es idempotente —
  /// si los valores efectivos no cambiaron desde la última aplicación,
  /// retorna sin tocar el player.
  ///
  /// Pitch en just_audio Android es un multiplicador: 1.0 = sin shift,
  /// 2.0 = una octava arriba, 0.5 = una octava abajo. Los semitonos vienen
  /// del usuario y se convierten con `pow(2, s/12)`.
  ///
  /// Cuando [UiSettings.lockPitchToSpeed] es true, el pitch sigue al speed
  /// (chipmunk effect) — útil si el usuario QUIERE el efecto retro de
  /// "rebobinar lento" o "acelerar agudo". Default false: pitch y speed
  /// independientes via Sonic time-stretch.
  ///
  /// iOS: setPitch es no-op en just_audio actual; solo el speed se aplica.
  Future<void> applyPlaybackParams() async {
    final s = settings.value;
    final speed = s.playbackSpeed.clamp(0.5, 2.0);
    // pow(2, semitones/12) → multiplicador. Con semitones=0 da 1.0 exacto.
    final pitchMul = s.lockPitchToSpeed
        ? speed
        : math.pow(2, s.playbackPitchSemitones / 12.0).toDouble();
    if (speed == _appliedSpeed && pitchMul == _appliedPitchMul) return;
    _appliedSpeed = speed;
    _appliedPitchMul = pitchMul;
    try {
      await audio.player.setSpeed(speed);
    } catch (e) {
      devLog('applyPlaybackParams: setSpeed($speed) failed: $e');
    }
    try {
      await audio.player.setPitch(pitchMul);
    } catch (e) {
      // iOS lanza UnsupportedError aquí — esperado, no loguear si no es
      // grave. En Android cualquier error real sí queremos verlo.
      if (!kIsWeb && !defaultTargetPlatform.toString().contains('iOS')) {
        devLog('applyPlaybackParams: setPitch($pitchMul) failed: $e');
      }
    }
  }

  /// Para el reproductor y limpia la cola. La paleta también, así el fondo
  /// vuelve al definido por el usuario.
  Future<void> stopAndClear() async {
    try {
      await audio.player.stop();
    } catch (_) {}
    _queue.clear();
    _index = -1;
    _isPlaying = false;
    _positionNotifier.value = Duration.zero;
    _duration = Duration.zero;
    palette.clear();
    notifyListeners();
  }

  /// Reemplaza la cola y reproduce desde [startIndex]. Si la cola queda
  /// vacía, también limpiamos paleta y carátula → el fondo vuelve al definido
  /// por el usuario.
  ///
  /// **Si shuffle está activo**, baraja la nueva cola preservando la
  /// canción de `startIndex` al frente. Sin esto, el flag decía ON pero el
  /// audio iba en orden secuencial → la info en pantalla quedaba desfasada
  /// de lo que sonaba al cambiar de álbum/playlist con shuffle activo.
  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) {
      _queue.clear();
      _index = -1;
      _originalQueue = null;
      palette.clear();
      notifyListeners();
      return;
    }

    final start = startIndex.clamp(0, songs.length - 1);
    final startSong = songs[start];

    if (_shuffle && songs.length > 1) {
      // Original (orden secuencial) se guarda para restaurar si shuffle se
      // apaga después.
      _originalQueue = List<Song>.from(songs);
      final rest = List<Song>.from(songs)..removeAt(start);
      rest.shuffle(math.Random());
      _queue
        ..clear()
        ..add(startSong)
        ..addAll(rest);
      _index = -1;
      await playAt(0);
      return;
    }

    // Sin shuffle: cola tal cual. Limpia cualquier _originalQueue stale.
    _originalQueue = null;
    _queue
      ..clear()
      ..addAll(songs);
    _index = -1;
    await playAt(start);

    // Si solo encolaste UNA canción streaming, pedimos al endpoint `next`
    // de YT Music sus "Up next" recomendaciones y las appendamos al final
    // del queue — así reproducir una sola canción se convierte
    // automáticamente en una radio infinita del estilo del track. No
    // bloqueamos `setQueue` esperando esto (corre async en background).
    if (songs.length == 1 && songs.first.isStreaming &&
        songs.first.streamingId != null) {
      _autoExpandQueueWithRecs(songs.first.streamingId!);
    }
  }

  /// Inserta [song] justo DESPUÉS de la canción actual — la próxima en
  /// sonar después de la que está activa. Si no hay canción activa
  /// (cola vacía), inicia reproducción con [song].
  ///
  /// Usado por el menú contextual "Reproducir a continuación".
  Future<void> playNext(Song song) async {
    if (_queue.isEmpty || _index < 0) {
      await setQueue([song]);
      return;
    }
    final insertAt = _index + 1;
    _queue.insert(insertAt, song);
    // Si shuffle está ON, sincronizamos también la cola original — sino
    // al desactivar shuffle perderíamos la canción agregada.
    _originalQueue?.insert(insertAt, song);
    notifyListeners();
  }

  /// Añade [song] al FINAL de la cola actual. Si la cola está vacía,
  /// arranca reproducción con [song].
  ///
  /// Usado por el menú contextual "Añadir a la cola actual".
  Future<void> addToCurrentQueue(Song song) async {
    if (_queue.isEmpty) {
      await setQueue([song]);
      return;
    }
    _queue.add(song);
    _originalQueue?.add(song);
    notifyListeners();
  }

  /// Mueve la canción de [oldIndex] a [newIndex] en la cola. Preserva la
  /// referencia a la canción actualmente reproduciéndose ajustando [_index]
  /// si fue movida o si su posición cambió por el desplazamiento.
  ///
  /// **Convención de Flutter `ReorderableListView`**: cuando arrastras un
  /// item hacia ABAJO, [newIndex] viene 1 más alto que la posición destino
  /// real (porque incluye al item siendo movido en el cálculo). Lo
  /// normalizamos restando 1 si `newIndex > oldIndex`.
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex > _queue.length) {
      return;
    }
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);

    // Ajuste de _index para no perder la canción activa.
    if (_index == oldIndex) {
      // La canción activa fue la movida → su nuevo índice es newIndex.
      _index = newIndex;
    } else if (oldIndex < _index && newIndex >= _index) {
      // La canción movida estaba ANTES de la activa y se fue DESPUÉS:
      // la activa "subió" un puesto.
      _index -= 1;
    } else if (oldIndex > _index && newIndex <= _index) {
      // Movida estaba DESPUÉS y se fue ANTES: la activa "bajó" un puesto.
      _index += 1;
    }

    // Cola original (cuando shuffle ON) NO se reordena — el orden
    // shuffle es el que importa para el usuario. Al apagar shuffle se
    // restaurará el original sin tocar.
    notifyListeners();
  }

  /// Auto-pulla recomendaciones de YT Music y las añade al final de la
  /// cola. Idempotente — si ya está corriendo o ya pulleamos exitosamente
  /// para esta canción, no hace nada.
  String? _lastRecsSeedId;
  bool _pullingRecs = false;
  Future<void> _autoExpandQueueWithRecs(String videoId,
      {int retriesLeft = 2}) async {
    if (_pullingRecs) return;
    if (_lastRecsSeedId == videoId) return;
    _pullingRecs = true;
    try {
      final recs = await streaming.getRecommendedQueue(videoId);
      // No memoizamos en caso vacío: en el PRIMER play tras abrir la app
      // la sesión de YT Music a veces aún no está totalmente caliente y
      // el endpoint /next devuelve [] → si guardábamos el seedId aquí,
      // bloqueábamos cualquier retry futuro para esta canción. Ahora
      // solo memoizamos cuando realmente añadimos tracks al queue.
      if (recs.isEmpty) {
        // Retry con backoff: la sesión puede haberse calentado en estos
        // segundos (visitorData/dataSyncId/cookies que el cliente
        // refresca en background al hacer otros calls como library/home).
        // Sin esto, el primer play tras abrir la app se queda con cola=1
        // hasta que el usuario tap otra canción → mala UX.
        if (retriesLeft > 0 && currentSong?.streamingId == videoId) {
          _pullingRecs = false;
          await Future<void>.delayed(const Duration(seconds: 3));
          if (currentSong?.streamingId == videoId) {
            return _autoExpandQueueWithRecs(videoId,
                retriesLeft: retriesLeft - 1);
          }
        }
        return;
      }
      // Dedupe contra las canciones ya en cola — el "Up next" suele
      // incluir la propia canción seed en algunas variantes.
      final existing = _queue
          .map((s) => s.streamingId)
          .whereType<String>()
          .toSet();
      final newSongs = <Song>[];
      for (final t in recs) {
        if (existing.contains(t.videoId)) continue;
        newSongs.add(t.toSong());
      }
      if (newSongs.isEmpty) return;
      // Si durante el await el usuario cambió de canción, la semilla ya
      // no aplica — evitamos contaminar el queue actual con recs de una
      // canción anterior.
      if (currentSong?.streamingId != videoId) return;
      _queue.addAll(newSongs);
      _lastRecsSeedId = videoId;
      notifyListeners();
    } catch (_) {
      // Falla silenciosa — el usuario aún puede seguir con su cola actual.
    } finally {
      _pullingRecs = false;
    }
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    // Cualquier reproducción explícita invalida el estado "restaurado
    // pendiente" — el usuario ya eligió qué oír.
    _restorePending = false;
    _index = index;
    final song = _queue[_index];

    // Format info: limpiar inmediatamente (la canción anterior ya no es la
    // que suena) y leer en background para canciones locales. Streaming
    // queda null hasta que tengamos un parser para los blobs de YT.
    currentFormat.value = null;
    if (!song.isStreaming) {
      // Fire-and-forget — el read es típicamente <2ms pero no queremos
      // bloquear el inicio de reproducción si por algún motivo el FS es lento.
      // ignore: discarded_futures
      AudioMetadataReader.read(song.uri).then((info) {
        // Solo aplicar si seguimos en la misma canción (el usuario pudo
        // haber pasado a otra mientras leíamos).
        if (currentSong?.uri == song.uri) {
          currentFormat.value = info;
        }
      });
    }

    // Actualizamos paleta y fondo INMEDIATAMENTE para evitar lag visual.
    if (song.isStreaming && song.thumbnailUrl != null) {
      _fetchAndApplyThumbnail(song.thumbnailUrl!);
    } else {
      library.loadArtwork(song).then((bytes) {
        if (bytes != null) {
          palette.updateArtworkOnly(bytes);
          palette.updateFromBytes(bytes);
        } else {
          palette.clear();
        }
      });
    }

    _loading = true;
    notifyListeners();
    try {
      // Para canciones de streaming la URI guardada es un placeholder
      // `ytmusic://${videoId}`. Antes de pedir a la API InnerTube, miramos
      // si tenemos una copia OFFLINE — descargada vía DownloadService — y
      // la usamos directamente. Reproducción sin red para canciones que el
      // usuario marcó "descargar".
      // No es final porque el branch de DSD lo reemplaza por la URI del
      // PCM cacheado tras decodificar.
      String playableUri;
      if (song.isStreaming) {
        final localPath = downloads?.localPath(song.id);
        if (localPath != null) {
          playableUri = localPath;
        } else {
          playableUri = await streaming.resolveStreamUrl(
            song.streamingId!,
            targetBitrateBps:
                network?.audioQuality.targetBitrateBps ?? (1 << 30),
          );
        }
      } else {
        playableUri = song.uri;
      }

      // DSD interception: ExoPlayer no decodifica DSD nativamente. Si la
      // URI apunta a un .dsf/.dff, lo pasamos por DsdDecoder que produce
      // un PCM WAV cacheado (en getTemporaryDirectory) y reproducimos
      // eso. Si la decodificación falla, surfaceamos error al UI con
      // mensaje específico (no el genérico "no se pudo reproducir").
      if (!song.isStreaming && DsdDecoder.isDsdFile(playableUri)) {
        isDecodingDsd.value = true;
        try {
          final pcmPath = await DsdDecoder.resolveToPcm(playableUri);
          if (pcmPath == null) {
            _emitError(
              'No se pudo decodificar el archivo DSD. '
              'Verifica que sea un .dsf válido (DSD64 estéreo).',
            );
            isDecodingDsd.value = false;
            _loading = false;
            notifyListeners();
            return;
          }
          playableUri = pcmPath;
          // Tras decode el formato efectivo cambia — el badge en el
          // player ahora muestra "DSD64 → PCM 24-bit / 176.4 kHz" hasta
          // que la siguiente canción reset.
          AudioMetadataReader.read(pcmPath).then((info) {
            if (currentSong?.uri == song.uri && info != null) {
              currentFormat.value = info;
            }
          });
        } finally {
          isDecodingDsd.value = false;
        }
      }

      await audio.setUri(playableUri);
      await audio.player.play();
      // Pre-warm la URL de la próxima canción para evitar el delay de la API
      // entre tracks. Es fire-and-forget.
      // ignore: discarded_futures
      _prefetchNext();
    } catch (e) {
      devLog('play error: $e');
      // Surfaceamos el error a la UI: SnackBar con mensaje legible.
      final msg = song.isStreaming
          ? 'No se pudo reproducir desde YouTube Music: ${_short(e)}'
          : 'No se pudo reproducir el archivo: ${_short(e)}';
      _emitError(msg);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _prefetchNext() async {
    if (_queue.isEmpty) return;
    final ni = (_index + 1) % _queue.length;
    if (ni == _index) return;
    final next = _queue[ni];
    if (!next.isStreaming) return;
    try {
      await streaming.resolveStreamUrl(
        next.streamingId!,
        targetBitrateBps:
            network?.audioQuality.targetBitrateBps ?? (1 << 30),
      );
    } catch (_) {
      // Silencioso: si falla, lo veremos cuando toque reproducir.
    }
  }

  Future<void> _fetchAndApplyThumbnail(String url) async {
    // Informamos la URL inmediatamente para que el background cargue via Image.network
    palette.updateArtworkOnly(null, url: url);

    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        // Una vez descargado, pasamos los bytes para mayor rendimiento y paleta
        palette.updateArtworkOnly(res.bodyBytes, url: url);
        await palette.updateFromBytes(res.bodyBytes);
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (currentSong == null) return;
    // Cola restaurada de la sesión anterior sin fuente cargada: el primer
    // play carga la canción y retoma donde ibas.
    if (_restorePending) {
      await _resumeRestored();
      return;
    }
    if (_isPlaying) {
      await _fadeOutAndPause();
    } else {
      await _playWithFadeIn();
    }
  }

  /// Token incremental para invalidar fades en curso cuando llega otra
  /// orden de play/pause antes de terminar el ramp. Cada nuevo fade
  /// captura el token al inicio y verifica al final de cada step que
  /// sigue siendo el current — si no, abandona el loop.
  int _fadeToken = 0;

  Future<void> _fadeOutAndPause() async {
    final dur = _effectiveFadeMs();
    if (dur <= 0) {
      await audio.player.pause();
      return;
    }
    final token = ++_fadeToken;
    await _rampVolume(from: 1.0, to: 0.0, ms: dur, token: token);
    if (token != _fadeToken) return; // un toggle posterior nos pisó.
    await audio.player.pause();
    // Restaurar a 1.0 para que el próximo play empiece bien (sino
    // queda mute hasta el siguiente fade-in).
    try {
      await audio.player.setVolume(1.0);
    } catch (_) {}
  }

  Future<void> _playWithFadeIn() async {
    final dur = _effectiveFadeMs();
    if (dur <= 0) {
      // `player.play()` en just_audio NO retorna cuando arranca el
      // playback — retorna cuando TERMINA (pause/stop/fin de track).
      // Hacer `await` bloqueaba el método entero durante toda la
      // canción. Fire-and-forget para que el control vuelva inmediato.
      // ignore: discarded_futures
      audio.player.play();
      return;
    }
    final token = ++_fadeToken;
    try {
      await audio.player.setVolume(0.0);
    } catch (_) {}
    // Fire-and-forget de play(): si lo awaited, el ramp NUNCA correría
    // durante la reproducción porque el Future de play() solo completa
    // cuando el usuario pausa. Bug reportado: audio silencioso durante
    // play + "pedazo con fade out" en pause (porque el ramp del pause
    // arrancaba en vol=0.95, salto súbito audible antes de bajar a 0).
    // ignore: discarded_futures
    audio.player.play();
    await _rampVolume(from: 0.0, to: 1.0, ms: dur, token: token);
  }

  /// Duración efectiva del fade. Devuelve 0 si el feature está OFF, si
  /// el slider está al mínimo, o si el audio está muteado (caso
  /// `setMuted(true)` para video — no queremos hacer fade-in
  /// silencioso).
  int _effectiveFadeMs() {
    final s = settings.value;
    if (!s.fadeOnPlayPauseEnabled) return 0;
    if (s.fadeDurationMs < 50) return 0;
    return s.fadeDurationMs;
  }

  /// Anima el volumen del player con steps de ~16ms (60fps). El [token]
  /// se compara contra `_fadeToken` en cada step → si otro toggle lo
  /// invalida, abandona limpio para que el nuevo fade tome control.
  Future<void> _rampVolume({
    required double from,
    required double to,
    required int ms,
    required int token,
  }) async {
    const stepMs = 16;
    final steps = (ms / stepMs).ceil().clamp(2, 200);
    final delta = (to - from) / steps;
    var v = from;
    for (var i = 0; i < steps; i++) {
      if (token != _fadeToken) return;
      v += delta;
      try {
        await audio.player.setVolume(v.clamp(0.0, 1.0));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: stepMs));
    }
    if (token != _fadeToken) return;
    try {
      await audio.player.setVolume(to.clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// Cuando termina una pista — distinto a `next()` porque debe respetar
  /// `repeat-one` (rebobinar y volver a tocar). El skip manual del usuario
  /// pasa por `next()` y siempre avanza.
  Future<void> _onTrackComplete() async {
    if (_queue.isEmpty) return;
    // Sleep timer en modo "fin de canción": pausa aquí en vez de avanzar.
    if (_sleepAtTrackEnd) {
      _sleepAtTrackEnd = false;
      await audio.player.pause();
      notifyListeners();
      return;
    }
    if (_repeat == PlaybackRepeatMode.one) {
      await audio.player.seek(Duration.zero);
      await audio.player.play();
      return;
    }
    await next();
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    final atEnd = _index >= _queue.length - 1;
    if (atEnd) {
      // Final de cola. En modo `all` envuelve; en `off` intenta autoplay
      // con recomendaciones (como YT Music) y si no puede, para. En `one`
      // no debería llegar acá (lo intercepta _onTrackComplete).
      if (_repeat == PlaybackRepeatMode.off) {
        if (await _tryAutoplayExtend()) return;
        await audio.player.pause();
        return;
      }
      await playAt(0);
      return;
    }
    await playAt(_index + 1);
  }

  /// Autoplay al agotar la cola: pide el "Up next" de YT Music seedeado
  /// en la última canción, appenda lo nuevo y sigue reproduciendo.
  /// Devuelve `true` si logró extender y avanzar; `false` deja al caller
  /// pausar como antes (setting apagado, canción local, endpoint vacío…).
  Future<bool> _tryAutoplayExtend() async {
    if (!settings.value.autoplayRelated) return false;
    final seed = currentSong;
    final seedId = seed?.streamingId;
    if (seed == null || !seed.isStreaming || seedId == null) return false;
    if (_pullingRecs) return false;
    _pullingRecs = true;
    try {
      final recs = await streaming.getRecommendedQueue(seedId);
      if (recs.isEmpty) return false;
      final existing =
          _queue.map((s) => s.streamingId).whereType<String>().toSet();
      final newSongs = <Song>[
        for (final t in recs)
          if (!existing.contains(t.videoId)) t.toSong(),
      ];
      if (newSongs.isEmpty) return false;
      // Si mientras esperábamos el endpoint el usuario cambió algo (tap a
      // otra canción, nueva cola), abortamos — sus acciones mandan.
      if (currentSong?.streamingId != seedId) return false;
      final insertAt = _queue.length;
      _queue.addAll(newSongs);
      _lastRecsSeedId = seedId;
      notifyListeners();
      await playAt(insertAt);
      return true;
    } catch (_) {
      return false;
    } finally {
      _pullingRecs = false;
    }
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    if (_positionNotifier.value.inSeconds > 3) {
      await audio.player.seek(Duration.zero);
      return;
    }
    if (_index == 0) {
      // En modo all, retroceder desde la primera lleva a la última.
      if (_repeat == PlaybackRepeatMode.all) {
        await playAt(_queue.length - 1);
      } else {
        await audio.player.seek(Duration.zero);
      }
      return;
    }
    await playAt(_index - 1);
  }

  /// Stream de eventos de seek. Lo escucha `MusicVideoPlayer` para mover
  /// el video controller a la misma posición — sin esto, arrastrar el
  /// scrubber con video activo movía solo el audio (muteado) y el video
  /// (que provee el sonido y la imagen) se quedaba donde estaba.
  final _seekController = StreamController<Duration>.broadcast();
  Stream<Duration> get seekEvents => _seekController.stream;

  Future<void> seek(Duration to) async {
    await audio.player.seek(to);
    // Notificamos DESPUÉS de que el audio confirmó el seek, así un
    // listener (video) que también busque no se adelanta a un seek que
    // pudo fallar. El guard isClosed evita StateError si llega un seek
    // tardío tras dispose.
    if (!_seekController.isClosed) _seekController.add(to);
  }

  /// Cicla entre los 3 modos de repetición.
  void cyclePlaybackRepeatMode() {
    _repeat = switch (_repeat) {
      PlaybackRepeatMode.off => PlaybackRepeatMode.all,
      PlaybackRepeatMode.all => PlaybackRepeatMode.one,
      PlaybackRepeatMode.one => PlaybackRepeatMode.off,
    };
    // just_audio gestiona repeat-one a nivel de player → más preciso que
    // hacerlo manual (sin gap entre el final y el restart).
    // ignore: discarded_futures
    audio.player.setLoopMode(
        _repeat == PlaybackRepeatMode.one ? LoopMode.one : LoopMode.off);
    notifyListeners();
  }

  /// Activa/desactiva el shuffle. Cuando se activa, baraja la cola
  /// preservando la canción actual al principio (no interrumpe lo que suena).
  /// Cuando se desactiva, restaura el orden original.
  ///
  /// El `_index` se recompute SIEMPRE por `id` después de mutar la cola — no
  /// confiamos en posiciones para evitar desfases si el shuffle/restore mete
  /// la canción en una posición distinta de la esperada.
  void toggleShuffle() {
    _shuffle = !_shuffle;
    final current = currentSong; // capturado antes de cualquier mutación
    if (_queue.isEmpty || current == null) {
      notifyListeners();
      return;
    }
    if (_shuffle) {
      _originalQueue = List<Song>.from(_queue);
      final rest = List<Song>.from(_queue)..removeAt(_index);
      rest.shuffle(math.Random());
      _queue
        ..clear()
        ..add(current)
        ..addAll(rest);
    } else if (_originalQueue != null) {
      _queue
        ..clear()
        ..addAll(_originalQueue!);
      _originalQueue = null;
    }
    // Recompute index por id. Si la canción ya no está (no debería), 0 safe.
    final newIndex = _queue.indexWhere((s) => s.id == current.id);
    _index = newIndex < 0 ? 0 : newIndex;
    notifyListeners();
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    _persistDebounce?.cancel();
    _sleepTimer?.cancel();
    _stateSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _eventSub?.cancel();
    _errorController.close();
    _seekController.close();
    _positionNotifier.dispose();
    currentFormat.dispose();
    isDecodingDsd.dispose();
    super.dispose();
  }
}
