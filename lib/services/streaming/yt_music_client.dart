import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'yt_auth.dart';
import '../../core/dev_log.dart';

/// Cliente HTTP de bajo nivel hacia la API InnerTube de YouTube Music.
///
/// Importante:
///   - Esta API no es pública. Replicamos lo que hace el cliente web/Android
///     oficial: mismos headers, mismo cuerpo `context.client`. Patrón usado
///     por OpenTune, InnerTune, ViMusic, ytmusicapi, NewPipe, etc.
///   - Para extracción de streams usamos el cliente `ANDROID_MUSIC` (clientId
///     21). Devuelve URLs directas en `streamingData.adaptiveFormats[*].url`
///     sin necesidad de descifrar firmas (cosa que requeriría ejecutar el JS
///     del player de YouTube).
///   - Esta clase NO interpreta los renderers; solo hace HTTP y devuelve
///     el JSON crudo. La interpretación vive en `StreamingService`.
class YtMusicClient {
  YtMusicClient({http.Client? client})
      : _http = client ?? http.Client();

  static const _origin = 'https://music.youtube.com';
  static const _baseUrl = '$_origin/youtubei/v1';

  final http.Client _http;

  /// Sesión actual. Si es `null` o `!isUsable` las requests van como invitado.
  /// Se setea desde fuera (StreamingService la sincroniza con SettingsController).
  YtMusicAuth? auth;

  /// Callback opcional para refrescar el OAuth access_token cuando expira.
  /// Lo registra el `StreamingService` apuntando a `YtOauthService.refresh`
  /// + actualización de settings. Si retorna un nuevo [YtMusicAuth], el
  /// cliente lo asigna a `auth` antes de seguir con la request actual.
  /// Si retorna null (refresh falló), seguimos con la auth vieja —
  /// probablemente la request retorne 401 y el caller lo maneje.
  Future<YtMusicAuth?> Function()? onAuthRefresh;

  // Cliente "WEB_REMIX" para búsquedas, browse, etc. — devuelve la jerarquía
  // de "musicShelfRenderer" tipo YouTube Music.
  //
  // `clientVersion` se intenta reemplazar en runtime con la que viene en el
  // HTML de music.youtube.com (`INNERTUBE_CLIENT_VERSION`). YT Music valida
  // este número contra rangos esperados; una versión muy fuera de fecha (en
  // el pasado o en el futuro) hace que el endpoint caiga a contenido
  // genérico para visitantes. El valor de aquí es solo el FALLBACK por si
  // la extracción falla.
  static _ClientSpec _webMusic = const _ClientSpec(
    clientName: 'WEB_REMIX',
    clientVersion: '1.20250101.01.00',
    clientId: '67',
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
  );

  /// INNERTUBE_API_KEY del cliente WEB_REMIX. Se manda como `?key=` en la
  /// URL de cada request OAuth (sin esto, el gateway de Google API
  /// devuelve 400 "invalid argument" antes de llegar a YT Music). La key
  /// es PÚBLICA — viene en el HTML de music.youtube.com y la usa todo
  /// cliente que hable con InnerTube. Se refresca dinámicamente desde el
  /// HTML en [fetchSessionIds]; este fallback es el que usa ytmusicapi
  /// históricamente.
  static String _innertubeApiKey =
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';

  // Clientes para PLAYER, en cascada según OpenTune (probados 2025). Cada
  // uno tiene tasa de éxito distinta dependiendo de qué quita Google en
  // ese momento. Los con `loginSupported: false` no envían cookie/auth —
  // bypassean varias restricciones (age-gate, geo-block) por ser "fresh
  // visitor" desde el punto de vista del server.
  static const _ios = _ClientSpec(
    clientName: 'IOS',
    clientVersion: '19.29.1',
    clientId: '5',
    userAgent: 'com.google.ios.youtube/19.29.1 '
        '(iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
    osVersion: '17.5.1.21F90',
  );

  static const _iosMusic = _ClientSpec(
    clientName: 'IOS_MUSIC',
    clientVersion: '7.27.0',
    clientId: '26',
    userAgent: 'com.google.ios.youtubemusic/7.27.0 '
        '(iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
    osName: 'iOS',
    osVersion: '17.5.1.21F90',
  );

