import 'package:flutter_js/flutter_js.dart';
import 'package:youtube_explode_dart/js_challenge.dart';

import '../../core/dev_log.dart';

/// Solver de challenges JS (`sig` y `n`) de YouTube usando un motor JS
/// embebido (QuickJS vía flutter_js).
///
/// youtube_explode delega el descifrado de las firmas al "EJS" de yt-dlp
/// (github.com/yt-dlp/ejs) — un bundle JS mantenido que, dado el `base.js`
/// del player y las challenges, devuelve los valores resueltos. Ese bundle
/// necesita un intérprete de JavaScript; en móvil no hay Deno, así que
/// usamos QuickJS.
///
/// Sin este solver, las URLs de media de WEB_REMIX salen con el parámetro
/// `n` sin transformar y googlevideo las rechaza con **403**.
class FlutterJsEjsSolver extends BaseEJSSolver {
  FlutterJsEjsSolver._(this._rt);

  final JavascriptRuntime _rt;

  /// Crea e inicializa el solver: descarga los módulos EJS (lib + core) y los
  /// evalúa en el runtime para dejar disponible la función global `jsc`.
  /// Devuelve null si el runtime o los módulos no se pudieron cargar — el
  /// caller cae al comportamiento sin descifrado.
  static Future<FlutterJsEjsSolver?> create() async {
    try {
      final rt = getJavascriptRuntime();
      // Fetch (con cache interno del paquete) del bundle EJS de yt-dlp.
      final modules = await EJSBuilder.getJSModules();
      final res = rt.evaluate(modules);
      if (res.isError) {
        devLog('[EJS] fallo al cargar módulos: ${res.stringResult}');
        rt.dispose();
        return null;
      }
      devLog('[EJS] solver JS inicializado (QuickJS)');
      return FlutterJsEjsSolver._(rt);
    } catch (e) {
      devLog('[EJS] no se pudo inicializar el motor JS: $e');
      return null;
    }
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    // `jsCode` es una expresión síncrona `JSON.stringify(jsc({...}))` que
    // youtube_explode arma con el player script + las challenges.
    final result = _rt.evaluate(jsCode);
    if (result.isError) {
      throw Exception('EJS eval error: ${result.stringResult}');
    }
    return result.stringResult;
  }

  @override
  void dispose() {
    try {
      _rt.dispose();
    } catch (_) {}
  }
}
