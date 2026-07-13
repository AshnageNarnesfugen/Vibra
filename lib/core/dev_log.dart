import 'package:flutter/foundation.dart';

/// Log de desarrollo: imprime SOLO en debug builds. En release, la llamada
/// se tree-shakea por completo (la constante `kDebugMode` queda inlined a
/// `false` y el compilador elimina el if completo), incluyendo la
/// construcción del mensaje — sin esto, las interpolaciones de string
/// seguían ejecutándose en producción aunque `debugPrint` no escribiera
/// nada visible.
///
/// Uso:
///   ```dart
///   devLog('[YTM] auth refreshed');
///   ```
///
/// Para logs que SÍ deben verse en release (errores reales que debe
/// capturar Sentry/Crashlytics) usa `debugPrint` directo o reportá vía
/// el crash reporter. `devLog` es para diagnostics que solo importan
/// cuando estás debuggeando localmente.
void devLog(String message, {int? wrapWidth}) {
  if (kDebugMode) {
    debugPrint(message, wrapWidth: wrapWidth);
  }
}
