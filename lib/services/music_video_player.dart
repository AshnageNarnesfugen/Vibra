import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../providers/playback_controller.dart';
import 'video_availability_controller.dart';
import '../core/dev_log.dart';

/// Controlador ÚNICO del music video de la canción actual.
///
/// Antes había dos `VideoPlayerController` separados (uno en el cover y otro
/// en el background) que causaban:
///   1. Desincronización audio↔video (cada uno avanza por su cuenta).
///   2. El "pause" del usuario solo paraba uno; el otro seguía corriendo.
///   3. Si el background no se montaba (modo de fondo distinto), el video se
///      veía solo en la carátula.
///
/// Esta clase mantiene UN solo `VideoPlayerController` y lo expone via
/// `controller`. Tanto `MusicVideoCover` como `MusicVideoBackgroundLayer` lo
/// dibujan con `VideoPlayer(svc.controller)` — el plugin permite varios
/// widgets compartiendo la misma textura GPU, así pintan el mismo frame en
/// ambos sitios sin duplicar el decoder.
///
/// **Sincronización con el audio**:
///   - Escucha `PlaybackController` y replica play/pause.
///   - Cada 1s mide el drift video↔audio: >400 ms corrige con seek duro;
///     120-400 ms con nudge de velocidad (±6%, converge suave sin tirar
///     el buffer del decoder); <120 ms el video corre a la velocidad base
///     del audio (incluye el setting de speed del usuario).
///   - Al cambiar de canción, el video viejo se descarta INMEDIATAMENTE
///     (la UI cae a la carátula) en vez de seguir mostrando frames viejos
///     mientras el nuevo resuelve URL + inicializa.
///   - El toggle del audio (video↔audio principal) está debounceado 300 ms:
///     si el usuario toggla rápido, solo aplicamos el último estado.
class MusicVideoPlayer extends ChangeNotifier {
  MusicVideoPlayer({
    required this.playback,
    required this.availability,
  }) {
    playback.addListener(_onPlaybackChanged);
    availability.addListener(_onAvailabilityChanged);
    // Seek explícito del scrubber → mover el video al instante. Sin esto,
    // arrastrar el slider con video activo movía solo el audio (muteado)
    // y el video se quedaba donde estaba; el sync timer NO corrige porque
    // hace early-return cuando el video provee el audio.
    _seekSub = playback.seekEvents.listen(_onSeekRequested);
    // Estado inicial — si ya hay canción cargada cuando se crea el service.
    _scheduleSync();
  }

  final PlaybackController playback;
  final VideoAvailabilityController availability;

  VideoPlayerController? _controller;
  VideoPlayerController? get controller => _controller;

  /// videoId actualmente cargado en `_controller`. Null = sin video.
  String? _loadedVideoId;
  /// videoId que QUEREMOS tener cargado. Si difiere de `_loadedVideoId`
  /// estamos en transición — el loop de `_runSwap` reintentará hasta cuadrar.
  String? _targetVideoId;
  bool _busy = false;
  Timer? _syncTimer;
  StreamSubscription<Duration>? _seekSub;

  /// Última velocidad aplicada al controller de video (base del audio o
  /// un nudge de corrección). Evita llamadas redundantes a
  /// setPlaybackSpeed en cada tick del sync timer.
  double? _videoSpeed;

  /// Debounce del routing audio. Si el usuario toggla rápido el botón
  /// "ver video", postponemos `_applyAudioRouting` hasta que pasen 300 ms
  /// sin más cambios. Sin esto, una ráfaga de seeks/volume/mute saturaba
  /// el decoder y provocaba buffer underrun + Lost connection to device.
  Timer? _routingDebounce;
  /// Lock para que dos `_applyAudioRouting` no se solapen (el seek async
  /// puede entrelazarse con un setVolume del siguiente toggle).
  bool _routingBusy = false;

  void _onPlaybackChanged() {
    _scheduleSync();
  }

