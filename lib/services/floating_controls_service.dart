import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/theme/palette_signal.dart';
import '../providers/playback_controller.dart';

/// Wrapper Flutter del foreground service nativo `FloatingControlsService`
/// (Kotlin). El service muestra un mini reproductor flotante sobre el
/// sistema cuando la app va a background — estilo Dynamic Island.
///
/// Lifecycle:
///   1. `setEnabled(true)`: pide permiso de overlay si no lo tiene
///      (abre Settings), luego arranca el service.
///   2. Listener interno a `playback` y `palette` → push de cambios al
///      nativo via `update()`.
///   3. `setEnabled(false)` o app destroy: para el service.
///
/// Solo Android. En iOS/desktop el toggle queda no-op (las plataformas
/// no permiten overlay windows de apps de terceros).
class FloatingControlsService extends ChangeNotifier {
  FloatingControlsService({
    required PlaybackController playback,
    required PaletteSignal palette,
  })  : _playback = playback,
        _palette = palette {
    _channel.setMethodCallHandler(_onNativeCall);
    _playback.addListener(_onPlaybackChanged);
    _palette.addListener(_onPaletteChanged);
    // Gate de lifecycle: el overlay solo tiene sentido cuando la app
    // NO está visible. Antes usábamos los callbacks individuales onPause/
    // onHide/onResume — pero en Android el firing de cada uno depende del
    // OEM (Samsung dispara hide+pause, Pixel solo paused, MIUI a veces ni
    // paused). `onStateChange` recibe TODOS los transitions con el state
    // crudo, así que no perdemos nunca el cambio.
    //
    // Reglas: SOLO `resumed` = foreground. Cualquier otro estado (inactive,
    // paused, hidden, detached) cuenta como background y dispara el
    // overlay. `inactive` también dispara — es lo que pasa cuando bajás
    // la notification shade — pero el alternativa sería perder el caso
    // del usuario que aprieta home en algunos devices que solo emiten
    // inactive sin paused antes de que la activity muera.
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final fg = state == AppLifecycleState.resumed;
        debugPrint('[FLOAT] lifecycle=$state → fg=$fg '
            '(enabled=$_enabled, prevFg=$_appInForeground)');
        _onAppForeground(fg);
      },
    );
  }

  static const _channel = MethodChannel('vibra/floating');

  final PlaybackController _playback;
  final PaletteSignal _palette;

  bool _enabled = false;
  bool get enabled => _enabled;

  String? _lastTitle;
  String? _lastArtist;
  String? _lastCoverHash;
  bool _lastPlaying = false;
  int _lastPaletteArgb = 0xFF18181E;

  AppLifecycleListener? _lifecycle;
  bool _appInForeground = true;

  void _onAppForeground(bool inForeground) {
    if (_appInForeground == inForeground) {
      debugPrint('[FLOAT] _onAppForeground($inForeground): no-op (same state)');
      return;
    }
    _appInForeground = inForeground;
    if (!_enabled) {
      debugPrint('[FLOAT] _onAppForeground($inForeground): toggle is OFF, '
          'skipping overlay action');
      return;
    }
    // Cuando la app va a foreground escondemos el pill; cuando vuelve a
    // background, lo levantamos de nuevo. Usamos start/stop nativo para
    // que no quede el foreground service comiendo batería mientras el
    // usuario tiene la app abierta.
    if (inForeground) {
      debugPrint('[FLOAT] _onAppForeground(true): app foreground → stop overlay');
      // ignore: discarded_futures
      _channel.invokeMethod('stop').catchError((Object _) {});
    } else {
      debugPrint('[FLOAT] _onAppForeground(false): app background → '
          'start overlay');
      // El service nativo arrancó nuevo → su bitmap es el placeholder.
      // Reset del hash para que el siguiente push reenvíe el cover real.
      _lastCoverHash = null;
      // ignore: discarded_futures
      _push(isStart: true);
    }
  }

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  Future<bool> hasOverlayPermission() async {
    if (!isSupported) return false;
    try {
      final v = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Abre los ajustes de sistema "Display over other apps" para que el
  /// usuario conceda el permiso. No hay forma de prompt in-app — Android
  /// fuerza al usuario a viajar a ajustes para esto.
  Future<void> requestOverlayPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (_) {}
  }

  /// Test mode: fuerza un start con datos placeholder (sin esperar
  /// canción ni paleta). Si el overlay aparece tras este botón, el
  /// pipeline nativo funciona y el problema está en el wiring de
  /// playback/palette. Si NO aparece, hay que mirar logcat por errores
  /// de permiso/foreground service. Auto-stop a los 8s para no dejar
  /// el widget colgando.
  Future<void> testFlash() async {
    if (!isSupported) return;
    final ok = await hasOverlayPermission();
    if (!ok) {
      await requestOverlayPermission();
      return;
    }
    debugPrint('[FLOAT] testFlash: starting overlay for 8s');
    try {
      await _channel.invokeMethod('start', {
        'title': '✓ Test Vibra',
        'artist': 'Si ves esto, el overlay funciona',
        'coverB64': null,
        'paletteColor': 0xFFFF3B30, // rojo Vibra (alta visibilidad)
        'isPlaying': false,
      });
      // Auto-stop 8s después si el usuario NO tenía el toggle ON.
      // Si el toggle estaba ON, el siguiente _push lo va a refrescar
      // con el contenido real.
      if (!_enabled) {
        await Future<void>.delayed(const Duration(seconds: 8));
        // RE-CHECK tras el delay: si el usuario activó el toggle real
        // DURANTE los 8s del test, el stop incondicional mataría el
        // overlay legítimo recién montado. Solo paramos si sigue OFF.
        if (!_enabled) {
          await _channel.invokeMethod('stop');
          debugPrint('[FLOAT] testFlash: auto-stopped');
        } else {
          debugPrint('[FLOAT] testFlash: skip auto-stop, toggle is now ON');
        }
      }
    } catch (e) {
      debugPrint('[FLOAT] testFlash failed: $e');
    }
  }

  /// Activa/desactiva el mini widget flotante. En activación verifica
  /// permiso — si no lo hay, dispara la ventana de ajustes y queda en
  /// estado "pendiente" (el usuario tiene que volver al toggle después
  /// de conceder).
  Future<bool> setEnabled(bool v) async {
    if (!isSupported) {
      debugPrint('[FLOAT] setEnabled($v): not supported on this platform');
      return false;
    }
    if (v == _enabled) {
      debugPrint('[FLOAT] setEnabled($v): already in that state');
      return _enabled;
    }
    if (v) {
      final ok = await hasOverlayPermission();
      debugPrint('[FLOAT] setEnabled(true): permission=$ok');
      if (!ok) {
        await requestOverlayPermission();
        return false;
      }
      _enabled = true;
      // Reset hash de cover: el lado nativo arranca con el placeholder
      // y nuestra dedupe-por-hash impedía re-enviar el cover si la
      // canción no había cambiado desde la última sesión (el hash en RAM
      // sobrevive al stop/start del service nativo pero el bitmap no).
      _lastCoverHash = null;
      // Si la app está en foreground, dejamos el toggle ON pero NO
      // arrancamos el overlay todavía — el lifecycle listener lo va a
      // levantar cuando el usuario salga de la app. Esto evita que el
      // pill compita por las zonas de tap con la UI normal.
      if (!_appInForeground) {
        await _push(isStart: true);
      } else {
        debugPrint('[FLOAT] setEnabled(true): app in foreground, '
            'deferring overlay start until backgrounded');
      }
    } else {
      _enabled = false;
      try {
        await _channel.invokeMethod('stop');
        debugPrint('[FLOAT] stop sent');
      } catch (e) {
        debugPrint('[FLOAT] stop failed: $e');
      }
    }
    notifyListeners();
    return _enabled;
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onTogglePlayPause':
        _playback.togglePlayPause();
        break;
    }
    return null;
  }

  void _onPlaybackChanged() {
    if (!_enabled) return;
    final song = _playback.currentSong;
    final title = song?.title ?? '';
    final artist = song?.artist ?? '';
    final playing = _playback.isPlaying;
    if (title == _lastTitle &&
        artist == _lastArtist &&
        playing == _lastPlaying) {
      return;
    }
    // ignore: discarded_futures
    _push();
  }

  void _onPaletteChanged() {
    if (!_enabled) return;
    final p = _palette.palette;
    if (p == null) return;
    final argb = _toArgb(p.dominant);
    if (argb == _lastPaletteArgb) return;
    // ignore: discarded_futures
    _push();
  }

  Future<void> _push({bool isStart = false}) async {
    final song = _playback.currentSong;
    final title = song?.title ?? '';
    final artist = song?.artist ?? '';
    final playing = _playback.isPlaying;
    final paletteArgb = _toArgb(
      _palette.palette?.dominant ?? const Color(0xFF18181E),
    );

    // Cover: prefer inline bytes (local songs) → fallback URL fetch.
    String? coverB64;
    final bytes = _palette.artworkBytes;
    if (bytes != null) {
      // Hash superficial para dedupe de envíos de la misma cover.
      final hash = '${bytes.length}-${bytes.first}-${bytes.last}';
      if (hash != _lastCoverHash) {
        coverB64 = base64Encode(_downscale(bytes, 128));
        _lastCoverHash = hash;
      }
    }

    _lastTitle = title;
    _lastArtist = artist;
    _lastPlaying = playing;
    _lastPaletteArgb = paletteArgb;

    try {
      final method = isStart ? 'start' : 'update';
      debugPrint('[FLOAT] invoking $method '
          'title="${title.isEmpty ? "(empty)" : title}" '
          'artist="${artist.isEmpty ? "(empty)" : artist}" '
          'cover=${coverB64 != null ? "${coverB64.length}b" : "null"} '
          'paletteColor=0x${paletteArgb.toRadixString(16)} '
          'playing=$playing');
      await _channel.invokeMethod(method, {
        'title': title,
        'artist': artist,
        'coverB64': coverB64,
        'paletteColor': paletteArgb,
        'isPlaying': playing,
      });
      debugPrint('[FLOAT] $method completed OK');
    } catch (e) {
      debugPrint('[FLOAT] push failed: $e');
    }
  }

  /// Compress de bytes de cover a ~128px de lado para no enviar 1MB de
  /// base64 al canal cada cambio. Si el codec del platform no decodifica
  /// (HEIC/AVIF), devuelve los bytes originales — el lado nativo igual
  /// los intenta decodificar y si falla solo no muestra cover.
  Uint8List _downscale(Uint8List src, int targetPx) {
    // En esta primera iteración no recomprimimos — el lado nativo hace
    // BitmapFactory.decodeByteArray que internamente respeta inSampleSize.
    // Si el cover excede ~256KB, mejor truncar a un hash placeholder en
    // un futuro PR. Por ahora pasamos el original.
    return src;
  }

  int _toArgb(Color c) {
    return ((c.a * 255).round() << 24) |
        ((c.r * 255).round() << 16) |
        ((c.g * 255).round() << 8) |
        (c.b * 255).round();
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
    _palette.removeListener(_onPaletteChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
    if (_enabled) {
      try {
        // ignore: discarded_futures
        _channel.invokeMethod('stop');
      } catch (_) {}
    }
    super.dispose();
  }
}