  static const _android = _ClientSpec(
    clientName: 'ANDROID',
    clientVersion: '21.10.38',
    clientId: '3',
    userAgent: 'com.google.android.youtube/21.10.38 '
        '(Linux; U; Android 15; en_US; Pixel 9 Pro; '
        'Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip',
    osName: 'Android',
    osVersion: '15',
  );

  /// VR con auth — útil cuando el video requiere sesión.
  static const _androidVr = _ClientSpec(
    clientName: 'ANDROID_VR',
    clientVersion: '1.61.48',
    clientId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.61.48 '
        '(Linux; U; Android 12; en_US; Quest 3; '
        'Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)',
    osName: 'Android',
    osVersion: '12',
  );

  /// VR sin auth — bypassea age-gate y region-block en muchos videos
  /// porque el server lo ve como visitante limpio. Una versión vieja (1.37)
  /// que Google aún acepta sin PoT.
  static const _androidVrNoAuth = _ClientSpec(
    clientName: 'ANDROID_VR',
    clientVersion: '1.37',
    clientId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.37 '
        '(Linux; U; Android 12; en_US; Quest 3; '
        'Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)',
    osName: 'Android',
    osVersion: '12',
    loginSupported: false,
  );

  static const _androidMusic = _ClientSpec(
    clientName: 'ANDROID_MUSIC',
    clientVersion: '7.27.52',
    clientId: '21',
    userAgent: 'com.google.android.apps.youtube.music/7.27.52 '
        '(Linux; U; Android 15; en_US; Pixel 9 Pro; '
        'Build/AP4A.250205.002) gzip',
    osName: 'Android',
    osVersion: '15',
  );

  static const _tvEmbedded = _ClientSpec(
    clientName: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    clientVersion: '2.0',
    clientId: '85',
    userAgent: 'Mozilla/5.0 (PlayStation; PlayStation 4/12.02) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 '
        'Safari/605.1.15',
  );

  /// Orden de cascada para extracción de stream. Mismo orden que OpenTune
  /// (probado 2025): IOS y MOBILE primero porque suelen funcionar sin PoT.
  /// Los NO_AUTH son fallback potente para videos restringidos.
  static const playerClientsCascade = <PlayerClientId>[
    PlayerClientId.ios,
    PlayerClientId.android,
    PlayerClientId.androidMusic,
    PlayerClientId.iosMusic,
    PlayerClientId.androidVrNoAuth,
    PlayerClientId.androidVr,
    PlayerClientId.tvEmbedded,
  ];

  _ClientSpec _resolve(PlayerClientId id) => switch (id) {
        PlayerClientId.ios => _ios,
        PlayerClientId.iosMusic => _iosMusic,
        PlayerClientId.android => _android,
        PlayerClientId.androidVr => _androidVr,
        PlayerClientId.androidVrNoAuth => _androidVrNoAuth,
        PlayerClientId.androidMusic => _androidMusic,
        PlayerClientId.tvEmbedded => _tvEmbedded,
      };

  /// Búsqueda en YouTube Music con filtros.
  Future<Map<String, dynamic>> search(String query, {String? filter}) async {
    final body = <String, dynamic>{
      'query': query,
    };
    if (filter != null) body['params'] = filter;
    
    return _post(
      endpoint: 'search',
      client: _webMusic,
      body: body,
    );
  }

  /// Obtiene los streamingData de un videoId con el cliente dado (o IOS_MUSIC
  /// por defecto — el primero de la cascada, el más fiable para URLs directas
  /// sin cipher).
  Future<Map<String, dynamic>> player(
    String videoId, {
    PlayerClientId clientId = PlayerClientId.iosMusic,
  }) async {
    return _post(
      endpoint: 'player',
      client: _resolve(clientId),
      body: {
        'videoId': videoId,
        'playbackContext': {
          'contentPlaybackContext': {
            'html5Preference': 'HTML5_PREF_WANTS',
          },
        },
      },
    );
  }

