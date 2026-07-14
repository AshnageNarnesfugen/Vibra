import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/settings/settings_controller.dart';
import '../core/theme/layout_tokens.dart';
import '../services/streaming/streaming_service.dart';
import '../services/streaming/yt_auth.dart';
import '../widgets/glass_card.dart';
import 'oauth_device_code_screen.dart';
import '../core/dev_log.dart';

/// Channel nativo para el estado web del WebView (Android). Métodos:
///   - getCookies(url): cookies INCLUYENDO HttpOnly (document.cookie no
///     las ve, y las HttpOnly — SID, __Secure-3PSID — son justo las que
///     Google necesita para reconocer una sesión).
///   - clearAll: cookies + WebStorage + form data → login siempre limpio.
///   - flush: persiste cookies a disco tras un login exitoso.
const _cookieChannel = MethodChannel('vibra/cookies');

/// Login a YouTube Music. Dos vías:
///   - **WebView** (recomendado): flujo calcado de OpenTune
///     (github.com/Arturo254/OpenTune). Abre el login web clásico de Google
///     (`ServiceLogin?continue=music.youtube.com`) con el user-agent POR
///     DEFECTO del WebView, fusiona las cookies de los 3 dominios de
///     YouTube y cosecha `VISITOR_DATA` + `DATASYNC_ID` del propio ytcfg
///     de la página logueada.
///   - **Paste manual**: para Linux/Windows o cuando WebView falla. El
///     usuario abre `music.youtube.com` en su navegador, copia el header
///     Cookie (DevTools → Network) y lo pega aquí. En este caso los IDs de
///     sesión se extraen con un GET a `music.youtube.com`.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  bool get _webViewSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  Future<void> _launchWebView() async {
    final result = await Navigator.of(context).push<_WebViewLoginResult>(
      MaterialPageRoute(builder: (_) => const _WebViewLogin()),
    );
    if (result == null || result.cookie.isEmpty) return;
    await _commit(
      result.cookie,
      visitorData: result.visitorData,
      dataSyncId: result.dataSyncId,
    );
  }

  /// Flujo Device Code (OAuth, recomendado). Sin WebView, sin cookies:
  /// el usuario autoriza en su navegador real. La pantalla maneja todo
  /// el polling y devuelve true cuando el token está guardado.
  Future<void> _launchDeviceCode() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const OauthDeviceCodeScreen()),
    );
    if (!mounted) return;
    if (ok == true) {
      // Pop la propia login screen para que el usuario vuelva a ajustes
      // viendo "Sesión activa".
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _pasteManually() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pegar cookie'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Necesitamos el header Cookie COMPLETO de music.youtube.com '
                '(típicamente 2000–3000 caracteres). Si solo pegas SAPISID '
                'el servidor rechaza la auth con 401.',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Método recomendado (Chrome/Edge):\n'
                '1. Abre music.youtube.com con sesión iniciada.\n'
                '2. F12 → pestaña Network.\n'
                '3. Recarga la página.\n'
                '4. Clic en cualquier request a youtubei/v1/* (browse, etc.).\n'
                '5. Sección "Request Headers" → busca "Cookie".\n'
                '6. Clic derecho → Copy value. Pega abajo.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText:
                      'SAPISID=...; HSID=...; SSID=...; APISID=...; SID=...; '
                      'LOGIN_INFO=...; __Secure-3PSID=...; '
                      '__Secure-3PAPISID=...; __Secure-3PSIDCC=...; ...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final cookie = controller.text.trim();
    if (cookie.isEmpty) return;
    await _commit(cookie);
  }

  Future<void> _commit(
    String cookie, {
    String? visitorData,
    String? dataSyncId,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = context.read<StreamingService>();
      final settingsCtrl = context.read<SettingsController>();

      // Validación de cookie completa. SAPISID solo NO basta — el servidor
      // necesita __Secure-3PSID (o SID) para reconocer la sesión. Si la
      // cookie está incompleta tiramos error antes de guardar, para que el
      // usuario no termine con un login "OK" pero todas las requests con
      // 401 silencioso.
      final auth = YtMusicAuth(cookie: cookie);
      if (!auth.isUsable) {
        throw StateError(
          'No encontré SAPISID en la cookie. Pegaste el header Cookie '
          'completo de music.youtube.com? (típicamente 2000+ caracteres)',
        );
      }
      if (!auth.isCompleteCookieSession) {
        final missing = auth.missingEssentialCookies.join(', ');
        throw StateError(
          'Cookie incompleta — faltan: $missing. La que pegaste tiene '
          '${cookie.length} caracteres; una sesión completa de YT Music '
          'suele tener 2000–3000. Asegúrate de copiar el header Cookie '
          'COMPLETO de una request en DevTools → Network.',
        );
      }
      svc.setAuth(auth);

      // IDs de sesión (visitorData + dataSyncId — la pieza clave de
      // personalización: sin dataSyncId YT Music devuelve home genérico
      // aunque la cookie sea válida). Si el WebView ya los cosechó del
      // ytcfg de la página logueada usamos esos: corresponden EXACTAMENTE
      // a la sesión recién creada. Solo con paste manual (o si la cosecha
      // falló) los extraemos del HTML con la cookie ya cargada.
      var vd = visitorData;
      var ds = dataSyncId;
      if (vd == null || ds == null) {
        final ids = await svc.fetchSessionIds();
        vd ??= ids.visitorData;
        ds ??= ids.dataSyncId;
      }
      svc.setAuth(YtMusicAuth(
        cookie: cookie,
        visitorData: vd,
        dataSyncId: ds,
      ));

      settingsCtrl.update((s) => s.copyWith(
            ytMusicCookie: cookie,
            ytMusicVisitorData: vd,
            ytMusicDataSyncId: ds,
          ));

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _logout() async {
    context.read<StreamingService>().clearAuth();
    context.read<SettingsController>().update(
          (s) => s.copyWith(clearYtMusicAuth: true),
        );
    // Limpiar también el estado del WebView (cookies, WebStorage) para que
    // el próximo login arranque con sesión de Google fresca — mismo patrón
    // que el clearWebAuthSession de OpenTune.
    try {
      await _cookieChannel.invokeMethod('clearAll');
    } catch (_) {
      // Canal no disponible en esta plataforma — no bloquea el logout.
    }
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final ctrl = context.watch<SettingsController>();
    // Sesión activa solo si hay COOKIE (única que funciona post-2024).
    // Si solo hay OAuth, mostramos un banner de "limitado" en lugar de
    // tratar al usuario como sin sesión — los tokens están guardados,
    // simplemente Google los rechaza.
    final s = ctrl.value;
    final hasCookieSession = s.ytMusicCookie != null;
    final hasOauthOnly = !hasCookieSession &&
        (s.ytMusicAccessToken != null ||
            s.ytMusicRefreshToken != null);
    final isLoggedIn = hasCookieSession;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Cuenta de YouTube Music')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isLoggedIn
                          ? Icons.verified_user_rounded
                          : Icons.account_circle_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    SizedBox(width: tokens.gap),
                    Text(
                      isLoggedIn ? 'Sesión activa' : 'Sin sesión',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                SizedBox(height: tokens.gapSm),
                Text(
                  isLoggedIn
                      ? 'Tienes acceso a tu biblioteca personal: gustadas, '
                          'historial, recomendaciones personalizadas.'
                      : 'Sin sesión solo verás búsqueda pública y trending '
                          'genérico. Inicia sesión para acceder a tu biblioteca.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          // Banner especial cuando hay tokens OAuth guardados pero no cookie:
          // los tokens no le sirven al usuario (Google rechaza), pero los
          // dejamos visibles + ofrecemos limpiarlos para que cualquier
          // request futura no intente Bearer.
          if (hasOauthOnly) ...[
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.error),
                      SizedBox(width: tokens.gap),
                      Expanded(
                        child: Text(
                          'OAuth guardado pero limitado',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    'Tienes tokens OAuth guardados de un login anterior, '
                    'pero Google los rechaza desde fin de 2024 al hablar '
                    'con YouTube Music. La app va a comportarse como sin '
                    'sesión (búsqueda pública) hasta que pegues tu '
                    'cookie. Los tokens viejos los puedes limpiar abajo '
                    'si quieres.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SizedBox(height: tokens.gap),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _logout,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Limpiar tokens OAuth viejos'),
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),
          ],
          if (!isLoggedIn) ...[
            // ─── Método recomendado: login con Google embebido ───
            // Flujo calcado de OpenTune: el login web clásico de Google
            // (ServiceLogin → music.youtube.com) SÍ funciona en WebView
            // con user-agent por defecto. Lo que Google bloquea son los
            // flows OAuth embebidos (cerrados desde fines de 2024, mismo
            // issue que ytmusicapi) y los UA falsificados que no cuadran
            // con el TLS fingerprint del WebView.
            if (_webViewSupported) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _launchWebView,
                icon: const Icon(Icons.login_rounded),
                label: const Text('Iniciar sesión con Google'),
              ),
              SizedBox(height: tokens.gapSm),
              GlassCard(
                padding: tokens.tilePadding(),
                child: Text(
                  'Se abre el login normal de Google dentro de la app y al '
                  'terminar Vibra captura la sesión automáticamente. Es el '
                  'mismo método que usan OpenTune e InnerTune.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SizedBox(height: tokens.gap),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pasteManually,
                icon: const Icon(Icons.content_paste_rounded),
                label: const Text('Pegar cookie desde el navegador'),
              ),
            ] else
              // Desktop (Linux/Windows): sin WebView, el paste es el
              // método primario.
              FilledButton.icon(
                onPressed: _busy ? null : _pasteManually,
                icon: const Icon(Icons.content_paste_rounded),
                label: const Text('Pegar cookie desde el navegador'),
              ),
            SizedBox(height: tokens.gapSm),
            GlassCard(
              padding: tokens.tilePadding(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.recommend_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary),
                      SizedBox(width: tokens.gapSm),
                      Text('Cómo conseguir la cookie',
                          style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    '1. Abre music.youtube.com en Chrome/Firefox con tu '
                    'sesión iniciada.\n'
                    '2. F12 (DevTools) → pestaña "Network" / "Red".\n'
                    '3. Recarga la página y haz clic en cualquier '
                    'request a youtubei/v1/*.\n'
                    '4. En "Request Headers" copia TODO el header '
                    '"Cookie" (típicamente 2000+ caracteres).\n'
                    '5. Pega esa línea con el botón de arriba.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),
            // ─── Métodos alternativos / experimentales ───
            ExpansionTile(
              shape: const RoundedRectangleBorder(side: BorderSide.none),
              collapsedShape:
                  const RoundedRectangleBorder(side: BorderSide.none),
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Métodos alternativos',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              children: [
                SizedBox(height: tokens.gapSm),
                GlassCard(
                  padding: tokens.tilePadding(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              size: 18,
                              color: Theme.of(context).colorScheme.error),
                          SizedBox(width: tokens.gapSm),
                          Expanded(
                            child: Text(
                              'No recomendado — Google lo limitó',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: tokens.gapSm),
                      Text(
                        'OAuth: funciona el login pero las requests a la '
                        'API retornan 400 desde finales de 2024 (mismo '
                        'issue que ytmusicapi).',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: tokens.gap),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _launchDeviceCode,
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Iniciar sesión OAuth (limitado)'),
                ),
                SizedBox(height: tokens.gapSm),
              ],
            ),
          ] else
            OutlinedButton.icon(
              onPressed: _busy ? null : _logout,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Cerrar sesión'),
            ),
          if (_busy) ...[
            SizedBox(height: tokens.gap),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            SizedBox(height: tokens.gap),
            GlassCard(
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded),
                  SizedBox(width: tokens.gap),
                  Expanded(child: Text(_error!)),
                ],
              ),
            ),
          ],
          SizedBox(height: tokens.gapLg),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sobre la sesión',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SizedBox(height: tokens.gapSm),
                Text(
                  'Vibra usa la API InnerTube no oficial de YouTube Music. '
                  'Tu cookie se guarda solo en este dispositivo y se envía '
                  'firmada (SAPISIDHASH) en cada request, igual que hace tu '
                  'navegador. No la compartimos con nadie. Ten en cuenta que '
                  'esta API no está pensada para clientes externos: úsala '
                  'bajo tu propia responsabilidad.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Resultado del login por WebView: cookie fusionada + IDs de sesión
/// cosechados del ytcfg de la propia página logueada (más fiables que un
/// fetch separado porque corresponden EXACTAMENTE a la sesión recién creada).
class _WebViewLoginResult {
  const _WebViewLoginResult({
    required this.cookie,
    this.visitorData,
    this.dataSyncId,
  });

  final String cookie;
  final String? visitorData;
  final String? dataSyncId;
}

/// Pantalla embebida con el login web de Google — port fiel del
/// `LoginScreen.kt` de OpenTune (github.com/Arturo254/OpenTune), que es el
/// flujo que la familia InnerTune lleva años usando de forma estable:
///
///   1. Estado web LIMPIO antes de empezar (cookies + WebStorage). Un
///      intento a medias deja a Google en modo "verifica que eres tú"
///      perpetuo que rompe los logins siguientes.
///   2. URL `ServiceLogin?continue=music.youtube.com` — el flujo web
///      clásico. Sin `service=youtube` ni arrancar en `/signin` (activan
///      otros paths de verificación).
///   3. User-agent POR DEFECTO del WebView. Falsificar el UA (nuestro viejo
///      "Firefox en Linux") es contraproducente: el TLS fingerprint sigue
///      siendo el del WebView de Android y la discrepancia es justo lo que
///      dispara el "este navegador no es seguro".
///   4. Cookies de terceros aceptadas — el redirect accounts.google.com →
///      music.youtube.com setea cookies cross-domain.
///   5. En cada página de youtube.com: cosechar VISITOR_DATA + DATASYNC_ID
///      del ytcfg y fusionar cookies de los 3 dominios (music/www/bare).
///   6. Éxito solo cuando la cookie tiene SAPISID + SID (sesión completa);
///      hasta entonces el WebView sigue abierto y reintenta solo.
class _WebViewLogin extends StatefulWidget {
  const _WebViewLogin();

  @override
  State<_WebViewLogin> createState() => _WebViewLoginState();
}

class _WebViewLoginState extends State<_WebViewLogin> {
  late final WebViewController _controller;

  static const _loginUrl = 'https://accounts.google.com/ServiceLogin'
      '?continue=https%3A%2F%2Fmusic.youtube.com';

  bool _completed = false;
  bool _loading = true;
  bool _onYouTube = false;
  String? _visitorData;
  String? _dataSyncId;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF101015))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: _onPageFinished,
          // Permitimos toda navegación — Google rebota entre subdominios y
          // si bloqueamos algo se rompe el flow.
          onNavigationRequest: (_) => NavigationDecision.navigate,
        ),
      );
    _acceptThirdPartyCookies();
    _startFresh();
  }

  /// Google setea cookies cruzadas entre accounts.google.com y los dominios
  /// de YouTube durante los redirects del login. Sin third-party cookies el
  /// WebView descarta parte de la sesión → cookie incompleta → 401.
  void _acceptThirdPartyCookies() {
    final platformController = _controller.platform;
    final platformCookies = WebViewCookieManager().platform;
    if (platformController is AndroidWebViewController &&
        platformCookies is AndroidWebViewCookieManager) {
      platformCookies.setAcceptThirdPartyCookies(platformController, true);
    }
  }

  /// Port de `resetAuthWebViewSession` de OpenTune: cada intento de login
  /// arranca con el estado web limpio.
  Future<void> _startFresh() async {
    try {
      await _cookieChannel.invokeMethod('clearAll');
    } catch (_) {
      // Canal no disponible (iOS/macOS) — limpiamos lo que webview_flutter
      // expone y seguimos.
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {}
    }
    await _controller.loadRequest(Uri.parse(_loginUrl));
  }

  Future<void> _onPageFinished(String url) async {
    if (mounted) setState(() => _loading = false);
    if (_completed) return;
    final host = Uri.tryParse(url)?.host ?? '';
    final isYouTube = host == 'music.youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'youtube.com';
    if (mounted) setState(() => _onYouTube = isYouTube);
    if (!isYouTube) return;

    await _harvestSessionIds();
    await _captureCookies();
    // music.youtube.com es una SPA: dispara UN solo onPageFinished y las
    // cookies de sesión pueden asentarse un instante después del redirect.
    // Reintentos cortos en vez de un delay fijo único.
    for (final delay in const [Duration(seconds: 1), Duration(seconds: 3)]) {
      if (_completed || !mounted) return;
      await Future.delayed(delay);
      if (_completed || !mounted) return;
      await _harvestSessionIds();
      await _captureCookies();
    }
  }

  /// Igual que OpenTune: leer `VISITOR_DATA` y `DATASYNC_ID` del
  /// `yt.config_` de la página ya logueada.
  Future<void> _harvestSessionIds() async {
    Future<String?> eval(String key) async {
      try {
        final raw = await _controller.runJavaScriptReturningResult(
          "(function(){try{"
          "var c=window.yt&&window.yt.config_;"
          "if(c&&c['$key'])return c['$key'];"
          "var g=window.ytcfg;"
          "if(g&&g.get)return g.get('$key')||'';"
          "return ''}catch(e){return ''}})()",
        );
        var s = raw is String ? raw : raw.toString();
        // Android devuelve el resultado JSON-quoted ("\"abc\"").
        if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
          s = s.substring(1, s.length - 1);
        }
        if (s.isEmpty || s == 'null') return null;
        return s;
      } catch (_) {
        return null;
      }
    }

    final vd = await eval('VISITOR_DATA');
    if (vd != null) _visitorData = vd;
    var ds = await eval('DATASYNC_ID');
    if (ds != null) {
      // El HTML trae "123||suffix" — solo la parte antes de `||` es el id
      // que user.onBehalfOfUser espera (mismo strip que OpenTune).
      final cut = ds.indexOf('||');
      if (cut >= 0) ds = ds.substring(0, cut);
      if (ds.isNotEmpty) _dataSyncId = ds;
    }
  }

  /// Fusión de cookies de los tres dominios de YouTube, calcada del
  /// `mergeYouTubeCookies` de OpenTune. Las HttpOnly (SID, __Secure-3PSID…)
  /// solo son visibles vía CookieManager nativo — document.cookie no las ve,
  /// y son exactamente las que Google necesita para reconocer la sesión.
  Future<String?> _mergedCookies() async {
    final parts = <String, String>{};
    for (final url in const [
      'https://music.youtube.com',
      'https://www.youtube.com',
      'https://youtube.com',
    ]) {
      String? raw;
      try {
        raw = await _cookieChannel
            .invokeMethod<String>('getCookies', {'url': url});
      } catch (e) {
        devLog('[YTM] native cookie channel failed: $e');
        break;
      }
      if (raw == null || raw.isEmpty) continue;
      for (final part in raw.split(';')) {
        final t = part.trim();
        final eq = t.indexOf('=');
        if (eq <= 0) continue;
        final name = t.substring(0, eq).trim();
        if (name.isEmpty) continue;
        parts[name] = t.substring(eq + 1).trim();
      }
    }
    if (parts.isEmpty) return null;
    return parts.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _captureCookies({bool manual = false}) async {
    if (_completed) return;
    try {
      var cookie = await _mergedCookies();
      // Fallback sin canal nativo: document.cookie (incompleto, sin
      // HttpOnly — puede bastar en iOS/macOS donde WKWebView comparte).
      if (cookie == null || cookie.isEmpty) {
        final raw = await _controller
            .runJavaScriptReturningResult('document.cookie');
        cookie = raw is String ? raw.replaceAll('"', '') : raw.toString();
      }

      final auth = YtMusicAuth(cookie: cookie);
      // La captura automática exige sesión COMPLETA (SAPISID + SID) — hasta
      // entonces seguimos esperando sin cerrar el WebView. Con el botón
      // manual basta SAPISID: _commit reporta exactamente qué falta.
      final ready = manual ? auth.isUsable : auth.isCompleteCookieSession;
      if (!ready) return;

      _completed = true;
      // Persistir cookies del WebView a disco antes de salir — un login
      // recién hecho puede vivir solo en RAM.
      try {
        await _cookieChannel.invokeMethod('flush');
      } catch (_) {}
      devLog('[YTM] webview cookie capturada (len=${cookie.length}, '
          'visitorData=${_visitorData != null ? "sí" : "no"}, '
          'dataSyncId=${_dataSyncId != null ? "sí" : "no"})');
      if (!mounted) return;
      Navigator.of(context).pop(_WebViewLoginResult(
        cookie: cookie,
        visitorData: _visitorData,
        dataSyncId: _dataSyncId,
      ));
    } catch (e) {
      devLog('[YTM] capture cookies error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Iniciar sesión'),
        actions: [
          // Botón explícito de "ya estoy dentro" — si la captura automática
          // falla por timing, el usuario puede confirmar manualmente.
          if (_onYouTube)
            TextButton(
              onPressed: () => _captureCookies(manual: true),
              child: const Text('Confirmar'),
            ),
          IconButton(
            tooltip: 'Cancelar',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}
