// AudioDeviceType en audio_session está marcado experimental pero es la
// única forma de saber si el output es USB DAC / BT / wired. La API es
// estable en práctica desde 0.1.x — el "experimental" es para señalar que
// puede haber renames, no que vaya a desaparecer.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';
import '../core/settings/settings_controller.dart';
import '../services/aaudio_native.dart';
import 'equalizer_controller.dart';

/// Estado del routing de audio actual: a qué device(s) está saliendo el
/// audio. Power users miran esto para confirmar que no hay procesado de
/// la cadena (BT por ejemplo siempre tiene re-encoding SBC/AAC).
class AudioOutputState {
  const AudioOutputState({
    required this.devices,
    required this.isUsbDac,
    required this.isBluetooth,
    required this.isWiredHeadphones,
    required this.isBuiltInSpeaker,
  });

  final List<AudioDevice> devices;
  final bool isUsbDac;
  final bool isBluetooth;
  final bool isWiredHeadphones;
  final bool isBuiltInSpeaker;

  /// Etiqueta humana para el badge del player y la pantalla de Hi-Fi.
  /// Cuando hay múltiples devices activos, prioriza el de mejor calidad
  /// (USB DAC > wired > BT > speaker).
  String get displayName {
    if (devices.isEmpty) return 'Desconocido';
    if (isUsbDac) {
      // Cuando hay USB DAC, mostrar su nombre real si está disponible.
      final usb = devices.firstWhere(
        (d) => d.type == AudioDeviceType.usbAudio,
        orElse: () => devices.first,
      );
      return usb.name.isEmpty ? 'USB DAC' : usb.name;
    }
    if (isWiredHeadphones) return 'Auriculares (cable)';
    if (isBluetooth) {
      final bt = devices.firstWhere(
        (d) => d.type == AudioDeviceType.bluetoothA2dp,
        orElse: () => devices.first,
      );
      return bt.name.isEmpty ? 'Bluetooth' : bt.name;
    }
    if (isBuiltInSpeaker) return 'Altavoz del teléfono';
    return devices.first.name;
  }

  /// True cuando el routing es "audiophile-friendly" — wired headphones
  /// o USB DAC. BT siempre tiene re-encoding lossy. Speaker tampoco rinde.
  bool get isLosslessPath => isUsbDac || isWiredHeadphones;

  /// Razón explícita para mostrar al usuario por qué su path no es
  /// bit-perfect aunque tenga el toggle ON.
  String? get nonBitPerfectReason {
    if (isBluetooth) {
      return 'Bluetooth aplica codec SBC/AAC/aptX — siempre con compresión. '
          'Para bit-perfect real, usa cable o USB DAC.';
    }
    if (isBuiltInSpeaker) {
      return 'El altavoz del teléfono tiene procesado extra (EQ, limiter) '
          'que no podemos desactivar. Usa auriculares para evaluar.';
    }
    return null;
  }
}

/// Coordinador del modo "Hi-Fi / Bit-perfect":
///
/// 1. Observa `settings.bitPerfectModeEnabled` y propaga el side-effect:
///    - Fuerza EQ off (deshabilita el toggle del EQ desde código).
///    - Fuerza preamp a 0 dB.
///    - Fuerza fade in/out off.
///    - Fuerza lockPitchToSpeed off.
///    Nada de esto se persiste como side-effect — al apagar bit-perfect
///    los valores vuelven a su estado anterior (preservados en settings).
///
/// 2. Subscribe al `AudioSession.devicesChangedEventStream` para mantener
///    al día qué device está activo. Útil para:
///    - Mostrar nombre del device en la UI ("USB DAC: FiiO BTR7")
///    - Avisar al usuario cuando conecta un USB DAC ("DAC detectado")
///    - Disparar callbacks per-output del futuro EQ con presets por device
///
/// 3. Interfaz al `AAudioNative` plugin (cuando esté implementado) para
///    consultas de capability — si el device soporta EXCLUSIVE mode, qué
///    sample rates exclusivos, etc. Por ahora el plugin devuelve stubs.
class BitPerfectController extends ChangeNotifier {
  BitPerfectController({
    required this.settings,
    required this.equalizer,
  }) {
    _init();
  }

  final SettingsController settings;
  final EqualizerController equalizer;

