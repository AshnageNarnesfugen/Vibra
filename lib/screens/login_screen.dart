import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/settings/settings_controller.dart';
import '../core/theme/layout_tokens.dart';
import '../services/streaming/streaming_service.dart';
import '../services/streaming/yt_auth.dart';
import '../widgets/glass_card.dart';
import 'oauth_device_code_screen.dart';
import '../core/dev_log.dart';

/// Login a YouTube Music. Dos vías:
///   - **WebView**: abre el formulario de Google (Android/iOS/macOS), espera
///     que aterricemos en `music.youtube.com` y captura las cookies con el
///     `WebViewCookieManager`. Esto es lo que hace OpenTune.
///   - **Paste manual**: para Linux/Windows o cuando WebView falla. El
///     usuario abre `music.youtube.com` en su navegador, copia la cookie
///     (DevTools → Application → Cookies) y la pega aquí.
///
/// En ambos casos, tras capturar la cookie hacemos un GET a `music.youtube.com`
/// para extraer el `visitorData` (es un id que personaliza las respuestas
/// InnerTube; sin él el feed es genérico).
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
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _WebViewLogin()),
    );
    if (result == null || result.isEmpty) return;
    await _commit(result);
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

  Future<void> _commit(String cookie) async {
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

      // Capturamos visitorData + dataSyncId con la cookie ya cargada en el
      // service. dataSyncId es la pieza clave de personalización: sin él,
      // YT Music devuelve home genérico aunque la cookie sea válida.
      final ids = await svc.fetchSessionIds();
      svc.setAuth(YtMusicAuth(
        cookie: cookie,
        visitorData: ids.visitorData,
        dataSyncId: ids.dataSyncId,
      ));

      settingsCtrl.update((s) => s.copyWith(
            ytMusicCookie: cookie,
            ytMusicVisitorData: ids.visitorData,
            ytMusicDataSyncId: ids.dataSyncId,
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
            // ─── Método recomendado: pegar cookie ───
            // Razón del reorden (era OAuth en 1.0.0): Google cerró desde
            // finales de 2024 el flow OAuth del YT TV client_id contra
            // los endpoints internos de music.youtube.com. Resultado:
            // el login OAuth ahora "funciona" (la app guarda tokens)
            // pero TODA request a la API retorna 400. El método cookie
            // sigue funcionando y es el único path confiable hoy.
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
                              'No recomendados — Google limitó ambos',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: tokens.gapSm),
                      Text(
                        'OAuth: funciona el login pero las requests a la '
                        'API retornan 400 desde finales de 2024 (mismo '
                        'issue que ytmusicapi).\n\n'
                        'WebView: Google detecta navegador embebido y '
                        'bloquea con "este navegador no es seguro" en '
                        'la mayoría de cuentas con 2FA.',
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
                if (_webViewSupported)
                  TextButton.icon(
                    onPressed: _busy ? null : _launchWebView,
                    icon: const Icon(Icons.warning_amber_rounded),
                    label: const Text(
                        'Probar login con WebView (experimental)'),
                  ),
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

/// Pantalla embebida con WebView de Google. Dejamos que el usuario complete
/// el login normal; cuando el browser aterriza en `music.youtube.com` (o
/// `youtube.com`), capturamos las cookies y devolvemos el string al caller.
class _WebViewLogin extends StatefulWidget {
  const _WebViewLogin();

  @override
  State<_WebViewLogin> createState() => _WebViewLoginState();
}

class _WebViewLoginState extends State<_WebViewLogin> {
  late final WebViewController _controller;
  bool _completed = false;
  bool _loading = true;
  bool _onMusicYouTube = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Firefox desktop UA. Probado: Google es mucho más permisivo aceptando
      // login con esta cadena que con cualquier "Chrome ; wv" o "Android".
      // Si pones Chrome desktop con SemiCadena Mobile, Google bloquea entre
      // email y password con "no podemos verificar este navegador".
      ..setUserAgent(
        'Mozilla/5.0 (X11; Linux x86_64; rv:121.0) '
        'Gecko/20100101 Firefox/121.0',
      )
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
      )
      ..loadRequest(Uri.parse(
        // Sin `passive=true` (cambia el flow de auth) y empezando en /signin
        // (más natural que /ServiceLogin) para que Google no marque flags
        // de "antiguo método" en su lado.
        'https://accounts.google.com/signin'
        '?service=youtube&hl=en'
        '&continue=https%3A%2F%2Fmusic.youtube.com%2F',
      ));
  }

  Future<void> _onPageFinished(String url) async {
    if (mounted) setState(() => _loading = false);
    if (_completed) return;
    final uri = Uri.parse(url);
    final isMusic = uri.host == 'music.youtube.com';
    if (mounted) setState(() => _onMusicYouTube = isMusic);
    if (!isMusic) return;
    await _captureCookies();
  }

  /// Channel nativo para leer cookies del WebView incluyendo HttpOnly.
  /// `document.cookie` desde JS NO ve las HttpOnly (SID, __Secure-3PSID,
  /// HSID, SSID, etc.) — y esas son exactamente las que Google necesita
  /// para reconocer una sesión. Sin esto el login terminaba siempre con
  /// cookie incompleta y todas las requests caían en 401.
  static const _cookieChannel = MethodChannel('vibra/cookies');

  Future<void> _captureCookies() async {
    if (_completed) return;
    // Pequeño delay para que music.youtube.com termine de asentar cookies
    // tras el redirect del login.
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      // 1) Intento prioritario: CookieManager nativo (incluye HttpOnly).
      String? cookie;
      try {
        cookie = await _cookieChannel.invokeMethod<String>(
          'getCookies',
          {'url': 'https://music.youtube.com'},
        );
      } on PlatformException catch (e) {
        devLog('[YTM] native cookie channel failed: $e');
      }

      // 2) Fallback: document.cookie (incompleto, sin HttpOnly).
      if (cookie == null || cookie.isEmpty) {
        final raw = await _controller.runJavaScriptReturningResult(
          'document.cookie',
        );
        cookie = raw is String ? raw.replaceAll('"', '') : raw.toString();
      }

      if (cookie.contains('SAPISID') ||
          cookie.contains('__Secure-3PAPISID')) {
        _completed = true;
        devLog('[YTM] webview captured cookie (len=${cookie.length})');
        if (!mounted) return;
        Navigator.of(context).pop(cookie);
      }
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
          if (_onMusicYouTube)
            TextButton(
              onPressed: _captureCookies,
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
          if (_loading)
            const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}