  /// Sugerencias de búsqueda (autocomplete).
  Future<Map<String, dynamic>> searchSuggestions(String input) async {
    return _post(
      endpoint: 'music/get_search_suggestions',
      client: _webMusic,
      body: {'input': input},
    );
  }

  /// Browse genérico — usado para `FEmusic_home`, `FEmusic_liked_videos`,
  /// playlists, álbumes, artistas. La respuesta contiene la jerarquía de
  /// `musicCarouselShelfRenderer` / `musicShelfRenderer`.
  Future<Map<String, dynamic>> browse({
    String? browseId,
    String? params,
  }) async {
    final body = <String, dynamic>{};
    if (browseId != null) body['browseId'] = browseId;
    if (params != null) body['params'] = params;

    return _post(
      endpoint: 'browse',
      client: _webMusic,
      body: body,
    );
  }

  /// Endpoint `next` — devuelve el panel "Up next" con canciones similares
  /// a la dada (videoId). Es el endpoint que YT Music usa internamente
  /// para autoplay y para llenar la cola con recomendaciones del algoritmo
  /// cuando inicias una sola canción.
  Future<Map<String, dynamic>> next({
    required String videoId,
    String? playlistId,
  }) async {
    // `RDAMVM{videoId}` es el playlistId "Radio" que YT Music usa cuando
    // pulsas "Iniciar radio" sobre una canción — devuelve un panel infinito
    // de recomendaciones algorítmicas. Sin playlistId el endpoint regresa
    // un panel vacío para canciones sueltas (no hay contexto de playlist).
    final effectivePlaylistId = playlistId ?? 'RDAMVM$videoId';
    final body = <String, dynamic>{
      'videoId': videoId,
      'playlistId': effectivePlaylistId,
      'enablePersistentPlaylistPanel': true,
      'isAudioOnly': true,
      'params': 'wAEB',
    };
    return _post(
      endpoint: 'next',
      client: _webMusic,
      body: body,
    );
  }

  /// In-flight coalescing de [fetchSessionIds]: en cold start, home +
  /// library + history disparan el fetch casi simultáneamente y cada
  /// uno descargaba el HTML completo de music.youtube.com (~1 MB).
  /// Con el coalescing, la primera llamada hace el fetch real y las
  /// concurrentes esperan el MISMO Future. Se limpia al completar para
  /// que un retry posterior (p.ej. tras re-login) haga fetch fresco.
  Future<({String? visitorData, String? dataSyncId})>? _sessionIdsInFlight;

  /// Resultado de inspeccionar el HTML de music.youtube.com: visitorData,
  /// dataSyncId (DATASYNC_ID) y clientVersion. Cualquiera puede ser null si
  /// el fetch falla o el HTML no los expone.
  Future<({String? visitorData, String? dataSyncId})> fetchSessionIds() {
    final pending = _sessionIdsInFlight;
    if (pending != null) return pending;
    final fut = _fetchSessionIdsImpl().whenComplete(() {
      _sessionIdsInFlight = null;
    });
    _sessionIdsInFlight = fut;
    return fut;
  }

