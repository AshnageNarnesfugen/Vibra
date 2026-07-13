import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/dev_log.dart';
import '../core/settings/settings_controller.dart';
import '../core/theme/layout_tokens.dart';
import '../services/streaming/streaming_service.dart';
import '../services/streaming/yt_auth.dart';
import '../services/streaming/yt_oauth_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/stable_backdrop_group.dart';

/// Pantalla del OAuth Device Code Flow.
///
/// Flujo:
///   1. Al entrar, pedimos un device code a Google.
///   2. Mostramos el user_code de 8 chars + URL para abrir en browser.
///   3. Polleamos el token endpoint cada N segundos.
///   4. Cuando el usuario autoriza en su browser real, recibimos
///      access_token + refresh_token → cerramos la pantalla con success.
///
/// La idea es NO USAR WebView en NINGÚN punto de este flujo — eso es lo
/// que rompía el login antes. El browser real (Chrome/Safari/Firefox del
/// sistema) hace el login con Google, no nosotros.
class OauthDeviceCodeScreen extends StatefulWidget {
  const OauthDeviceCodeScreen({super.key});

  @override
  State<OauthDeviceCodeScreen> createState() => _OauthDeviceCodeScreenState();
}

class _OauthDeviceCodeScreenState extends State<OauthDeviceCodeScreen> {
  final _oauth = YtOauthService();

