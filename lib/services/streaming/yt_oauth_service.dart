import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/dev_log.dart';

/// Resultado inicial del Device Code request: user code + URL para mostrar
/// al usuario, device code + intervalo de polling para el lado de la app.
class DeviceCodeChallenge {
  const DeviceCodeChallenge({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresInSeconds,
    required this.pollIntervalSeconds,
  });

  /// Code interno que enviamos en cada poll. NO mostrarlo al usuario.
  final String deviceCode;

  /// Code de 8 caracteres (tipo "ABCD-EFGH") que el usuario tipea en el
  /// browser. Este SÍ se muestra.
  final String userCode;

  /// URL para abrir en el browser real del usuario (no WebView).
  /// Típicamente `https://www.google.com/device`.
  final String verificationUrl;

  /// Vida del code antes de que Google deje de aceptarlo. ~30 min por default.
  final int expiresInSeconds;

  /// Cada cuántos segundos debemos poll-ear el token endpoint. Google
  /// nos castiga (slow_down) si polleamos más rápido.
  final int pollIntervalSeconds;
}

/// Tokens OAuth de Google. `accessTokenExpiry` es epoch ms absoluto.
class YtOauthTokens {
  const YtOauthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiryEpochMs,
  });

  final String accessToken;
  final String refreshToken;
  final int accessTokenExpiryEpochMs;
}

/// Resultado del polling. Puede ser: pendiente, success con tokens, o
/// error fatal (denied, expired).
///
/// Cada result trae [statusCode] + [rawBody] cuando vinieron de Google
/// (null para fallos pre-HTTP como timeout). Sirve para diagnóstico
/// visible al usuario cuando el flow se queda colgado — el beta tester
/// puede captura de pantalla y mandar.
sealed class PollResult {
  const PollResult({this.statusCode, this.rawBody});
  final int? statusCode;
  final String? rawBody;
}

class PollPending extends PollResult {
  const PollPending({super.statusCode, super.rawBody});
}

class PollSuccess extends PollResult {
  const PollSuccess(this.tokens, {super.statusCode, super.rawBody});
  final YtOauthTokens tokens;
}

class PollDenied extends PollResult {
  const PollDenied({super.statusCode, super.rawBody});
}

class PollExpired extends PollResult {
  const PollExpired({super.statusCode, super.rawBody});
}

class PollError extends PollResult {
  const PollError(this.message, {super.statusCode, super.rawBody});
  final String message;
}