  Future<({String? visitorData, String? dataSyncId})>
      _fetchSessionIdsImpl() async {
    try {
      final headers = <String, String>{
        'User-Agent': _webMusic.userAgent,
      };
      final a = auth;
      if (a != null && a.cookie.isNotEmpty) {
        headers['Cookie'] = a.cookie;
      }
      final res = await _http.get(Uri.parse(_origin), headers: headers);
      if (res.statusCode != 200) return (visitorData: null, dataSyncId: null);
      final body = res.body;

      // Refresca clientVersion (mismo razonamiento que antes).
      final versionMatch = RegExp(
        r'"INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"',
      ).firstMatch(body);
      if (versionMatch != null) {
        final version = versionMatch.group(1);
        if (version != null && version.isNotEmpty &&
            version != _webMusic.clientVersion) {
          _webMusic = _webMusic.copyWithVersion(version);
          devLog('[YTM] clientVersion refreshed: $version');
        }
      }

      // Refresca INNERTUBE_API_KEY. La hardcoded del cliente WEB_REMIX puede
      // estar vieja — Google rota estas keys ocasionalmente y las requests
      // con la vieja regresan 400 "invalid argument". La extracción del
      // HTML garantiza que siempre usamos la actual.
      final keyMatch = RegExp(
        r'"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"',
      ).firstMatch(body);
      if (keyMatch != null) {
        final key = keyMatch.group(1);
        if (key != null && key.isNotEmpty && key != _innertubeApiKey) {
          _innertubeApiKey = key;
          devLog('[YTM] innertubeApiKey refreshed: '
              '${key.substring(0, 12)}...');
        }
      }

      // VISITOR_DATA (canónico) primero, INNERTUBE_CONTEXT después, longest
      // último.
      String? visitor = RegExp(r'"VISITOR_DATA"\s*:\s*"([^"]+)"')
          .firstMatch(body)
          ?.group(1);
      visitor ??= RegExp(
        r'INNERTUBE_CONTEXT[^}]*?"visitorData"\s*:\s*"([^"]+)"',
        dotAll: true,
      ).firstMatch(body)?.group(1);
      if (visitor == null || visitor.isEmpty) {
        final all = RegExp(r'"visitorData"\s*:\s*"([^"]+)"')
            .allMatches(body)
            .map((m) => m.group(1)!)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        if (all.isNotEmpty) {
          all.sort((a, b) => b.length.compareTo(a.length));
          visitor = all.first;
        }
      }
      if (visitor != null && visitor.isEmpty) visitor = null;

      // DATASYNC_ID — clave de personalización. Formato típico: `"123||abc"`
      // donde la parte antes de `||` es el user id que YT Music acepta como
      // `user.onBehalfOfUser`. OpenTune hace exactamente este strip.
      String? dataSyncId = RegExp(r'"DATASYNC_ID"\s*:\s*"([^"]+)"')
          .firstMatch(body)
          ?.group(1);
      if (dataSyncId != null && dataSyncId.contains('||')) {
        dataSyncId = dataSyncId.substring(0, dataSyncId.indexOf('||'));
      }
      if (dataSyncId != null && dataSyncId.isEmpty) dataSyncId = null;

      devLog('[YTM] session ids: '
          'visitor=${visitor != null ? "yes(${visitor.length})" : "no"}, '
          'dataSyncId=${dataSyncId != null ? "yes" : "no"}');
      return (visitorData: visitor, dataSyncId: dataSyncId);
    } catch (e) {
      devLog('[YTM] fetchSessionIds error: $e');
      return (visitorData: null, dataSyncId: null);
    }
  }

  /// Wrapper compat: devuelve solo `visitorData`. Para personalización
  /// completa usa [fetchSessionIds] que también devuelve `dataSyncId`.
  Future<String?> fetchVisitorData() async {
    final ids = await fetchSessionIds();
    return ids.visitorData;
  }