  DeviceCodeChallenge? _challenge;
  String? _error;
  bool _polling = false;
  bool _busyManualPoll = false;
  Timer? _pollTimer;
  int _pollIntervalSeconds = 5;
  String _status = 'Preparando…';
  int _pollAttempts = 0;
  PollResult? _lastResult;
  bool _showDiagnostics = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _bootstrap();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _oauth.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final ch = await _oauth.requestDeviceCode();
      if (!mounted) return;
      setState(() {
        _challenge = ch;
        _pollIntervalSeconds = ch.pollIntervalSeconds;
        _status = 'Esperando que autorices…';
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo obtener el código de Google: $e';
      });
    }
  }

  void _startPolling() {
    _polling = true;
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    if (!_polling) return;
    _pollTimer?.cancel();
    _pollTimer = Timer(Duration(seconds: _pollIntervalSeconds), _pollOnce);
  }

  Future<void> _pollOnce({bool manual = false}) async {
    final ch = _challenge;
    if (ch == null || !mounted) return;
    // Para el poll manual permitimos correr aunque _polling sea false (ej.
    // si ya hay un error visible y el usuario quiere reintentar sin
    // reabrir la pantalla). Para el poll automático respetamos el flag.
    if (!manual && !_polling) return;
    if (manual) {
      setState(() => _busyManualPoll = true);
    }
    _pollAttempts++;
    final res = await _oauth.pollOnce(ch.deviceCode);
    if (!mounted) return;
    setState(() {
      _lastResult = res;
      if (manual) _busyManualPoll = false;
    });
    switch (res) {
      case PollPending():
        setState(() => _status = 'Esperando autorización…');
        if (!manual) _scheduleNextPoll();
      case PollSuccess(tokens: final t):
        _polling = false;
        await _saveTokensAndFinish(t);
      case PollDenied():
        _polling = false;
        setState(() {
          _status = 'Cancelado';
          _error = 'Negaste el permiso desde el navegador. '
              'Reintenta si fue por error.';
        });
      case PollExpired():
        _polling = false;
        setState(() {
          _status = 'Código expirado';
          _error = 'El código de Google expiró antes de que autorizaras. '
              'Vuelve a abrir esta pantalla para empezar de cero.';
        });
      case PollError(message: final m):
        if (m == 'slow_down') {
          _pollIntervalSeconds += 5;
          devLog('Google asked slow_down; new interval=$_pollIntervalSeconds');
          if (!manual) _scheduleNextPoll();
        } else {
          // Error inesperado: lo mostramos al usuario para que pueda
          // mandar screenshot. Seguimos polling automático por si era
          // transitorio.
          setState(() {
            _status = 'Respuesta inesperada de Google: $m';
          });
          if (!manual) _scheduleNextPoll();
        }
    }
  }

  Future<void> _saveTokensAndFinish(YtOauthTokens tokens) async {
    if (!mounted) return;
    setState(() => _status = 'Guardando sesión…');
    final ctrl = context.read<SettingsController>();
    final s = ctrl.value;
    ctrl.update((p) => p.copyWith(
          ytMusicAccessToken: tokens.accessToken,
          ytMusicRefreshToken: tokens.refreshToken,
          ytMusicAccessTokenExpiryEpochMs:
              tokens.accessTokenExpiryEpochMs,
        ));
    // Empujar la nueva auth al StreamingService — el cliente HTTP la usa
    // para componer el header `Authorization: Bearer ...` en cada request.
    // Mantenemos cualquier visitorData/dataSyncId/cookie que ya tenía
    // (por si hay una sesión cookie previa todavía válida — coexistir es
    // OK, el cliente prefiere Bearer cuando ambas están).
    final streaming = context.read<StreamingService>();
    streaming.setAuth(YtMusicAuth(
      cookie: s.ytMusicCookie ?? '',
      visitorData: s.ytMusicVisitorData,
      dataSyncId: s.ytMusicDataSyncId,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      tokenExpiryEpochMs: tokens.accessTokenExpiryEpochMs,
    ));
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _openBrowser() async {
    final ch = _challenge;
    if (ch == null) return;
    try {
      final uri = Uri.parse(ch.verificationUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      devLog('launchUrl failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final ch = _challenge;
    final scheme = Theme.of(context).colorScheme;

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Iniciar sesión')),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            // Aviso destacado: estado actual del OAuth con YT Music.
            // Honesto con el usuario sobre la limitación que descubrimos
            // probando vs el comportamiento esperado.
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 28, color: scheme.error),
                      SizedBox(width: tokens.gapSm),
                      Expanded(
                        child: Text(
                          'Estado: limitado por Google',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: scheme.error),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    'Desde finales de 2024 Google rechaza las requests a '
                    'YouTube Music autenticadas vía este flujo OAuth '
                    '(error 400 en búsqueda, biblioteca, historial). '
                    'Podés iniciar sesión y la app guarda los tokens, '
                    'pero la mayoría de funciones personalizadas no van '
                    'a responder.\n\n'
                    'Si quieres sesión COMPLETA, vuelve atrás y usa '
                    '"Pegar cookie desde el navegador" — es el método '
                    'que sí funciona contra el endpoint actual de YT '
                    'Music. Esta limitación afecta también a '
                    'ytmusicapi y otras apps de terceros; no es bug '
                    'de Vibra.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SizedBox(height: tokens.gap),
                  FilledButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(false),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Volver y usar cookie'),
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),
            // Card secundaria para los que igual quieren intentar.
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          size: 22,
                          color: scheme.onSurface.withValues(alpha: 0.75)),
                      SizedBox(width: tokens.gapSm),
                      Expanded(
                        child: Text(
                          'Login OAuth (de todos modos)',
                          style:
                              Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    'Si Google reabre el endpoint o querés tener los '
                    'tokens guardados para usar manualmente, podés '
                    'continuar con el flow abajo. La pantalla detecta '
                    'el éxito automáticamente.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),
            if (_error != null) ...[
              GlassCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        color: scheme.error, size: 24),
                    SizedBox(width: tokens.gapSm),
                    Expanded(
                      child: Text(_error!,
                          style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
              SizedBox(height: tokens.gap),
            ],
            if (ch == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (ch != null) ...[
              // ─────── User code grande ───────
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Paso 1 — Abre esta URL',
                        style:
                            Theme.of(context).textTheme.titleSmall),
                    SizedBox(height: tokens.gapSm),
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            ch.verificationUrl,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copiar',
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: ch.verificationUrl));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('URL copiada'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: tokens.gapSm),
                    FilledButton.icon(
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const Text('Abrir en navegador'),
                      onPressed: _openBrowser,
                    ),
                  ],
                ),
              ),
              SizedBox(height: tokens.gap),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Paso 2 — Pega este código',
                        style:
                            Theme.of(context).textTheme.titleSmall),
                    SizedBox(height: tokens.gapSm),
                    Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                            vertical: tokens.gap),
                        child: SelectableText(
                          ch.userCode,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 36,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 6,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: TextButton.icon(
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copiar código'),
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: ch.userCode));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Código copiado'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                    ),
                    SizedBox(height: tokens.gapSm),
                    Text(
                      'Inicia sesión en Google si no lo está, pega el '
                      'código, autoriza el acceso, y vuelve aquí. La app '
                      'detecta el éxito automáticamente.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              SizedBox(height: tokens.gap),
              // ─────── Estado del polling + botón verificar ───────
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_polling || _busyManualPoll)
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.primary,
                            ),
                          )
                        else
                          Icon(Icons.check_circle_outline_rounded,
                              size: 18, color: scheme.primary),
                        SizedBox(width: tokens.gapSm),
                        Expanded(
                          child: Text(_status,
                              style:
                                  Theme.of(context).textTheme.bodyMedium),
                        ),
                      ],
                    ),
                    SizedBox(height: tokens.gapSm),
                    // Botón para verificar inmediatamente sin esperar el
                    // próximo tick del timer. Útil cuando autorizaste hace
                    // rato y el polling siguiente tarda en disparar (Google
                    // pidió slow_down y el intervalo es largo).
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _busyManualPoll
                              ? null
                              : () => _pollOnce(manual: true),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Verificar ahora'),
                        ),
                        const Spacer(),
                        Text(
                          'Intento #$_pollAttempts',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color:
                                    scheme.onSurface.withValues(alpha: 0.55),
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // ─────── Diagnóstico (último response de Google) ───────
              if (_lastResult != null) ...[
                SizedBox(height: tokens.gap),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => setState(
                            () => _showDiagnostics = !_showDiagnostics),
                        child: Row(
                          children: [
                            Icon(Icons.bug_report_outlined,
                                size: 18, color: scheme.onSurface),
                            SizedBox(width: tokens.gapSm),
                            Expanded(
                              child: Text(
                                'Diagnóstico técnico',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall,
                              ),
                            ),
                            Icon(
                              _showDiagnostics
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                            ),
                          ],
                        ),
                      ),
                      if (_showDiagnostics) ...[
                        SizedBox(height: tokens.gapSm),
                        Text(
                          'Si el flow se queda colgado tras autorizar en '
                          'el navegador, captura esta info y comparte '
                          'para diagnóstico.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        SizedBox(height: tokens.gapSm),
                        _DiagRow(
                          label: 'Último tipo',
                          value: _lastResult!.runtimeType.toString(),
                        ),
                        _DiagRow(
                          label: 'HTTP status',
                          value: '${_lastResult!.statusCode ?? "—"}',
                        ),
                        _DiagRow(
                          label: 'Intentos',
                          value: '$_pollAttempts',
                        ),
                        _DiagRow(
                          label: 'Intervalo actual',
                          value: '${_pollIntervalSeconds}s',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Respuesta cruda de Google:',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: scheme.surface.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color:
                                  scheme.outline.withValues(alpha: 0.4),
                            ),
                          ),
                          child: SelectableText(
                            _lastResult!.rawBody ?? '(sin respuesta)',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('Copiar diagnóstico'),
                          onPressed: () {
                            final text = '''
Vibra OAuth diagnóstico
─────────────────────
Último tipo: ${_lastResult!.runtimeType}
HTTP status: ${_lastResult!.statusCode}
Intentos: $_pollAttempts
Intervalo: ${_pollIntervalSeconds}s

Respuesta:
${_lastResult!.rawBody ?? '(sin respuesta)'}
''';
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Diagnóstico copiado'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