/// Implementa OAuth 2.0 Device Code Flow contra los endpoints de Google
/// usando las credenciales públicas del YouTube TV app.
///
/// Por qué este flow vs. WebView:
///   1. Google bloquea WebView en login por su política anti-phishing
///      ("This browser or app may not be secure" en pantalla blanca).
///   2. Device Code NO requiere WebView — el usuario abre la URL en su
///      browser real (Chrome, Safari, etc.), tipea un code corto, y
///      autoriza ahí.
///   3. Los tokens resultantes funcionan con el header
///      `Authorization: Bearer <token>` contra los endpoints internos de
///      YT Music (igual que cookies pero más estable).
///
/// Credenciales: las del YouTube TV app, públicas y usadas por
/// ytmusicapi/youtube-dl. Google las trata como cliente "TV/limited input".
class YtOauthService {
  YtOauthService({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  // Endpoints OAuth de Google para el client_id del YouTube TV app.
  //
  // **IMPORTANTE**: usamos los endpoints YouTube-específicos (no los
  // genéricos `oauth2.googleapis.com/device/code`). El client_id del
  // YT TV está registrado contra `youtube.com/o/oauth2`, y el grant_type
  // que acepta es el legacy `http://oauth.net/grant_type/device/1.0` con
  // parámetro `code` (no el RFC 8628 con `device_code`). Mezclar
  // endpoints/grant_types produce `invalid_request: Missing required
  // parameter: device_code` — exactamente lo que veía el beta tester.
  //
  // Esto es lo mismo que usa ytmusicapi en su path OAuth en Python.
  static const _deviceCodeUrl =
      'https://www.youtube.com/o/oauth2/device/code';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';
  static const _deviceGrantType =
      'http://oauth.net/grant_type/device/1.0';

  // Credenciales públicas del YouTube TV app (usadas por ytmusicapi).
  // Google no las trata como secret — son identificadores del cliente,
  // no autenticación de cliente.
  static const _clientId =
      '861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com';
  static const _clientSecret = 'SboVhoG9s0rNafixCSGGKXAT';
  static const _scope = 'https://www.googleapis.com/auth/youtube';

  /// Paso 1: pedir un device code a Google. Devuelve el challenge que la UI
  /// muestra al usuario.
  Future<DeviceCodeChallenge> requestDeviceCode() async {
    final r = await _http.post(
      Uri.parse(_deviceCodeUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _clientId,
        'scope': _scope,
      },
    );
    if (r.statusCode != 200) {
      devLog('requestDeviceCode failed: ${r.statusCode} ${r.body}');
      throw YtOauthException(
        'Google rechazó la petición: ${r.statusCode}',
        statusCode: r.statusCode,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return DeviceCodeChallenge(
      deviceCode: m['device_code'] as String,
      userCode: m['user_code'] as String,
      verificationUrl: m['verification_url'] as String,
      expiresInSeconds: (m['expires_in'] as num).toInt(),
      pollIntervalSeconds: (m['interval'] as num).toInt(),
    );
  }

  /// Paso 2: poll del token endpoint hasta que el usuario autorice o
  /// expire. Llamar en loop con el intervalo del challenge.
  ///
  /// Importante: si Google devuelve `slow_down`, debemos AUMENTAR el
  /// intervalo (el server nos está pidiendo que polleemos menos). Esto se
  /// señaliza via [PollError] con mensaje específico — el caller debe
  /// incrementar su delay antes del próximo poll.
  Future<PollResult> pollOnce(String deviceCode) async {
    http.Response? r;
    String? rawBody;
    try {
      r = await _http.post(
        Uri.parse(_tokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': _clientId,
          'client_secret': _clientSecret,
          // El parámetro se llama `code` (no `device_code`) porque
          // usamos el grant_type legacy de Google `oauth.net/.../device/1.0`.
          // El RFC 8628 (`urn:ietf:params:...:device_code`) pediría
          // `device_code` pero el client_id del YT TV no está
          // registrado para ese flow.
          'code': deviceCode,
          'grant_type': _deviceGrantType,
        },
      );
      rawBody = r.body;
      // `print` (no devLog) para que también se vea en release builds —
      // el beta tester puede `adb logcat | grep VIBRA-OAUTH` para
      // ver qué le contesta Google sin necesidad de build de debug.
      // ignore: avoid_print
      print('[VIBRA-OAUTH] poll status=${r.statusCode} bodyLen=${rawBody.length}');

      Map<String, dynamic> m;
      try {
        m = jsonDecode(rawBody) as Map<String, dynamic>;
      } catch (e) {
        // ignore: avoid_print
        print('[VIBRA-OAUTH] body no es JSON parseable: $e');
        return PollError('invalid_response',
            statusCode: r.statusCode, rawBody: _truncate(rawBody, 400));
      }

      if (r.statusCode == 200) {
        // Defensive: lee con casts opcionales. Si access_token falta o
        // viene null (no debería con device flow pero Google a veces
        // cambia formato), no tireamos exception → reportamos PollError
        // específico con el body para diagnóstico.
        final accessToken = m['access_token'] as String?;
        if (accessToken == null || accessToken.isEmpty) {
          // ignore: avoid_print
          print('[VIBRA-OAUTH] 200 sin access_token, body=$rawBody');
          return PollError('missing_access_token',
              statusCode: r.statusCode, rawBody: _truncate(rawBody, 400));
        }
        // refresh_token: Google lo manda en device flow pero defensivo —
        // si por algún motivo viniera vacío (ej. el usuario YA tiene
        // sesión a este device y re-autoriza), seguimos con string vacío;
        // el cliente podrá usar access_token hasta que expire y entonces
        // pedirá re-login.
        final refreshToken = m['refresh_token'] as String? ?? '';
        final expiresIn = (m['expires_in'] as num?)?.toInt() ?? 3600;
        final expiry = DateTime.now().millisecondsSinceEpoch +
            (expiresIn * 1000);
        // ignore: avoid_print
        print('[VIBRA-OAUTH] ✓ tokens recibidos. '
            'access(len)=${accessToken.length} refresh(len)=${refreshToken.length} '
            'expires=${expiresIn}s');
        return PollSuccess(
          YtOauthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiryEpochMs: expiry,
          ),
          statusCode: r.statusCode,
          rawBody: _truncate(rawBody, 400),
        );
      }

      // Status no-200: leer el error code de Google.
      final err = m['error'] as String?;
      // ignore: avoid_print
      print('[VIBRA-OAUTH] poll error=$err description=${m['error_description']}');
      switch (err) {
        case 'authorization_pending':
          return PollPending(statusCode: r.statusCode, rawBody: rawBody);
        case 'slow_down':
          return PollError('slow_down',
              statusCode: r.statusCode, rawBody: rawBody);
        case 'access_denied':
          return PollDenied(statusCode: r.statusCode, rawBody: rawBody);
        case 'expired_token':
          return PollExpired(statusCode: r.statusCode, rawBody: rawBody);
        default:
          return PollError(err ?? 'unknown_error_${r.statusCode}',
              statusCode: r.statusCode, rawBody: _truncate(rawBody, 400));
      }
    } catch (e) {
      // ignore: avoid_print
      print('[VIBRA-OAUTH] pollOnce exception: $e');
      devLog('pollOnce exception: $e');
      return PollError(
        'network_error: $e',
        statusCode: r?.statusCode,
        rawBody: rawBody == null ? null : _truncate(rawBody, 400),
      );
    }
  }

  static String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…(${s.length} total)';

  /// Refresca un access_token usando el refresh_token. Devuelve los tokens
  /// nuevos (refresh_token puede ser el mismo). Si Google rechaza con
  /// `invalid_grant`, el refresh_token fue revocado — el caller debe
  /// pedirle al usuario re-login.
  Future<YtOauthTokens> refresh(String refreshToken) async {
    final r = await _http.post(
      Uri.parse(_tokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      },
    );
    if (r.statusCode != 200) {
      devLog('refresh failed: ${r.statusCode} ${r.body}');
      throw YtOauthException(
        'Refresh rechazado: ${r.statusCode}',
        statusCode: r.statusCode,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    final accessToken = m['access_token'] as String;
    // Algunos endpoints de Google devuelven NUEVO refresh_token; otros
    // mantienen el viejo (campo ausente). Por seguridad, si viene uno
    // nuevo lo usamos.
    final newRefresh = m['refresh_token'] as String? ?? refreshToken;
    final expiresIn = (m['expires_in'] as num).toInt();
    final expiry = DateTime.now().millisecondsSinceEpoch +
        (expiresIn * 1000);
    return YtOauthTokens(
      accessToken: accessToken,
      refreshToken: newRefresh,
      accessTokenExpiryEpochMs: expiry,
    );
  }

  void close() => _http.close();
}

class YtOauthException implements Exception {
  YtOauthException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'YtOauthException($message, status=$statusCode)';
}
