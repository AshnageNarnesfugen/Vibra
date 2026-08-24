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

  /// Motivo del último fallo de [create] — para diagnóstico. null si todo ok.
  static String? lastError;

  /// Crea e inicializa el solver: descarga los módulos EJS (lib + core) y los
  /// evalúa en el runtime para dejar disponible la función global `jsc`.
  /// Devuelve null si el runtime o los módulos no se pudieron cargar — el
  /// caller cae al comportamiento sin descifrado.
  static Future<FlutterJsEjsSolver?> create() async {
    lastError = null;
    JavascriptRuntime? rt;
    try {
      rt = getJavascriptRuntime();
    } catch (e) {
      lastError = 'getJavascriptRuntime: $e';
      devLog('[EJS] $lastError');
      return null;
    }
    try {
      // Fetch (con cache interno del paquete) del bundle EJS de yt-dlp.
      final modules = await EJSBuilder.getJSModules();
      // Smoke test del motor antes de cargar el bundle grande.
      final smoke = rt.evaluate('1+1');
      if (smoke.isError || smoke.stringResult != '2') {
        lastError = 'smoke test falló: ${smoke.stringResult}';
        devLog('[EJS] $lastError');
        rt.dispose();
        return null;
      }
      // Polyfills: el QuickJS que embebe flutter_js es viejo y le faltan
      // APIs ES2021/2022 que el bundle EJS (meriyah, etc.) usa —
      // `Object.hasOwn`, `String.prototype.replaceAll`, `Array.prototype.at`.
      // Sin ellos el bundle tira `TypeError: not a function` al cargar.
      final poly = rt.evaluate(_polyfills);
      if (poly.isError) {
        lastError = 'polyfills: ${poly.stringResult}';
        devLog('[EJS] $lastError');
        rt.dispose();
        return null;
      }
      final res = rt.evaluate(modules);
      if (res.isError) {
        lastError = 'evaluar módulos: ${res.stringResult}';
        devLog('[EJS] $lastError');
        rt.dispose();
        return null;
      }
      devLog('[EJS] solver JS inicializado (QuickJS + polyfills)');
      return FlutterJsEjsSolver._(rt);
    } catch (e) {
      lastError = 'init: $e';
      devLog('[EJS] $lastError');
      try {
        rt.dispose();
      } catch (_) {}
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

  /// Polyfills de APIs ES2021/2022 ausentes en el QuickJS viejo de flutter_js.
  /// Todos guardados con `if (!...)` — no pisan implementaciones nativas.
  static const String _polyfills = r'''
(function(){
  if (!Object.hasOwn) {
    Object.defineProperty(Object, 'hasOwn', {
      value: function(o, k){ return Object.prototype.hasOwnProperty.call(o, k); },
      configurable: true, writable: true
    });
  }
  if (!String.prototype.replaceAll) {
    Object.defineProperty(String.prototype, 'replaceAll', {
      value: function(find, replace){
        if (Object.prototype.toString.call(find) === '[object RegExp]') {
          return this.replace(find, replace);
        }
        return this.split(find).join(replace);
      },
      configurable: true, writable: true
    });
  }
  if (!Array.prototype.at) {
    Object.defineProperty(Array.prototype, 'at', {
      value: function(n){ n = Math.trunc(n) || 0; if (n < 0) n += this.length;
        return (n < 0 || n >= this.length) ? undefined : this[n]; },
      configurable: true, writable: true
    });
  }
  if (!String.prototype.at) {
    Object.defineProperty(String.prototype, 'at', {
      value: function(n){ n = Math.trunc(n) || 0; if (n < 0) n += this.length;
        return (n < 0 || n >= this.length) ? undefined : this[n]; },
      configurable: true, writable: true
    });
  }
  if (!Array.prototype.findLast) {
    Object.defineProperty(Array.prototype, 'findLast', {
      value: function(fn, thisArg){ for (var i=this.length-1;i>=0;i--){ if (fn.call(thisArg,this[i],i,this)) return this[i]; } return undefined; },
      configurable: true, writable: true
    });
  }
  if (!Object.fromEntries) {
    Object.defineProperty(Object, 'fromEntries', {
      value: function(iter){ var o={}; for (var e of iter){ o[e[0]]=e[1]; } return o; },
      configurable: true, writable: true
    });
  }
})();
''';
}