  Future<Map<String, dynamic>> _post({
    required String endpoint,
    required _ClientSpec client,
    required Map<String, dynamic> body,
  }) async {
    // Auto-refresh del OAuth access_token: si el token expiró (o expira
    // dentro de 60s) pero tenemos refresh_token, refrescamos AHORA antes
    // de mandar la request. Sino mandaríamos un token expirado, el
    // server respondería 401, y el usuario vería un error en vez de la
    // request funcionando transparente.
    final cur = auth;
    if (cur != null &&
        !cur.hasValidBearer &&
        cur.hasRefreshToken &&
        onAuthRefresh != null) {
      try {
        final refreshed = await onAuthRefresh!();
        if (refreshed != null) {
          auth = refreshed;
        }
      } catch (e) {
        // Si el refresh falla (network, invalid_grant), seguimos con la
        // auth vieja. La request fallará con 401 y el caller (StreamingService
        // o la UI) puede decidir qué hacer (pedir re-login, mostrar error).
        // No re-throweamos para no romper el flow normal.
        // ignore: avoid_print
        // devLog desde acá rompería import sin necesidad — sentry capta el throw arriba.
      }
    }

    // Si no hay visitorData y no hay sesión, intentamos conseguir uno genérico.
    if (auth == null || auth!.visitorData == null || auth!.visitorData!.isEmpty) {
       final vd = await fetchVisitorData();
       if (vd != null) {
          auth = (auth ?? const YtMusicAuth()).copyWith(visitorData: vd);
       }
    }

    // INNERTUBE_API_KEY siempre. Es OBLIGATORIA cuando autenticamos con
    // OAuth Bearer (el gateway de Google API la requiere para OAuth o
    // devuelve 400 "invalid argument" antes de llegar a YT Music). En el
    // path cookie+SAPISIDHASH también la mandamos — Google la acepta
    // como hint adicional sin penalizar.
    //
    // URL param: `alt=json` (no `prettyPrint=false`) que es lo que usa
    // ytmusicapi. Aparentemente el gateway gRPC distingue entre estos:
    // con `prettyPrint=false` y OAuth, devuelve INVALID_ARGUMENT.
    //
    // La key vive en `_innertubeApiKey` (static) y se refresca desde el
    // HTML de music.youtube.com en cada `fetchSessionIds` para no
    // depender de una hardcoded vieja. Si la primera request falla
    // antes del primer refresh, usamos el fallback inicial.
    final uri = Uri.parse(
      '$_baseUrl/$endpoint?alt=json&key=$_innertubeApiKey',
    );

    // Inyectamos `visitorData` en el contexto si lo tenemos guardado: cuando
    // hay sesión, esto le dice a InnerTube quién eres "para personalización".
    //
    // **NO con Bearer**: el visitorData que extraemos del HTML público es
    // del visitante anónimo (no del usuario logueado vía OAuth). Mandarlo
    // junto con un Bearer del cliente TV produce inconsistencia de
    // identidad y el server rechaza con 400. ytmusicapi obtiene el
    // visitorData del usuario via endpoint dedicado `/visitor_id` después
    // del login OAuth — replicarlo aquí es opcional, sin visitorData YT
    // Music deriva uno del bearer y el flow funciona igual.
    final contextMap = client.toContext();
    final vd = auth?.visitorData;
    final useBearer = auth?.hasValidBearer ?? false;
    if (vd != null && vd.isNotEmpty && !useBearer) {
      (contextMap['client'] as Map<String, dynamic>)['visitorData'] = vd;
    }

    // CLAVE para personalización: `user.onBehalfOfUser = dataSyncId`. Sin
    // este campo, YT Music ignora la cookie y devuelve contenido de
    // visitante incluso con SAPISIDHASH válido. OpenTune lo confirma — es
    // el "secret sauce" que diferencia un cliente que ve tu Quick Picks de
    // uno que ve "Take it easy".
    //
    // **Guardrail crítico**: solo lo mandamos si la sesión es COMPLETA
    // (`isCompleteSession`) Y el client soporta login. Si la cookie está
    // incompleta (falta __Secure-3PSID, etc.) pero dataSyncId está
    // presente, mandar `onBehalfOfUser` hace que el server REJECTE con 401
    // en lugar de devolver contenido de visitante. Y si el client es
    // no-login (ANDROID_VR_NO_AUTH), mandar onBehalfOfUser confunde al
    // server y devuelve ERROR.
    // `onBehalfOfUser` SOLO con auth por cookie. Con OAuth Bearer el
    // access_token ya identifica al usuario a Google — agregar
    // onBehalfOfUser produce ambigüedad y algunos endpoints rechazan.
    final dsi = auth?.dataSyncId;
    final useCookieAuth = (auth?.isCompleteCookieSession ?? false) &&
        !(auth?.hasValidBearer ?? false);
    if (client.loginSupported &&
        dsi != null &&
        dsi.isNotEmpty &&
        useCookieAuth) {
      (contextMap['user'] as Map<String, dynamic>)['onBehalfOfUser'] = dsi;
    }

    // Con Bearer, `user` debe ir VACÍO (ytmusicapi manda `{}`).
    //
    // **Nota honesta**: Google cerró el OAuth del YT TV client_id contra
    // los endpoints de music.youtube.com desde finales de 2024. Aún con
    // body/headers/key exactamente como ytmusicapi, las requests
    // retornan 400 INVALID_ARGUMENT. Mantenemos el path Bearer por si
    // Google reabre, pero la UI ahora recomienda cookie como primary.
    // Issues abiertos en ytmusicapi: github.com/sigma67/ytmusicapi.
    final useBearerForBody = auth?.hasValidBearer ?? false;
    if (useBearerForBody) {
      (contextMap['user'] as Map<String, dynamic>).clear();
    }

    final mergedBody = <String, dynamic>{
      'context': contextMap,
      ...body,
    };

    try {
      final res = await _http.post(
        uri,
        headers: _buildHeaders(client),
        body: jsonEncode(mergedBody),
      );
      if (res.statusCode != 200) {
        throw HttpException(
          'YT Music $endpoint → HTTP ${res.statusCode}: '
          '${_truncate(res.body, 200)}',
        );
      }
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw HttpException('Red caída al hablar con YouTube Music: $e');
    }
  }