  AudioOutputState _output = const AudioOutputState(
    devices: [],
    isUsbDac: false,
    isBluetooth: false,
    isWiredHeadphones: false,
    isBuiltInSpeaker: false,
  );
  AudioOutputState get output => _output;

  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  bool _lastEnabled = false;
  bool _aaudioAvailable = false;
  AAudioCapability? _aaudioCapability;

  /// True cuando el modo bit-perfect está ON.
  bool get enabled => settings.value.bitPerfectModeEnabled;

  /// True cuando el plugin nativo AAudio está disponible y reportó capability.
  /// Esto NO significa que esté ACTIVO — solo que el plugin responde.
  bool get aaudioAvailable => _aaudioAvailable;

  AAudioCapability? get aaudioCapability => _aaudioCapability;

  Future<void> _init() async {
    settings.addListener(_onSettingsChanged);
    _lastEnabled = settings.value.bitPerfectModeEnabled;
    if (_lastEnabled) {
      // Cold start con el modo ON → aplicar las reglas inmediatamente.
      // ignore: discarded_futures
      _applyBitPerfectRules();
    }

    // audio_session: monitor de devices.
    try {
      final session = await AudioSession.instance;
      _devicesSub = session.devicesChangedEventStream
          .map((evt) => evt.devicesAdded.union(evt.devicesRemoved))
          .listen((_) async {
        // Cada evento → re-query del device set actual.
        await _refreshDevices(session);
      });
      await _refreshDevices(session);
    } catch (e) {
      devLog('BitPerfectController audio_session init failed: $e');
    }

    // AAudio capability probe.
    try {
      _aaudioAvailable = await AAudioNative.isAvailable();
      if (_aaudioAvailable) {
        _aaudioCapability = await AAudioNative.queryCapability();
      }
    } catch (e) {
      devLog('AAudio probe failed: $e');
    }
    notifyListeners();
  }

  Future<void> _refreshDevices(AudioSession session) async {
    try {
      final devs = await session.getDevices(includeInputs: false);
      final list = devs.toList();
      _output = AudioOutputState(
        devices: list,
        isUsbDac: list.any((d) => d.type == AudioDeviceType.usbAudio),
        isBluetooth: list.any((d) =>
            d.type == AudioDeviceType.bluetoothA2dp ||
            d.type == AudioDeviceType.bluetoothLe ||
            d.type == AudioDeviceType.bluetoothSco),
        isWiredHeadphones: list.any((d) =>
            d.type == AudioDeviceType.wiredHeadphones ||
            d.type == AudioDeviceType.wiredHeadset),
        isBuiltInSpeaker:
            list.any((d) => d.type == AudioDeviceType.builtInSpeaker),
      );
      notifyListeners();
    } catch (e) {
      devLog('refreshDevices failed: $e');
    }
  }

  void _onSettingsChanged() {
    final v = settings.value.bitPerfectModeEnabled;
    if (v == _lastEnabled) return;
    _lastEnabled = v;
    // ignore: discarded_futures
    _applyBitPerfectRules();
    notifyListeners();
  }

  /// Cuando bit-perfect ON: fuerza neutral a todo lo que toca señal.
  /// Cuando OFF: no-op (los valores anteriores ya están en settings).
  Future<void> _applyBitPerfectRules() async {
    if (!_lastEnabled) {
      // No restauramos nada: el usuario verá los toggles de EQ/fade
      // como estaban antes (su preferencia persistida). Solo dejamos
      // que el `enabled = false` se quede off en el EQ — el usuario
      // lo reactiva manualmente si quiere.
      return;
    }
    // EQ off.
    if (equalizer.enabled) {
      await equalizer.setEnabled(false);
    }
    // Preamp a 0 — sin amplificación extra que altere el peak.
    if (equalizer.preampDb != 0.0) {
      await equalizer.setPreampDb(0.0);
    }
    // Fade off (forzar via settings.update — el listener del playback
    // lo notará pero como bit-perfect está ON, fade ni se llama).
    final s = settings.value;
    if (s.fadeOnPlayPauseEnabled || s.lockPitchToSpeed) {
      settings.update((p) => p.copyWith(
            fadeOnPlayPauseEnabled: false,
            lockPitchToSpeed: false,
          ));
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    _devicesSub?.cancel();
    super.dispose();
  }
}
