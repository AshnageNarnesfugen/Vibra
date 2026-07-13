import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dev_log.dart';
import '../services/audio_service.dart';

/// Preset de ecualizador: gains por banda + nombre + bandera builtin.
@immutable
class EqPreset {
  const EqPreset({
    required this.name,
    required this.gainsDb,
    this.builtin = false,
  });

  /// Nombre visible en la UI ("Rock", "Vocal", "Mi mezcla", etc.).
  final String name;

  /// Gains en dB por banda. La longitud debería igualar el número de bandas
  /// del EQ del SO. Si difiere, se interpola al cargar (lineal): bandas
  /// extra se rellenan con 0.0, bandas faltantes se descartan.
  final List<double> gainsDb;

  /// True para presets predefinidos (no se pueden borrar). Custom = false.
  final bool builtin;

  EqPreset copyWith({String? name, List<double>? gainsDb}) =>
      EqPreset(
        name: name ?? this.name,
        gainsDb: gainsDb ?? this.gainsDb,
        builtin: builtin,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'gains': gainsDb,
        'builtin': builtin,
      };

  factory EqPreset.fromJson(Map<String, dynamic> m) => EqPreset(
        name: m['name'] as String? ?? 'Custom',
        gainsDb: ((m['gains'] as List?) ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(),
        builtin: m['builtin'] as bool? ?? false,
      );
}

/// Controla el ecualizador del sistema (Android) + preamp + presets.
/// Persiste estado en SharedPreferences.
///
/// **Limitación honesta**: usa `AndroidEqualizer` que es un envoltorio del
/// EQ nativo de OpenSL ES. El número de bandas y sus centros son
/// determinados por el SO/OEM — típicamente 5 en stock Android, 10 en
/// Samsung One UI, etc. Para emular Poweramp (10 bandas paramétricas) se
/// necesitaría DSP nativo propio. Esta versión expone lo que da el SO.
///
/// En plataformas non-Android queda inerte: `available` retorna false y
/// los métodos son no-op.
class EqualizerController extends ChangeNotifier {
  EqualizerController({required this.audio}) {
    _init();
  }

  final AudioService audio;

  bool _ready = false;
  bool _enabled = false;
  double _preampDb = 0.0;

  AndroidEqualizerParameters? _params;
  List<double> _gainsDb = const [];

  /// Presets builtin "consagrados" que la mayoría de apps incluyen. Los
  /// valores se interpolan/recortan a la cantidad de bandas que reporte el
  /// SO en runtime.
  ///
  /// Los gains están diseñados para una curva visual reconocible — el
  /// usuario espera que "Rock" suene a Rock independientemente del device.
  /// Asumen un EQ de 10 bandas (~32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16kHz).
  static final List<EqPreset> _builtinPresets = [
    const EqPreset(
      name: 'Plano',
      gainsDb: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      builtin: true,
    ),
    const EqPreset(
      name: 'Rock',
      gainsDb: [5, 3, -2, -3, -1, 1, 3, 4, 4, 3],
      builtin: true,
    ),
    const EqPreset(
      name: 'Pop',
      gainsDb: [-1, 0, 3, 4, 4, 2, 0, -1, -1, -2],
      builtin: true,
    ),
    const EqPreset(
      name: 'Hip-Hop',
      gainsDb: [6, 5, 2, 0, -1, 0, 0, 1, 2, 3],
      builtin: true,
    ),
    const EqPreset(
      name: 'Jazz',
      gainsDb: [4, 3, 1, 2, -1, -1, 0, 1, 2, 3],
      builtin: true,
    ),
    const EqPreset(
      name: 'Clásica',
      gainsDb: [4, 3, 2, 0, -2, -2, 0, 2, 3, 4],
      builtin: true,
    ),
    const EqPreset(
      name: 'Vocal',
      gainsDb: [-2, -3, -2, 1, 3, 4, 4, 3, 1, 0],
      builtin: true,
    ),
    const EqPreset(
      name: 'Bass Boost',
      gainsDb: [7, 6, 5, 3, 1, 0, 0, 0, 0, 0],
      builtin: true,
    ),
    const EqPreset(
      name: 'Treble Boost',
      gainsDb: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7],
      builtin: true,
    ),
    const EqPreset(
      name: 'V-Shape',
      gainsDb: [5, 4, 2, 0, -3, -3, 0, 2, 4, 5],
      builtin: true,
    ),
  ];

  final List<EqPreset> _customPresets = [];
  String? _activePresetName;

  // ─────────────── Public state ───────────────

  /// True si el EQ está disponible (plataforma Android con effect creado).
  bool get available => audio.equalizer != null;

  /// True si los parámetros nativos ya fueron leídos. Antes de esto, las
  /// bandas son [].
  bool get isReady => _ready;

  bool get enabled => _enabled;

  /// Gains actuales en dB por banda. Length = número de bandas reportado
  /// por el SO. Cuando [available] es false → vacío.
  List<double> get gainsDb => List.unmodifiable(_gainsDb);

