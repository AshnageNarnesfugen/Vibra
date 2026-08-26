import 'dart:async';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import '../../core/dev_log.dart';
import 'cipher_extractor.dart';

/// Descifra `sig`/`n` de las URLs de YouTube en un **isolate en segundo
/// plano**, corriendo SOLO las funciones pequeñas extraídas del `base.js`
/// (variante `player_ias_tce`) en QuickJS. No parsea el archivo completo:
/// [buildDeobfuscator] localiza por regex las funciones de firma y de `n`
/// (unos pocos KB) y el motor las evalúa en milisegundos.
///
/// Todo el trabajo (descargar el base.js, extraer, evaluar) va en el isolate
/// para no bloquear la UI. El script deobfuscado se cachea, así solo el
/// primer track paga la descarga.
class CipherSolverIsolate {
  Isolate? _isolate;
  SendPort? _send;
  Completer<void>? _ready;

  Future<void> _ensureStarted() {
    final existing = _ready;
    if (existing != null) return existing.future;
    final ready = _ready = Completer<void>();
    final rp = ReceivePort();
    rp.listen((msg) {
      if (msg is SendPort) {
        _send = msg;
        if (!ready.isCompleted) ready.complete();
      }
    });
    Isolate.spawn(_entry, rp.sendPort, debugName: 'cipher-solver').then(
      (iso) => _isolate = iso,
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
        _ready = null;
        rp.close();
      },
    );
    return ready.future;
  }

  /// Resuelve las challenges. [playerUrl] es la URL del `base.js` (se le fuerza
  /// la variante `_tce`). Devuelve `sig`/`n` descifrados o un `error` legible.
  Future<({String? sig, String? n, String? error, int? ms})> solve({
    required String playerUrl,
    String? sig,
    String? n,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      await _ensureStarted();
    } catch (e) {
      return (sig: null, n: null, error: 'isolate no arrancó: $e', ms: null);
    }
    final reply = ReceivePort();
    _send!.send({
      'reply': reply.sendPort,
      'playerUrl': playerUrl,
      'sig': sig,
      'n': n,
    });
    try {
      final res = await reply.first.timeout(timeout);
      if (res is Map && res['error'] == null) {
        return (
          sig: res['sig'] as String?,
          n: res['n'] as String?,
          error: null,
          ms: res['ms'] as int?,
        );
      }
      final err = res is Map ? '${res['error']}' : '$res';
      devLog('[cipher-isolate] $err');
      return (
        sig: null,
        n: null,
        error: err,
        ms: res is Map ? res['ms'] as int? : null
      );
    } on TimeoutException {
      return (
        sig: null,
        n: null,
        error: 'timeout (${timeout.inSeconds}s)',
        ms: null,
      );
    } finally {
      reply.close();
    }
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _ready = null;
  }

  // ───────────────────────── isolate ─────────────────────────
  static Future<void> _entry(SendPort mainSend) async {
    final rp = ReceivePort();
    mainSend.send(rp.sendPort);

    JavascriptRuntime? rt;
    String? loadedFor; // playerUrl del script actualmente cargado

    await for (final msg in rp) {
      final m = msg as Map;
      final reply = m['reply'] as SendPort;
      final sw = Stopwatch()..start();
      try {
        final baseUrl = m['playerUrl'] as String;
        // Forzar la variante TCE (ofuscación clásica, extraíble por regex).
        final tceUrl = baseUrl.replaceFirst(
          RegExp(r'/player_[a-z0-9]+\.vflset/'),
          '/player_ias_tce.vflset/',
        );

        if (rt == null || loadedFor != tceUrl) {
          rt?.dispose();
          rt = null;
          final resp = await http.get(Uri.parse(tceUrl));
          if (resp.statusCode != 200) {
            reply.send({
              'error': 'base.js tce HTTP ${resp.statusCode}',
              'ms': sw.elapsedMilliseconds
            });
            continue;
          }
          final script = buildDeobfuscator(resp.body);
          if (script == null) {
            reply.send({
              'error': 'no se pudo extraer sig/n del base.js',
              'ms': sw.elapsedMilliseconds
            });
            continue;
          }
          rt = getJavascriptRuntime();
          final ev = rt.evaluate(script);
          if (ev.isError) {
            reply.send({
              'error': 'eval deobf: ${ev.stringResult}',
              'ms': sw.elapsedMilliseconds
            });
            rt.dispose();
            rt = null;
            continue;
          }
          loadedFor = tceUrl;
          devLog('[cipher-isolate] deobf cargado (${script.length}b) '
              'en ${sw.elapsedMilliseconds}ms');
        }

        String? outSig;
        String? outN;
        final rawSig = m['sig'] as String?;
        final rawN = m['n'] as String?;
        if (rawSig != null && rawSig.isNotEmpty) {
          final r = rt.evaluate('__sig(${_jsStr(rawSig)})');
          if (!r.isError) outSig = r.stringResult;
        }
        if (rawN != null && rawN.isNotEmpty) {
          final r = rt.evaluate('__n(${_jsStr(rawN)})');
          if (!r.isError) outN = r.stringResult;
        }
        reply.send({
          'sig': outSig,
          'n': outN,
          'error': null,
          'ms': sw.elapsedMilliseconds,
        });
      } catch (e) {
        reply.send({'error': e.toString(), 'ms': sw.elapsedMilliseconds});
      }
    }
  }

  /// Serializa un string a un literal JS seguro (para incrustarlo en la
  /// llamada `__sig("...")`).
  static String _jsStr(String s) {
    final esc = s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$esc"';
  }
}
