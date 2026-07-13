import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_settings.dart';

/// Estado central de la personalización de la UI.
///
/// Toda mutación pasa por aquí: cambia [value] → notifica → la app entera
/// (envuelta en [InheritedNotifier]/`Provider`) se reconstruye con el nuevo
/// [UiSettings]. La persistencia es _eventual_: cada cambio dispara un guardado
/// que ignoramos (fire-and-forget) ya que la próxima escritura sobreescribe.
class SettingsController extends ChangeNotifier {
  SettingsController._(this._prefs, this._value);

  static const _kPrefsKey = 'ui_settings_v1';

  final SharedPreferences? _prefs;
  UiSettings _value;

  UiSettings get value => _value;

  static Future<SettingsController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    UiSettings initial;
    if (raw == null) {
      initial = const UiSettings();
    } else {
      try {
        initial = UiSettings.fromJson(raw);
      } catch (_) {
        initial = const UiSettings();
      }
    }
    return SettingsController._(prefs, initial);
  }

  /// Crea un controlador sin persistencia real (fallback para cuando SharedPreferences falla).
  static Future<SettingsController> loadFallback() async {
    // Intentamos obtener una instancia vacía si es posible.
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    return SettingsController._(prefs, const UiSettings());
  }

  void update(UiSettings Function(UiSettings) mutate) {
    final next = mutate(_value);
    if (identical(next, _value)) return;
    _value = next;
    notifyListeners();
    // ignore: discarded_futures
    _prefs?.setString(_kPrefsKey, _value.toJson());
  }

  void replace(UiSettings next) {
    _value = next;
    notifyListeners();
    // ignore: discarded_futures
    _prefs?.setString(_kPrefsKey, _value.toJson());
  }

  void resetDefaults() => replace(const UiSettings());
}
