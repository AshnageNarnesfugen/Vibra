import 'dart:async';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

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
    // El isolate manda mensajes de progreso (`{progress: 'etapa', ms}`) y al
    // final el resultado (`{sig,n,error,ms}`). Así, si algo se cuelga,
    // sabemos EN QUÉ etapa fue (el timeout reporta la última alcanzada).
    final completer = Completer<({String? sig, String? n, String? error, int? ms})>();
    var lastStage = 'inicio';
    late final StreamSubscription sub;
    sub = reply.listen((res) {
      if (res is Map && res['progress'] != null) {
        lastStage = '${res['progress']} (${res['ms']}ms)';
        return;
      }
      if (res is Map && !completer.isCompleted) {
        completer.complete((
          sig: res['sig'] as String?,
          n: res['n'] as String?,
          error: res['error'] as String?,
          ms: res['ms'] as int?,
        ));
      }
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return (
        sig: null,
        n: null,
        error: 'timeout (${timeout.inSeconds}s) — última etapa: $lastStage',
        ms: null,
      );
    } finally {
      await sub.cancel();
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

    // Cacheamos SOLO el script deobfuscado (~5 KB) por URL — NO el runtime.
    // Creamos un runtime QuickJS FRESCO por cada solve y lo desechamos: así
    // no se arrastra estado entre tracks (evita bugs de reuso del motor).
    String? cachedScript;
    String? cachedForUrl;

    await for (final msg in rp) {
      final m = msg as Map;
      final reply = m['reply'] as SendPort;
      final sw = Stopwatch()..start();
      JavascriptRuntime? rt;
      try {
        final baseUrl = m['playerUrl'] as String;
        // Forzar la variante TCE (ofuscación clásica, extraíble por regex).
        final tceUrl = baseUrl.replaceFirst(
          RegExp(r'/player_[a-z0-9]+\.vflset/'),
          '/player_ias_tce.vflset/',
        );

        if (cachedScript == null || cachedForUrl != tceUrl) {
          final resp = await http.get(Uri.parse(tceUrl));
          reply.send({'progress': 'descargado', 'ms': sw.elapsedMilliseconds});
          if (resp.statusCode != 200) {
            reply.send({
              'error': 'base.js tce HTTP ${resp.statusCode}',
              'ms': sw.elapsedMilliseconds
            });
            continue;
          }
          final script = buildDeobfuscator(resp.body);
          reply.send({'progress': 'extraído', 'ms': sw.elapsedMilliseconds});
          if (script == null) {
            reply.send({
              'error': 'no se pudo extraer sig/n del base.js',
              'ms': sw.elapsedMilliseconds
            });
            continue;
          }
          cachedScript = script;
          cachedForUrl = tceUrl;
        }

        rt = getJavascriptRuntime();
        reply.send({'progress': 'runtime', 'ms': sw.elapsedMilliseconds});
        final ev = rt.evaluate(cachedScript);
        reply.send({'progress': 'script-evaluado', 'ms': sw.elapsedMilliseconds});
        if (ev.isError) {
          reply.send({
            'error': 'eval deobf: ${ev.stringResult}',
            'ms': sw.elapsedMilliseconds
          });
          continue;
        }

        String? outSig;
        String? outN;
        String? evalErr;
        final rawSig = m['sig'] as String?;
        final rawN = m['n'] as String?;
        if (rawSig != null && rawSig.isNotEmpty) {
          final r = rt.evaluate('__sig(${_jsStr(rawSig)})');
          if (r.isError) {
            evalErr = 'sig eval: ${r.stringResult}';
          } else {
            outSig = r.stringResult;
          }
        }
        reply.send({'progress': 'sig-listo', 'ms': sw.elapsedMilliseconds});
        if (evalErr == null && rawN != null && rawN.isNotEmpty) {
          final r = rt.evaluate('__n(${_jsStr(rawN)})');
          if (r.isError) {
            evalErr = 'n eval: ${r.stringResult}';
          } else {
            outN = r.stringResult;
          }
        }
        reply.send({'progress': 'n-listo', 'ms': sw.elapsedMilliseconds});
        if (evalErr != null) {
          reply.send({'error': evalErr, 'ms': sw.elapsedMilliseconds});
          continue;
        }
        reply.send({
          'sig': outSig,
          'n': outN,
          'error': null,
          'ms': sw.elapsedMilliseconds,
        });
      } catch (e) {
        reply.send({'error': e.toString(), 'ms': sw.elapsedMilliseconds});
      } finally {
        rt?.dispose();
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