  /// Compone los headers de cada request, fusionando los del cliente con la
  /// firma SAPISIDHASH y la cookie cuando hay sesión activa.
  ///
  /// **Un solo Authorization header con la mejor variante disponible**.
  /// Antes mandaba múltiples (`SAPISIDHASH ts_h1 SAPISID1PHASH ts_h2 ...`)
  /// pero los endpoints de music.youtube.com no aceptan ese formato y
  /// rechazaban con 401 cuando había `onBehalfOfUser`. OpenTune confirma:
  /// un solo valor, prefijo correcto según qué cookie tenemos.
  ///
  /// Prioridad: `SAPISID` → `SAPISID3PHASH` → `SAPISID1PHASH`. La canónica
  /// (SAPISID) es la primera elección porque el servidor la espera por
  /// defecto; las 3PH/1PH son fallback cuando solo tienes esas variantes.
  Map<String, String> _buildHeaders(_ClientSpec client) {
    final h = Map<String, String>.from(client.headers());
    final a = auth;
    if (a == null || !a.isUsable) return h;

    // VisitorData se manda como header EXCEPTO con Bearer — por la misma
    // razón que en el body (es del visitante anónimo, no del usuario
    // OAuth, y la mismatch produce 400). Sin el header YT Music deriva
    // uno del bearer y todo sigue funcionando.
    if (a.visitorData != null && !a.hasValidBearer) {
      h['X-Goog-Visitor-Id'] = a.visitorData!;
    }

    // Skip toda la auth si el client está marcado no-login (ej.
    // ANDROID_VR_NO_AUTH). Mandar cookie a esos clients rompe la request —
    // el server espera visitor puro.
    if (!client.loginSupported) return h;

    // ─── PRIORIDAD 1: OAuth Bearer ───
    //
    // **Estado actual (jun 2026)**: Google cerró el OAuth del YT TV
    // client_id contra los endpoints de music.youtube.com. CUALQUIER
    // request con Bearer retorna 400 INVALID_ARGUMENT, sin importar
    // body/headers/key. ytmusicapi tiene el mismo issue abierto.
    //
    // Por eso: si SOLO tenemos OAuth (sin cookie completa), NO mandamos
    // Bearer — la request va como guest y al menos retorna contenido
    // público. Es feo pero infinitamente mejor que tirar 400 en cada
    // browse/search/library.
    //
    // Si Google reabre, quitar este guard y reactivar el path Bearer.
    if (a.hasValidBearer && !a.isCompleteCookieSession) {
      return h; // bearer presente pero no usable → guest
    }
    if (a.hasValidBearer) {
      // Solo llegamos acá si TAMBIÉN hay cookie completa (caso raro:
      // usuario hizo OAuth Y pegó cookie). Mantenemos el path por
      // simetría — si Google reabre, este path empieza a funcionar.
      h['Authorization'] = 'Bearer ${a.accessToken}';
      h.remove('X-Origin');
      h['Origin'] = _origin;
      h['Cookie'] = 'SOCS=CAI';
      return h;
    }

    // ─── PRIORIDAD 2: Cookie + SAPISIDHASH (legacy) ───
    //
    // Solo si la sesión por cookies está completa. Mandar la cookie
    // incompleta con SAPISIDHASH hace que el server rechace con 401 en
    // lugar de degradar a guest. Forzar guest puro cuando la auth está
    // rota nos garantiza al menos contenido genérico (Take it easy etc.)
    // en lugar de pantalla vacía con error.
    if (!a.isCompleteCookieSession) return h;

    h['Cookie'] = a.cookie;

    // Elige UNA variante en orden de prioridad — mismo orden que el browser
    // real usa en sus requests a YT Music.
    final variants = a.sapisidVariants.toList();
    if (variants.isNotEmpty) {
      // OpenTune prefiere SAPISID puro; replicamos.
      final pick = variants.firstWhere(
        (v) => v.prefix == 'SAPISIDHASH',
        orElse: () => variants.first,
      );
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final hash = sha1
          .convert(utf8.encode('$ts ${pick.value} $_origin'))
          .toString();
      h['Authorization'] = '${pick.prefix} ${ts}_$hash';
    }
    h['X-Origin'] = _origin;
    return h;
  }