  /// Mueve el video controller a [to] cuando el usuario hace seek desde el
  /// scrubber. Se ejecuta SIEMPRE que haya video cargado — tanto si el
  /// video provee el audio (entonces ES la fuente que oyes) como si solo
  /// es decorativo de fondo (para que la imagen siga al audio). Es
  /// independiente del sync timer, que solo corrige drift gradual.
  Future<void> _onSeekRequested(Duration to) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.seekTo(to);
    } catch (_) {}
  }

  void _onAvailabilityChanged() {
    // Si el target todavía no está cargado, intentamos `_runSwap`. Esto cubre
    // 2 casos:
    //   a) `ensureChecked` async acaba de poblar la URL para una canción
    //      sin video cargado todavía (_controller == null).
    //   b) Cambio de canción CON el toggle ya activo: el video anterior
    //      sigue en `_controller` pero el target apunta al nuevo videoId.
    //      Antes solo chequeábamos `_controller == null` y por eso el video
    //      viejo se quedaba reproduciendo indefinidamente.
    if (_targetVideoId != null && _loadedVideoId != _targetVideoId) {
      _runSwap();
    }
    // El toggle del cover dispara este listener — debounceamos para no
    // ejecutar 5 seeks si el usuario toggla 5 veces seguidas.
    _routingDebounce?.cancel();
    _routingDebounce = Timer(const Duration(milliseconds: 300), () {
      _applyAudioRouting(syncIfDrift: true);
    });
  }

  void _scheduleSync() {
    final song = playback.currentSong;
    final id = song?.streamingId;
    if (id != _targetVideoId) {
      _targetVideoId = id;
      _runSwap();
    }
    // Replicar play/pause aunque no haya cambio de canción.
    // (Posición se sincroniza solo en `_startSyncTimer` cada 3s + umbral
    // 800 ms — lo hacíamos antes con un delta>1500 en cada notify, pero
    // eso disparaba seeks falsos cuando el listener tardaba en correr.)
    _syncPlayState();
  }

  Future<void> _syncPlayState() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (playback.isPlaying && !c.value.isPlaying) {
        await c.play();
      } else if (!playback.isPlaying && c.value.isPlaying) {
        await c.pause();
      }
    } catch (_) {}
  }

  /// `true` si el audio sale del video player (porque el usuario activó el
  /// toggle "ver video en cover" Y el video está listo Y el stream del video
  /// trae pista de audio). En cualquier otro caso (incluido video solo como
  /// background sin toggle, o stream video-only), el audio sale del audio
  /// principal.
  ///
  /// Por qué chequear `hasAudio`: los `adaptiveFormats` de YouTube son
  /// video-only — si seleccionamos uno y muteamos el audio principal, queda
  /// silencio. Solo los formats COMBINADOS (mp4 itag 18/22) traen audio.
  ///
  /// Por qué solo cuando el toggle del cover está ON, no cuando hay video en
  /// bg: el bg es decorativo, el cover es la experiencia principal. Si el
  /// usuario tiene video solo en bg, NO quiere que su audio reemplace al
  /// audio principal. Solo cuando explícitamente activa el toggle del cover
  /// dice "quiero el video como contenido principal" → ahí enrutamos audio.
  bool get _audioGoesToVideo {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return false;
    if (!availability.showAsCover) return false;
    final id = _loadedVideoId;
    if (id == null) return false;
    return availability.hasAudioFor(id);
  }

  /// Aplica el routing de audio según `_audioGoesToVideo`.
  ///
  /// [syncIfDrift]: si `true` y vamos a video, hace seek SOLO si el video
  /// está desincronizado más de 800 ms respecto al audio principal. Si el
  /// drift es pequeño, dejamos al sync timer corregirlo gradualmente — un
  /// seek inmediato fuerza al decoder de video a tirar su buffer y rebufferar
  /// (lo que provoca el stuttering que el usuario reporta).
  ///
  /// Serializado con [_routingBusy]: si una llamada anterior aún corre, la
  /// nueva descarta — la siguiente notificación del listener volverá a
  /// dispararla con el estado correcto.
  Future<void> _applyAudioRouting({bool syncIfDrift = false}) async {
    if (_routingBusy) return;
    _routingBusy = true;
    try {
      final c = _controller;
      if (c == null || !c.value.isInitialized) {
        // Sin video listo: aseguramos audio principal sonando.
        playback.setMuted(false);
        return;
      }
      final toVideo = _audioGoesToVideo;
      try {
        if (toVideo) {
          if (syncIfDrift) {
            try {
              final vidPos = await c.position;
              if (vidPos != null) {
                final delta = (vidPos.inMilliseconds -
                        playback.position.inMilliseconds)
                    .abs();
                if (delta > 800) {
                  await c.seekTo(playback.position);
                }
              }
            } catch (_) {}
          }
          await c.setVolume(1.0);
          playback.setMuted(true);
        } else {
          await c.setVolume(0.0);
          playback.setMuted(false);
        }
      } catch (_) {}
    } finally {
      _routingBusy = false;
    }
  }

  Future<void> _runSwap() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_loadedVideoId != _targetVideoId) {
        final target = _targetVideoId;
        // Soltar el video viejo INMEDIATAMENTE al cambiar de canción.
        // Antes se quedaba montado y reproduciéndose en loop durante los
        // 2-4s que tardan resolver la URL + inicializar el nuevo → el
        // usuario veía frames del video anterior con el audio de la
        // canción nueva. Con el dispose temprano la UI cae a la carátula
        // al instante y el video nuevo aparece ya sincronizado. También
        // desmutea el audio principal de inmediato (si el video viejo
        // era la fuente de audio, la canción nueva sonaba tarde).
        if (_controller != null) {
          await _disposeController();
          _loadedVideoId = null;
          notifyListeners();
        }
        if (target == null) {
          _loadedVideoId = null;
          notifyListeners();
          continue;
        }
        // Si la disponibilidad aún no se verificó, salimos. El listener de
        // availability nos llamará otra vez cuando llegue el resultado.
        if (!availability.isChecked(target)) {
          // ignore: discarded_futures
          availability.ensureChecked(target);
          break;
        }
        final url = availability.urlFor(target);
        if (url == null || url.isEmpty) {
          await _disposeController();
          _loadedVideoId = target;
          notifyListeners();
          continue;
        }
        VideoPlayerController? next;
        try {
          next = VideoPlayerController.networkUrl(
            Uri.parse(url),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
          await next.initialize();
          await next.setLooping(true);
          await next.setVolume(0);
          // El video corre a la MISMA velocidad que el audio — sin esto,
          // con speed ≠ 1× el video derivaba sin parar y el sync timer
          // vivía corrigiendo con seeks (stutter constante).
          final baseSpeed = playback.currentSpeed;
          try {
            await next.setPlaybackSpeed(baseSpeed);
          } catch (_) {}
          _videoSpeed = baseSpeed;
          // Posicionarlo donde está el audio AHORA. Si el audio lleva 1:30,
          // arrancar el video desde 0 sería incomodísimo visualmente.
          try {
            await next.seekTo(playback.position);
          } catch (_) {}
          if (playback.isPlaying) {
            await next.play();
          }
          // Mientras initialize() corría, el target puede haber cambiado.
          if (_targetVideoId != target) {
            await next.dispose();
            continue;
          }
          _controller = next;
          _loadedVideoId = target;
          _startSyncTimer();
          // Aplicar routing: si el usuario tenía el toggle activo de la
          // canción anterior, el nuevo controller debe tomar audio.
          await _applyAudioRouting();
          notifyListeners();
        } catch (e) {
          devLog('MusicVideoPlayer load $target failed: $e');
          try {
            await next?.dispose();
          } catch (_) {}
          _loadedVideoId = target; // marca como "intentado" para no loopear
          notifyListeners();
        }
      }
    } finally {
      _busy = false;
    }
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    // Corrección en dos niveles, cada 1s:
    //   - Drift > 400 ms → seek duro (única forma de recuperar rápido).
    //   - Drift 120-400 ms → nudge de velocidad (±6%): el video converge
    //     suave en 2-5s SIN tirar el buffer del decoder. El esquema viejo
    //     (seek solo con drift > 800 ms cada 3s) dejaba el video hasta
    //     0.8s desfasado de forma permanente — visible en el lip-sync.
    //   - Drift < 120 ms → velocidad base (la del audio). Esto también
    //     mantiene el video a la velocidad del setting speed del usuario.
    _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      if (!playback.isPlaying) return;
      // Si el audio del video manda, no tiene sentido sincronizar contra
      // el audio principal (que está muteado y avanza por su cuenta).
      if (_audioGoesToVideo) return;
      try {
        final vidPos = await c.position;
        if (vidPos == null) return;
        final base = playback.currentSpeed;
        final driftMs =
            vidPos.inMilliseconds - playback.position.inMilliseconds;
        final absDrift = driftMs.abs();
        var desiredSpeed = base;
        if (absDrift > 400) {
          await c.seekTo(playback.position);
        } else if (absDrift > 120) {
          // Video adelantado → frenarlo un poco; atrasado → acelerarlo.
          desiredSpeed = base * (driftMs > 0 ? 0.94 : 1.06);
        }
        if (_videoSpeed != desiredSpeed) {
          await c.setPlaybackSpeed(desiredSpeed);
          _videoSpeed = desiredSpeed;
        }
      } catch (_) {}
    });
  }

  Future<void> _disposeController() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    _videoSpeed = null;
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        await c.dispose();
      } catch (_) {}
    }
    // Sin video activo, el audio principal debe sonar siempre. Si veníamos
    // muteados (toggle estaba ON con video anterior), restauramos volumen.
    playback.setMuted(false);
  }

  @override
  void dispose() {
    playback.removeListener(_onPlaybackChanged);
    availability.removeListener(_onAvailabilityChanged);
    // ignore: discarded_futures
    _seekSub?.cancel();
    _routingDebounce?.cancel();
    _syncTimer?.cancel();
    _controller?.dispose();
    _controller = null;
    // Garantía: si la app se cierra con el toggle activo, no dejar el audio
    // principal muteado para la próxima sesión.
    try {
      playback.setMuted(false);
    } catch (_) {}
    super.dispose();
  }
}
