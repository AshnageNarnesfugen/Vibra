import 'package:flutter/foundation.dart';

/// Estado de autenticación de YouTube Music.
///
/// Soporta DOS modos de auth simultáneamente disponibles:
///
///   1. **OAuth Bearer** (recomendado, sobreviv anti-WebView de Google):
///      access_token + refresh_token obtenidos via Device Code Flow contra
///      el client_id del YouTube TV app. Se envían como
///      `Authorization: Bearer <access_token>`. Si el token expira, el
///      caller debe refrescarlo via [YtOauthService.refresh] y crear un
///      nuevo [YtMusicAuth] con los tokens nuevos.
///
///   2. **Cookie + SAPISIDHASH** (legacy, frágil al detección de WebView):
///      cadena `name=value; ...` con las cookies post-login. SHA-1 sobre
///      `${ts} ${SAPISID} ${origin}` se envía como
///      `Authorization: SAPISIDHASH ${ts}_${hash}`. La cookie completa va
///      en el header `Cookie`. Modo histórico que mantenemos como fallback
///      para usuarios que ya tienen sesión válida.
///
/// El `_buildHeaders` del cliente HTTP decide cuál usar: si hay Bearer
/// (no expirado) lo prefiere; sino cae a cookie si está completa; sino
/// envía request como visitante.
///
/// `visitorData` se manda en AMBOS modos — ayuda a YT Music a personalizar
/// el feed independiente de la auth.
@immutable
class YtMusicAuth {
  const YtMusicAuth({
    this.cookie = '',
    this.visitorData,
    this.dataSyncId,
    this.accessToken,
    this.refreshToken,
    this.tokenExpiryEpochMs,
  });

  final String cookie;
  final String? visitorData;

  /// OAuth access token (Bearer) — preferido cuando está disponible y no
  /// expirado.
  final String? accessToken;

  /// OAuth refresh token — usado para renovar [accessToken] cuando expira.
  /// Persiste indefinidamente (Google los revoca solo si el usuario
  /// quita el permiso en su cuenta).
  final String? refreshToken;

  /// Epoch ms de cuándo expira [accessToken]. Si está en el pasado o a
  /// menos de 60s del presente, se considera expirado.
  final int? tokenExpiryEpochMs;

  /// True si tenemos un access_token vigente. Le restamos 60s al expiry
  /// para evitar la ventana de carrera donde el token vence entre
  /// build-headers y send-request.
  bool get hasValidBearer {
    final tok = accessToken;
    if (tok == null || tok.isEmpty) return false;
    final exp = tokenExpiryEpochMs;
    if (exp == null) return false;
    return DateTime.now().millisecondsSinceEpoch < (exp - 60000);
  }

  /// True si tenemos refresh_token — podemos pedir nuevo access_token
  /// aunque el actual haya expirado.
  bool get hasRefreshToken =>
      (refreshToken?.isNotEmpty ?? false);

  YtMusicAuth copyWith({
    String? cookie,
    String? visitorData,
    String? dataSyncId,
    String? accessToken,
    String? refreshToken,
    int? tokenExpiryEpochMs,
    bool clearTokens = false,
  }) {
    return YtMusicAuth(
      cookie: cookie ?? this.cookie,
      visitorData: visitorData ?? this.visitorData,
      dataSyncId: dataSyncId ?? this.dataSyncId,
      accessToken: clearTokens ? null : (accessToken ?? this.accessToken),
      refreshToken: clearTokens ? null : (refreshToken ?? this.refreshToken),
      tokenExpiryEpochMs: clearTokens
          ? null
          : (tokenExpiryEpochMs ?? this.tokenExpiryEpochMs),
    );
  }

  /// Identificador del usuario actual (`DATASYNC_ID` del ytcfg). Se envía en
  /// el contexto de cada request como `user.onBehalfOfUser` — sin esto, YT
  /// Music ignora la cookie y trata todas las requests como visitante (=
  /// "Take it easy", "Mindful instrumentals", etc.). Lo extrae OpenTune del
  /// HTML de music.youtube.com y es la pieza clave para personalización.
  ///
  /// Formato esperado: `"<digits>"` (sin `||` ni sufijo — el HTML a veces
  /// trae `"123|abc"`, el caller debe haber stripped el `||...` ya).
  final String? dataSyncId;

