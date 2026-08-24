import 'dart:async';
import 'dart:isolate';

import 'package:youtube_explode_dart/js_challenge.dart';

import '../../core/dev_log.dart';
import 'flutter_js_ejs_solver.dart';

/// Corre el descifrado de `sig`/`n` (motor JS QuickJS + solver EJS de yt-dlp)
/// en un **isolate en segundo plano**.
///
/// Es imprescindible: evaluar el `base.js` (~2.9 MB) y parsearlo con meriyah
/// es CPU-intensivo y SÍNCRONO; hacerlo en el hilo de UI congela la app y
/// dispara un ANR/crash. En un isolate dedicado, la UI queda libre.
///
/// El isolate mantiene vivo el runtime QuickJS y el solver (con su cache del
/// player preprocesado), así solo el primer track paga el parseo completo.
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

  /// Resuelve las challenges. Devuelve `sig`/`n` descifrados y, si falló, un
  /// `error` legible (para diagnóstico). [sig] y [n] son los valores CRUDOS.
  /// [timeout] generoso: el primer parse del base.js en QuickJS es lento.
  Future<({String? sig, String? n, String? error, int? ms})> solve({
    required String playerUrl,
    String? sig,
    String? n,
    Duration timeout = const Duration(seconds: 90),
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
      return (sig: null, n: null, error: err, ms: res is Map ? res['ms'] as int? : null);
    } on TimeoutException {
      return (
        sig: null,
        n: null,
        error: 'timeout (${timeout.inSeconds}s) resolviendo challenges',
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

  /// Punto de entrada del isolate: crea el solver una vez y atiende
  /// solicitudes de descifrado.
  static Future<void> _entry(SendPort mainSend) async {
    final rp = ReceivePort();
    mainSend.send(rp.sendPort);
    FlutterJsEjsSolver? solver;
    await for (final msg in rp) {
      final m = msg as Map;
      final reply = m['reply'] as SendPort;
      final sw = Stopwatch()..start();
      try {
        solver ??= await FlutterJsEjsSolver.create();
        if (solver == null) {
          reply.send({
            'error': 'solver init: ${FlutterJsEjsSolver.lastError}',
            'ms': sw.elapsedMilliseconds,
          });
          continue;
        }
        final playerUrl = m['playerUrl'] as String;
        String? outSig;
        String? outN;
        final rawSig = m['sig'] as String?;
        final rawN = m['n'] as String?;
        // Ambas challenges (sig + n) comparten el mismo player: la primera
        // paga el parse completo, la segunda usa el player preprocesado.
        if (rawSig != null && rawSig.isNotEmpty) {
          outSig = await solver.solve(playerUrl, JSChallengeType.sig, rawSig);
        }
        if (rawN != null && rawN.isNotEmpty) {
          outN = await solver.solve(playerUrl, JSChallengeType.n, rawN);
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
}