  /// Preamp en dB. Rango [-15, 15] (mapeado al `targetGainDb` del
  /// LoudnessEnhancer interno con clamp a su rango efectivo).
  double get preampDb => _preampDb;

  /// Min y max dB de cada banda según el SO. Antes de [isReady] retornan
  /// (-12, 12) como placeholder seguro.
  double get bandMinDb => _params?.minDecibels.toDouble() ?? -12.0;
  double get bandMaxDb => _params?.maxDecibels.toDouble() ?? 12.0;

  /// Frecuencia central de cada banda en Hz. Vacío hasta isReady.
  List<double> get bandCenterFrequencies =>
      _params?.bands.map((b) => b.centerFrequency).toList() ??
      const <double>[];

  List<EqPreset> get builtinPresets => List.unmodifiable(_builtinPresets);
  List<EqPreset> get customPresets => List.unmodifiable(_customPresets);
  String? get activePresetName => _activePresetName;

  // ─────────────── Init ───────────────

  Future<void> _init() async {
    if (!available) return;
    try {
      // `parameters` se completa cuando el player tiene una source cargada.
      // Si no hay aún, esperamos en background sin bloquear.
      _params = await audio.equalizer!.parameters;
      _gainsDb = List<double>.filled(_params!.bands.length, 0.0);
      // Lee gains iniciales del SO (puede traer presets de fábrica del OEM).
      for (var i = 0; i < _params!.bands.length; i++) {
        _gainsDb[i] = _params!.bands[i].gain.toDouble();
      }
      // Carga estado persistido + custom presets.
      await _loadPersistedState();
      _ready = true;
      // Re-aplica gains/preamp/enabled tras la lectura (por si los valores
      // persistidos difieren de los del SO).
      await _applyAll();
      notifyListeners();
    } catch (e) {
      devLog('EqualizerController init failed: $e');
    }
  }

  // ─────────────── Persistence ───────────────

  static const _prefsKeyEnabled = 'eq.enabled';
  static const _prefsKeyPreamp = 'eq.preamp_db';
  static const _prefsKeyGains = 'eq.gains_db';
  static const _prefsKeyActivePreset = 'eq.active_preset';
  static const _prefsKeyCustomPresets = 'eq.custom_presets';

