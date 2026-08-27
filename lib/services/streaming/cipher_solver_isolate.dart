import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import 'cipher_extractor.dart';

/// Descifra `sig`/`n` de las URLs de YouTube corriendo SOLO las funciones
/// pequeñas extraídas del `base.js` (variante `player_ias_tce`) en QuickJS.
///
/// **Diseño (v1.8.18)**: el motor JS (flutter_js/QuickJS) corre en el HILO
/// PRINCIPAL — evaluar el script chico (~6 KB) y llamar a `__sig`/`__n` toma
/// ~10 ms (medido en QuickJS real). `getJavascriptRuntime()` en un isolate de
/// fondo se colgaba en algunos dispositivos; en el hilo principal es fiable.
/// La ÚNICA parte pesada (extraer las funciones del base.js de ~2.9 MB) va en
/// un `compute` de una sola vez y el resultado se cachea, así no bloquea la UI.
class CipherSolverIsolate {
  String? _script; // deobfuscador cacheado
  String? _scriptUrl;

  /// Resuelve las challenges. [playerUrl] es la URL del `base.js` (se le fuerza
  /// la variante `_tce`). Devuelve `sig`/`n` descifrados o un `error` legible.
  Future<({String? sig, String? n, String? error, int? ms})> solve({
    required String playerUrl,
    String? sig,
    String? n,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final sw = Stopwatch()..start();
    final tceUrl = playerUrl.replaceFirst(
      RegExp(r'/player_[a-z0-9]+\.vflset/'),
      '/player_ias_tce.vflset/',
    );
    try {
      // 1. Script deobfuscador (descarga + extracción en compute). Cacheado.
      if (_script == null || _scriptUrl != tceUrl) {
        final resp =
            await http.get(Uri.parse(tceUrl)).timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) {
          return (
            sig: null,
            n: null,
            error: 'base.js tce HTTP ${resp.statusCode}',
            ms: sw.elapsedMilliseconds
          );
        }
        // Extracción (regex + brace-match sobre 2.9 MB) en un isolate de un
        // solo uso — es Dart puro (sin flutter_js), seguro en compute.
        final script = await compute(buildDeobfuscator, resp.body);
        if (script == null) {
          return (
            sig: null,
            n: null,
            error: 'no se pudo extraer sig/n del base.js',
            ms: sw.elapsedMilliseconds
          );
        }
        _script = script;
        _scriptUrl = tceUrl;
      }

      // 2. Motor JS en el hilo principal (rápido). Runtime fresco por llamada.
      final rt = getJavascriptRuntime();
      try {
        final ev = rt.evaluate(_script!);
        if (ev.isError) {
          return (
            sig: null,
            n: null,
            error: 'eval deobf: ${ev.stringResult}',
            ms: sw.elapsedMilliseconds
          );
        }
        String? outSig;
        String? outN;
        if (sig != null && sig.isNotEmpty) {
          final r = rt.evaluate('__sig(${_jsStr(sig)})');
          if (r.isError) {
            return (
              sig: null,
              n: null,
              error: 'sig eval: ${r.stringResult}',
              ms: sw.elapsedMilliseconds
            );
          }
          outSig = r.stringResult;
        }
        if (n != null && n.isNotEmpty) {
          final r = rt.evaluate('__n(${_jsStr(n)})');
          if (r.isError) {
            return (
              sig: null,
              n: null,
              error: 'n eval: ${r.stringResult}',
              ms: sw.elapsedMilliseconds
            );
          }
          outN = r.stringResult;
        }
        return (sig: outSig, n: outN, error: null, ms: sw.elapsedMilliseconds);
      } finally {
        rt.dispose();
      }
    } on TimeoutException {
      return (
        sig: null,
        n: null,
        error: 'timeout descargando base.js',
        ms: sw.elapsedMilliseconds
      );
    } catch (e) {
      return (sig: null, n: null, error: '$e', ms: sw.elapsedMilliseconds);
    }
  }

  void dispose() {}

  static String _jsStr(String s) {
    final esc = s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$esc"';
  }
}