  static String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  void dispose() => _http.close();
}

/// Identificador público del cliente a usar en el endpoint `player`.
/// Mapea internamente a un `_ClientSpec` privado.
enum PlayerClientId {
  ios,
  iosMusic,
  android,
  androidVr,
  androidVrNoAuth,
  androidMusic,
  tvEmbedded,
}

@immutable
class _ClientSpec {
  const _ClientSpec({
    required this.clientName,
    required this.clientVersion,
    required this.clientId,
    required this.userAgent,
    this.osName,
    this.osVersion,
    this.loginSupported = true,
  });

  final String clientName;
  final String clientVersion;
  final String clientId;
  final String userAgent;
  final String? osName;
  final String? osVersion;

  /// `false` para clients tipo `ANDROID_VR_NO_AUTH` que deben ir como
  /// visitante. Sin esto, mandar cookie+SAPISIDHASH a esos clients los
  /// "rompe" — el server espera visitor puro y devuelve ERROR.
  final bool loginSupported;

  Map<String, String> headers() => {
        'Content-Type': 'application/json',
        'User-Agent': userAgent,
        'X-Goog-Api-Format-Version': '1',
        'X-YouTube-Client-Name': clientId,
        'X-YouTube-Client-Version': clientVersion,
        // OJO: NO incluir `Origin` (diferente de `X-Origin` que sí va en
        // _buildHeaders). Google rechaza algunos requests cuando Origin no
        // matchea una whitelist → 401 silencioso. OpenTune solo manda
        // X-Origin y Referer. Misma lista de headers exacta que ellos.
        'Referer': '${YtMusicClient._origin}/',
      };

  Map<String, dynamic> toContext() => <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': clientName,
          'clientVersion': clientVersion,
          'gl': 'US',
          'hl': 'en',
          if (osName != null) 'osName': osName,
          if (osVersion != null) 'osVersion': osVersion,
        },
        // Tipo explícito Map<String, dynamic>: sin esto Dart lo infería como
        // Map<String, bool> (solo había un campo bool) y al inyectar
        // `onBehalfOfUser` (String) explotaba en runtime con
        // "type 'String' is not a subtype of type 'bool' of 'value'".
        'user': <String, dynamic>{
          'lockedSafetyMode': false,
        },
      };

  /// Devuelve una copia con `clientVersion` reemplazada. Útil cuando se
  /// extrae la versión actual desde el HTML de music.youtube.com en runtime
  /// — YT Music valida la versión contra rangos esperados y un mismatch
  /// puede degradar el endpoint a contenido genérico.
  _ClientSpec copyWithVersion(String newVersion) => _ClientSpec(
        clientName: clientName,
        clientVersion: newVersion,
        clientId: clientId,
        userAgent: userAgent,
        osName: osName,
        osVersion: osVersion,
        loginSupported: loginSupported,
      );
}