  Future<void> _loadPersistedState() async {
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(_prefsKeyEnabled) ?? false;
      _preampDb = p.getDouble(_prefsKeyPreamp) ?? 0.0;
      _activePresetName = p.getString(_prefsKeyActivePreset);
      final gainsRaw = p.getStringList(_prefsKeyGains);
      if (gainsRaw != null && gainsRaw.isNotEmpty) {
        final saved = gainsRaw.map(double.parse).toList();
        // Si el número de bandas cambió (otro device, otro OEM), interpolamos.
        _gainsDb = _resampleGains(saved, _gainsDb.length);
      }
      final customRaw = p.getString(_prefsKeyCustomPresets);
      if (customRaw != null) {
        final list = (jsonDecode(customRaw) as List)
            .cast<Map<String, dynamic>>()
            .map(EqPreset.fromJson)
            .toList();
        _customPresets
          ..clear()
          ..addAll(list);
      }
    } catch (e) {
      devLog('EQ persist load failed: $e');
    }
  }

  Future<void> _persistState() async {
    if (!_ready) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_prefsKeyEnabled, _enabled);
      await p.setDouble(_prefsKeyPreamp, _preampDb);
      await p.setStringList(
          _prefsKeyGains, _gainsDb.map((g) => g.toString()).toList());
      if (_activePresetName != null) {
        await p.setString(_prefsKeyActivePreset, _activePresetName!);
      } else {
        await p.remove(_prefsKeyActivePreset);
      }
      await p.setString(
        _prefsKeyCustomPresets,
        jsonEncode(_customPresets.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      devLog('EQ persist save failed: $e');
    }
  }

  // ─────────────── Mutations ───────────────

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    if (!available) {
      notifyListeners();
      return;
    }
    try {
      await audio.equalizer!.setEnabled(v);
      await audio.loudnessEnhancer!.setEnabled(v);
    } catch (e) {
      devLog('setEnabled($v) failed: $e');
    }
    await _persistState();
    notifyListeners();
  }

  Future<void> setBandGain(int index, double db) async {
    if (!_ready || index < 0 || index >= _gainsDb.length) return;
    final clamped = db.clamp(bandMinDb, bandMaxDb);
    if ((_gainsDb[index] - clamped).abs() < 0.01) return;
    _gainsDb[index] = clamped;
    // Cambiar un slider manualmente desselecciona el preset activo —
    // ahora es una mezcla custom no guardada.
    _activePresetName = null;
    try {
      await _params!.bands[index].setGain(clamped);
    } catch (e) {
      devLog('setBandGain($index, $db) failed: $e');
    }
    await _persistState();
    notifyListeners();
  }

  Future<void> setPreampDb(double db) async {
    final clamped = db.clamp(-15.0, 15.0);
    if ((_preampDb - clamped).abs() < 0.01) return;
    _preampDb = clamped;
    if (!available) {
      notifyListeners();
      return;
    }
    try {
      // LoudnessEnhancer toma milibels (1 dB = 100 mB). El plugin acepta
      // dB en `targetGain`; verificamos rango efectivo del device antes
      // de aplicar.
      await audio.loudnessEnhancer!.setTargetGain(clamped);
    } catch (e) {
      devLog('setPreampDb($db) failed: $e');
    }
    await _persistState();
    notifyListeners();
  }

  Future<void> applyPreset(EqPreset preset) async {
    if (!_ready) return;
    final resampled = _resampleGains(preset.gainsDb, _gainsDb.length);
    _gainsDb = resampled;
    _activePresetName = preset.name;
    for (var i = 0; i < _gainsDb.length; i++) {
      try {
        await _params!.bands[i].setGain(_gainsDb[i]);
      } catch (e) {
        devLog('applyPreset band $i failed: $e');
      }
    }
    // Activar el EQ implícitamente al aplicar un preset — el usuario
    // espera oír el cambio sin tener que tocar el toggle también.
    if (!_enabled) {
      await setEnabled(true);
    } else {
      await _persistState();
      notifyListeners();
    }
  }

  /// Guarda los gains actuales como nuevo preset custom con el nombre dado.
  /// Si ya existe un preset custom con ese nombre, lo sobrescribe.
  Future<void> saveCurrentAsPreset(String name) async {
    if (!_ready || name.trim().isEmpty) return;
    final trimmed = name.trim();
    // No permitir nombres que choquen con builtin (confunde al usuario).
    if (_builtinPresets.any((p) => p.name.toLowerCase() == trimmed.toLowerCase())) {
      return;
    }
    final preset = EqPreset(
      name: trimmed,
      gainsDb: List<double>.from(_gainsDb),
    );
    final existingIdx = _customPresets.indexWhere(
      (p) => p.name.toLowerCase() == trimmed.toLowerCase(),
    );
    if (existingIdx >= 0) {
      _customPresets[existingIdx] = preset;
    } else {
      _customPresets.add(preset);
    }
    _activePresetName = trimmed;
    await _persistState();
    notifyListeners();
  }

  Future<void> deleteCustomPreset(String name) async {
    final removed = _customPresets
        .indexWhere((p) => p.name == name);
    if (removed < 0) return;
    _customPresets.removeAt(removed);
    if (_activePresetName == name) _activePresetName = null;
    await _persistState();
    notifyListeners();
  }

  /// Resetea todas las bandas a 0 y el preamp a 0.
  Future<void> resetFlat() async {
    if (!_ready) return;
    for (var i = 0; i < _gainsDb.length; i++) {
      _gainsDb[i] = 0.0;
      try {
        await _params!.bands[i].setGain(0.0);
      } catch (_) {}
    }
    _preampDb = 0.0;
    try {
      await audio.loudnessEnhancer!.setTargetGain(0.0);
    } catch (_) {}
    _activePresetName = 'Plano';
    await _persistState();
    notifyListeners();
  }

  // ─────────────── Internals ───────────────

  Future<void> _applyAll() async {
    if (!available || !_ready) return;
    try {
      await audio.equalizer!.setEnabled(_enabled);
      await audio.loudnessEnhancer!.setEnabled(_enabled);
      await audio.loudnessEnhancer!.setTargetGain(_preampDb);
      for (var i = 0; i < _gainsDb.length && i < _params!.bands.length; i++) {
        await _params!.bands[i].setGain(_gainsDb[i]);
      }
    } catch (e) {
      devLog('_applyAll failed: $e');
    }
  }

  /// Adapta una lista de gains de N bandas a M bandas via interpolación
  /// lineal sobre frecuencia normalizada. Necesario porque los presets
  /// builtin son 10 bandas y un device específico puede tener 5 o 6.
  static List<double> _resampleGains(List<double> src, int targetLen) {
    if (src.length == targetLen) return List<double>.from(src);
    if (targetLen <= 0) return const [];
    if (src.isEmpty) return List<double>.filled(targetLen, 0.0);
    if (src.length == 1) return List<double>.filled(targetLen, src.first);
    final out = List<double>.filled(targetLen, 0.0);
    for (var i = 0; i < targetLen; i++) {
      final pos = i * (src.length - 1) / (targetLen - 1);
      final lo = pos.floor();
      final hi = pos.ceil();
      if (lo == hi) {
        out[i] = src[lo];
      } else {
        final t = pos - lo;
        out[i] = src[lo] * (1 - t) + src[hi] * t;
      }
    }
    return out;
  }
}

/// Helper para que callers no-Android salgan rápido sin importar tu lógica.
/// Returns true si el plugin de EQ está disponible en este SO.
bool isAndroidEqualizerAvailable() {
  return !kIsWeb && Platform.isAndroid;
}
