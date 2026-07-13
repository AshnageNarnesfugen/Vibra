import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../core/dev_log.dart';

/// Wrapper delgado sobre `just_audio` para poder mockearlo y centralizar
/// la inicialización de `audio_session`.
///
/// Construye el `AudioPlayer` con un `AudioPipeline` que incluye un
/// equalizer y un loudness enhancer (preamp) en Android — los exponemos
/// para que `EqualizerController` los pueda manipular. En otras plataformas
/// no agregamos effects (just_audio los ignora silenciosamente).
class AudioService {
  AudioService._() {
    final isAndroid = !kIsWeb && Platform.isAndroid;
    // Los effects son singleton de proceso — los creamos UNA vez y los
    // referenciamos desde el EqualizerController. Sin esto, cualquier
    // reset del player perdería los parámetros del EQ.
    if (isAndroid) {
      equalizer = AndroidEqualizer();
      loudnessEnhancer = AndroidLoudnessEnhancer();
      player = AudioPlayer(
        audioPipeline: AudioPipeline(
          androidAudioEffects: [
            equalizer!,
            loudnessEnhancer!,
          ],
        ),
      );
    } else {
      equalizer = null;
      loudnessEnhancer = null;
      player = AudioPlayer();
    }
  }
  static final AudioService instance = AudioService._();

  late final AudioPlayer player;

  /// EQ del sistema Android (5-10 bandas según OEM). Null en plataformas
  /// non-Android. El número y frecuencia de bandas la dicta la implementación
  /// nativa — exponemos lo que da el SO sin reescalar.
  late final AndroidEqualizer? equalizer;

  /// Preamp / loudness enhancer (-15 dB a +15 dB efectivo en práctica).
  /// Null en plataformas non-Android.
  late final AndroidLoudnessEnhancer? loudnessEnhancer;

  bool _initialized = false;

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      devLog('AudioSession init error: $e');
    }
  }

  Future<void> setUri(String uri) async {
    if (uri.startsWith('http') || uri.startsWith('https')) {
      await player.setAudioSource(AudioSource.uri(Uri.parse(uri)));
    } else if (uri.startsWith('content://')) {
      await player.setAudioSource(AudioSource.uri(Uri.parse(uri)));
    } else {
      // Asumimos que es un path local.
      await player.setAudioSource(AudioSource.file(uri));
    }
  }

  Stream<Duration> get position => player.positionStream;
  Stream<Duration?> get totalDuration => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  // Stream para detectar errores de runtime del player (timeouts de red,
  // sockets cerrados, codecs no soportados, etc.). just_audio los entrega
  // por `playbackEventStream` como `onError` del listener — el caller
  // debe pasar `onError` cuando se suscribe.
  Stream<PlaybackEvent> get playbackEventStream => player.playbackEventStream;
}