  /// Mapa parseado por nombre. Útil para extraer SAPISID rápidamente sin
  /// re-parsear cada request. Trim de nombre Y valor — algunos paste manuales
  /// llegan con `SAPISID = abc` y eso producía un valor con espacio inicial
  /// → SAPISIDHASH inválido → 401.
  Map<String, String> get parsedCookies {
    final out = <String, String>{};
    for (final part in cookie.split(';')) {
      final t = part.trim();
      final eq = t.indexOf('=');
      if (eq <= 0) continue;
      final name = t.substring(0, eq).trim();
      final value = t.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      out[name] = value;
    }
    return out;
  }

  String? get sapisid {
    final p = parsedCookies;
    return p['SAPISID'] ??
        p['__Secure-3PAPISID'] ??
        p['__Secure-1PAPISID'];
  }

  /// Variantes de SAPISID disponibles en la cookie, con el prefijo de
  /// Authorization header que les corresponde. Logins modernos de Google a
  /// menudo SOLO tienen `__Secure-3PAPISID` — etiquetar su hash como
  /// `SAPISIDHASH` (en lugar de `SAPISID3PHASH`) hace que el servidor
  /// rechace la auth silenciosamente y devuelva contenido de visitante.
  ///
  /// Devolvemos TODAS las variantes disponibles para que el caller pueda
  /// componer un Authorization header con múltiples hashes separados por
  /// espacio (formato que aceptan los servicios de Google):
  ///   `SAPISIDHASH ts_h1 SAPISID1PHASH ts_h2 SAPISID3PHASH ts_h3`
  Iterable<({String prefix, String value})> get sapisidVariants sync* {
    final p = parsedCookies;
    final v1p = p['__Secure-1PAPISID'];
    final v3p = p['__Secure-3PAPISID'];
    final v = p['SAPISID'];
    if (v != null && v.isNotEmpty) {
      yield (prefix: 'SAPISIDHASH', value: v);
    }
    if (v1p != null && v1p.isNotEmpty) {
      yield (prefix: 'SAPISID1PHASH', value: v1p);
    }
    if (v3p != null && v3p.isNotEmpty) {
      yield (prefix: 'SAPISID3PHASH', value: v3p);
    }
  }

  /// La sesión es "utilizable" cuando hay AL MENOS uno: Bearer válido, o
  /// SAPISID (para firmar SAPISIDHASH). Bearer tiene prioridad porque es
  /// el path nuevo, robusto al WebView blocking de Google.
  bool get isUsable {
    if (hasValidBearer || hasRefreshToken) return true;
    return sapisid != null && sapisid!.isNotEmpty;
  }

  /// **Stricter check** específicamente para el path COOKIE: una sesión
  /// completa por cookies debe traer también el cookie de session
  /// (`__Secure-3PSID`/`SID`). Solo SAPISID basta para firmar pero sin SID
  /// el server no reconoce la sesión y devuelve 401.
  ///
  /// NO valida bearer — para chequear si hay bearer válido usar
  /// [hasValidBearer]. Esta propiedad es solo para el code path de cookie.
  bool get isCompleteCookieSession {
    final p = parsedCookies;
    if ((p['SAPISID']?.isEmpty ?? true) &&
        (p['__Secure-3PAPISID']?.isEmpty ?? true) &&
        (p['__Secure-1PAPISID']?.isEmpty ?? true)) {
      return false;
    }
    final hasSession = (p['__Secure-3PSID']?.isNotEmpty ?? false) ||
        (p['__Secure-1PSID']?.isNotEmpty ?? false) ||
        (p['SID']?.isNotEmpty ?? false);
    return hasSession;
  }

  /// Alias deprecado — mantiene API anterior. Equivale a
  /// [isCompleteCookieSession] OR [hasValidBearer] OR [hasRefreshToken].
  @Deprecated('Usa isCompleteCookieSession o hasValidBearer según necesidad')
  bool get isCompleteSession {
    if (hasValidBearer || hasRefreshToken) return true;
    return isCompleteCookieSession;
  }

  /// Lista de nombres de cookies críticas que FALTAN para una sesión
  /// completa. Útil para mostrar al usuario qué le falta pegar.
  List<String> get missingEssentialCookies {
    final p = parsedCookies;
    final missing = <String>[];
    if ((p['SAPISID']?.isEmpty ?? true)) missing.add('SAPISID');
    final hasSession = (p['__Secure-3PSID']?.isNotEmpty ?? false) ||
        (p['__Secure-1PSID']?.isNotEmpty ?? false) ||
        (p['SID']?.isNotEmpty ?? false);
    if (!hasSession) missing.add('__Secure-3PSID (o SID/__Secure-1PSID)');
    return missing;
  }
}
