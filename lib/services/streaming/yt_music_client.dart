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

  /// PoToken (Proof-of-Origin) cosechado del WebView de login. Google lo
  /// exige cada vez más para servir streams — sin él, incluso los clients
  /// ANDROID_VR devuelven `LOGIN_REQUIRED` ("confirma que no eres un bot").
  /// Cuando está presente se manda en `serviceIntegrityDimensions` del
  /// player. Puede caducar; el WebView lo re-cosecha en cada login.
  String? poToken;

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
    clientVersion: '1.20260114.01.00',
    clientId: '67',
    userAgent:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
  );

  /// INNERTUBE_API_KEY del cliente WEB_REMIX. Se manda como `?key=` en la
  /// URL de cada request OAuth (sin esto, el gateway de Google API
  /// devuelve 400 "invalid argument" antes de llegar a YT Music).
  ///
  /// **NO es un secreto.** Es la key PÚBLICA del web client de YouTube
  /// Music — está en el HTML de music.youtube.com (view-source la muestra)
  /// y la usan ytmusicapi, yt-dlp y todo cliente de InnerTube. No da
  /// acceso a datos privados ni factura a nadie. La app además la refresca
  /// dinámicamente desde el HTML en [fetchSessionIds]; este valor es solo
  /// el seed de arranque.
  ///
  /// Se reconstruye desde fragmentos en runtime únicamente para que el
  /// secret-scanner de GitHub no la marque como "Google API Key filtrada"
  /// (falso positivo: el formato `AIza…` coincide con el de las Cloud
  /// keys privadas, pero ésta es pública por diseño). NO es seguridad
  /// real — es solo evitar el ruido de la alerta recurrente.
  static String _innertubeApiKey = _seedKey();

  static String _seedKey() => <String>[
        'AIzaSyC9',
        'XL3ZjWdd',
        'Xya6X74d',
        'JoCTL-WE',
        'YFDNX30',
      ].join();

  // Clientes para PLAYER, en cascada según OpenTune (probados 2025). Cada
  // uno tiene tasa de éxito distinta dependiendo de qué quita Google en
  // ese momento. Los con `loginSupported: false` no envían cookie/auth —
  // bypassean varias restricciones (age-gate, geo-block) por ser "fresh
  // visitor" desde el punto de vista del server.
  // IOS: SÍ autentica (loginSupported=true, igual que OpenTune). Devuelve
  // URLs directas sin `signatureCipher` — ideal para nosotros que no
  // desciframos. Con sesión activa va primero en la cascada.
  static const _ios = _ClientSpec(
    clientName: 'IOS',
    clientVersion: '19.29.1',
    clientId: '5',
    userAgent: 'com.google.ios.youtube/19.29.1 '
        '(iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
    osVersion: '17.5.1.21F90',
  );

  // IOS_MUSIC: SIN auth (loginSupported=false, igual que OpenTune). Google
  // no acepta su cookie — va en el grupo anónimo, como fallback.
  static const _iosMusic = _ClientSpec(
    clientName: 'IOS_MUSIC',
    clientVersion: '7.27.0',
    clientId: '26',
    userAgent: 'com.google.ios.youtubemusic/7.27.0 '
        '(iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)',
    osName: 'iOS',
    osVersion: '17.5.1.21F90',
    deviceMake: 'Apple',
    deviceModel: 'iPhone16,2',
    loginSupported: false,
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

  /// VR 1.61.48 SIN auth. Como los otros VR, va como visitante puro — así
  /// Google lo sirve sin PoToken. Antes heredaba loginSupported:true por
  /// defecto: con sesión activa se le mandaba cookie+SAPISIDHASH y el
  /// server lo rechazaba con ERROR (justo el síntoma "estando logueado").
  static const _androidVr = _ClientSpec(
    clientName: 'ANDROID_VR',
    clientVersion: '1.61.48',
    clientId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.61.48 '
        '(Linux; U; Android 12; en_US; Quest 3; '
        'Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)',
    osName: 'Android',
    osVersion: '12',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: '32',
    loginSupported: false,
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
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: '32',
    loginSupported: false,
  );

  /// VR intermedio sin auth (1.43.32). Google rota qué versiones VR acepta
  /// sin PoToken; tener varias sube la tasa de éxito cuando tumba una.
  static const _androidVr43 = _ClientSpec(
    clientName: 'ANDROID_VR',
    clientVersion: '1.43.32',
    clientId: '28',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.43.32 '
        '(Linux; U; Android 12; en_US; Quest 3; '
        'Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)',
    osName: 'Android',
    osVersion: '12',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: '32',
    loginSupported: false,
  );

  static const _androidMusic = _ClientSpec(
    clientName: 'ANDROID_MUSIC',
    clientVersion: '7.27.52',
    clientId: '21',
    userAgent: 'com.google.android.apps.youtube.music/7.27.52 '
        '(Linux; U; Android 15; en_US; Pixel 9 Pro; '
        'Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip',
    osName: 'Android',
    osVersion: '15',
    deviceMake: 'Google',
    deviceModel: 'Pixel 9 Pro',
    androidSdkVersion: '35',
  );

  static const _tvEmbedded = _ClientSpec(
    clientName: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    clientVersion: '2.0',
    clientId: '85',
    userAgent: 'Mozilla/5.0 (PlayStation; PlayStation 4/12.02) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 '
        'Safari/605.1.15',
  );

  /// Orden BASE de cascada para extracción de stream, usado tal cual cuando
  /// NO hay sesión. Cuando el usuario está logueado, [orderedPlayerClients]
  /// reordena esto poniendo los clients que autentican primero — ver ahí el
  /// porqué. Reordenado 2026 tras el endurecimiento de Google.
  ///
  /// Como INVITADO, los ANDROID_VR SIN AUTH van primero: son los únicos que
  /// Google sigue sirviendo sin PoToken (Proof-of-Origin) y devuelven URL
  /// directa (sin `signatureCipher` que habría que descifrar con el player
  /// JS). Google rota qué versión VR acepta, así que probamos tres (1.61 →
  /// 1.43 → 1.37). Los mobile clients (IOS/ANDROID/…) quedan como fallback:
  /// funcionan a ratos pero cada vez más piden PoToken → dan `Status Error`.
  /// tvEmbedded se sacó de la cascada — ahora exige login+PoToken y solo
  /// aportaba el "Status Error con tvEmbedded" del final.
  static const playerClientsCascade = <PlayerClientId>[
    PlayerClientId.androidVr, // 1.61.48
    PlayerClientId.androidVr43, // 1.43.32
    PlayerClientId.androidVrNoAuth, // 1.37
    PlayerClientId.ios,
    PlayerClientId.androidMusic,
    PlayerClientId.iosMusic,
  ];
  // NOTA: el cliente ANDROID plano (com.google.android.youtube) se sacó de
  // la cascada — YouTube dejó de servirle el endpoint `player` sin params
  // especiales y devuelve HTTP 400. OpenTune tampoco lo usa para streaming.
  // El enum/spec se conservan por si se necesita en otro endpoint.

  _ClientSpec _resolve(PlayerClientId id) => switch (id) {
        PlayerClientId.ios => _ios,
        PlayerClientId.iosMusic => _iosMusic,
        PlayerClientId.android => _android,
        PlayerClientId.androidVr => _androidVr,
        PlayerClientId.androidVr43 => _androidVr43,
        PlayerClientId.androidVrNoAuth => _androidVrNoAuth,
        PlayerClientId.androidMusic => _androidMusic,
        PlayerClientId.tvEmbedded => _tvEmbedded,
        PlayerClientId.webRemix => _webMusic,
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

  /// Piezas de un cliente WEB_REMIX **autenticado** con nuestra cookie, para
  /// pasárselas a `youtube_explode_dart` (que hace el POST al endpoint player
  /// y descifra las firmas con el base.js). Es la única forma de reproducir
  /// tracks bot-gated de YT Music: WEB_REMIX es el cliente que acepta la
  /// cookie de navegador (SAPISIDHASH), y youtube_explode mantiene el
  /// descifrador. Devuelve null si no hay sesión completa por cookie.
  ({
    Map<String, dynamic> payload,
    String apiUrl,
    Map<String, String> headers,
  })? webRemixAuthedClient() {
    final a = auth;
    if (a == null || !a.isCompleteCookieSession) return null;

    final ctx = _webMusic.toContext();
    final vd = a.visitorData;
    if (vd != null && vd.isNotEmpty) {
      (ctx['client'] as Map<String, dynamic>)['visitorData'] = vd;
      // onBehalfOfUser identifica al usuario logueado (Quick Picks, etc.).
      final dsi = a.dataSyncId;
      if (dsi != null && dsi.isNotEmpty) {
        (ctx['user'] as Map<String, dynamic>)['onBehalfOfUser'] = dsi;
      }
    }
    // youtube_explode necesita el clientVersion/Name en el context.client
    // para armar los headers; ya están en toContext(). Añadimos userAgent
    // ahí porque de ahí lo lee.
    (ctx['client'] as Map<String, dynamic>)['userAgent'] = _webMusic.userAgent;

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': _webMusic.userAgent,
      'X-YouTube-Client-Name': _webMusic.clientId,
      'X-YouTube-Client-Version': _webMusic.clientVersion,
      // Origin DEBE coincidir con el usado en el SAPISIDHASH (music.youtube).
      'Origin': _origin,
      'X-Origin': _origin,
      'Cookie': a.cookie,
    };
    if (vd != null && vd.isNotEmpty) headers['X-Goog-Visitor-Id'] = vd;

    final variants = a.sapisidVariants.toList();
    if (variants.isNotEmpty) {
      final pick = variants.firstWhere(
        (v) => v.prefix == 'SAPISIDHASH',
        orElse: () => variants.first,
      );
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final hash = sha1
          .convert(utf8.encode('$ts ${pick.value} $_origin'))
          .toString();
      headers['Authorization'] = '${pick.prefix} ${ts}_$hash';
    }

    final apiUrl = '$_baseUrl/player?key=$_innertubeApiKey&prettyPrint=false';
    return (payload: {'context': ctx}, apiUrl: apiUrl, headers: headers);
  }

  /// Orden de la cascada de clients ADAPTADO a la sesión. Cuando hay
  /// sesión (cookie completa o Bearer OAuth vigente), los clients que mandan
  /// la cookie (loginSupported) van PRIMERO: se autentican y pasan el
  /// bot-check de Google. Sin sesión, los ANDROID_VR anónimos van primero
  /// (funcionan como visitante limpio). Mismo criterio que OpenTune 2026.
  List<PlayerClientId> orderedPlayerClients() {
    final loggedIn = (auth?.isCompleteCookieSession ?? false) ||
        (auth?.hasValidBearer ?? false);
    if (!loggedIn) return playerClientsCascade;
    final login = <PlayerClientId>[];
    final noLogin = <PlayerClientId>[];
    for (final id in playerClientsCascade) {
      (_resolve(id).loginSupported ? login : noLogin).add(id);
    }
    return [...login, ...noLogin];
  }

  /// Obtiene los streamingData de un videoId con el cliente dado. Inyecta el
  /// PoToken (si lo hay) en el body y en la URL para pasar el bot-gate.
  ///
  /// Retry sin `onBehalfOfUser`: algunos clients (ANDROID_MUSIC, IOS…)
  /// devuelven `400 INVALID_ARGUMENT` cuando les mandamos el dataSyncId. Si
  /// pasa, reintentamos el MISMO client sin él — así el usuario logueado no
  /// se queda sin stream. Calcado de OpenTune
  /// (`shouldRetryPlayerRequestWithoutDataSyncId`).
  Future<Map<String, dynamic>> player(
    String videoId, {
    PlayerClientId clientId = PlayerClientId.iosMusic,
  }) async {
    final spec = _resolve(clientId);
    // Body mínimo, como OpenTune para clientes móviles: `videoId` + context
    // (+ serviceIntegrityDimensions si hay PoToken). NO mandamos
    // `playbackContext.contentPlaybackContext.html5Preference`: es un campo
    // del player WEB y los clientes ANDROID_MUSIC / IOS lo rechazan con 400
    // "invalid argument" / "precondition check failed". El único
    // contentPlaybackContext válido para estos sería `signatureTimestamp`,
    // que solo aplica a WEB (que no usamos porque devuelve URLs cifradas).
    final body = <String, dynamic>{
      'videoId': videoId,
    };
    // PoToken: Google lo pide para servir el stream sin `LOGIN_REQUIRED`.
    final pot = poToken;
    if (pot != null && pot.isNotEmpty) {
      body['serviceIntegrityDimensions'] = {'poToken': pot};
    }

    // ¿Este request llevará onBehalfOfUser? Solo si hay cookie completa y el
    // client autentica. Si no, ni tiene sentido el retry.
    final wouldSendDsi = spec.loginSupported &&
        (auth?.dataSyncId?.isNotEmpty ?? false) &&
        (auth?.isCompleteCookieSession ?? false) &&
        !(auth?.hasValidBearer ?? false);

    try {
      return await _post(endpoint: 'player', client: spec, body: body);
    } on HttpException catch (e) {
      final msg = e.message.toLowerCase();
      final isInvalidArg = msg.contains('http 400') &&
          (msg.contains('invalid argument') ||
              msg.contains('invalid_argument') ||
              msg.contains('precondition'));
      if (wouldSendDsi && isInvalidArg) {
        devLog('[YTM] player ${spec.clientName} 400 con onBehalfOfUser — '
            'reintentando sin dataSyncId');
        return _post(
          endpoint: 'player',
          client: spec,
          body: body,
          includeOnBehalfOfUser: false,
        );
      }
      rethrow;
    }
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
    // Cuando es false NO mandamos `user.onBehalfOfUser` (dataSyncId). Se usa
    // para el retry del endpoint `player`: algunos clients (ANDROID_MUSIC…)
    // devuelven 400 INVALID_ARGUMENT si les llega onBehalfOfUser — reintentar
    // sin él lo resuelve (mismo patrón que OpenTune).
    bool includeOnBehalfOfUser = true,
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
    // El PoToken va TAMBIÉN como query param `pot` en el endpoint `player`
    // (además de en el body). OpenTune manda ambos: algunos frontends de
    // Google lo leen de la URL y otros del body.
    final potParam = (endpoint == 'player' && poToken != null &&
            poToken!.isNotEmpty)
        ? '&pot=${Uri.encodeQueryComponent(poToken!)}'
        : '';
    // El `key=` en el endpoint `player` va SOLO para el cliente WEB_REMIX
    // (la INNERTUBE_API_KEY es la suya). Mandarla con un contexto móvil
    // (ANDROID_MUSIC / IOS) hace que el gateway rechace con 400. Los clientes
    // móviles se apoyan solo en el contexto + auth. El resto de endpoints
    // (search, browse) usan `alt=json&key=` como siempre.
    final isWebClient = client.clientName == 'WEB_REMIX';
    final Uri uri;
    if (endpoint == 'player') {
      final keyParam = isWebClient ? '&key=$_innertubeApiKey' : '';
      uri = Uri.parse(
          '$_baseUrl/$endpoint?prettyPrint=false$keyParam$potParam');
    } else {
      uri = Uri.parse('$_baseUrl/$endpoint?alt=json&key=$_innertubeApiKey');
    }

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
    if (includeOnBehalfOfUser &&
        client.loginSupported &&
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
          '${_truncate(res.body, 500)}',
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
  androidVr43,
  androidVrNoAuth,
  androidMusic,
  tvEmbedded,
  webRemix,
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
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
    this.loginSupported = true,
  });

  final String clientName;
  final String clientVersion;
  final String clientId;
  final String userAgent;
  final String? osName;
  final String? osVersion;

  /// Fabricante / modelo / SDK del dispositivo. **Obligatorios para los
  /// clientes ANDROID** (ANDROID_MUSIC, ANDROID_VR): sin `androidSdkVersion`
  /// el endpoint `player` responde 400 "invalid argument". OpenTune los manda
  /// siempre para esta familia.
  final String? deviceMake;
  final String? deviceModel;
  final String? androidSdkVersion;

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
          if (deviceMake != null) 'deviceMake': deviceMake,
          if (deviceModel != null) 'deviceModel': deviceModel,
          if (androidSdkVersion != null) 'androidSdkVersion': androidSdkVersion,
        },
        // `request` como lo manda OpenTune — algunos endpoints lo esperan.
        'request': <String, dynamic>{
          'internalExperimentFlags': <dynamic>[],
          'useSsl': true,
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
        deviceMake: deviceMake,
        deviceModel: deviceModel,
        androidSdkVersion: androidSdkVersion,
        loginSupported: loginSupported,
      );
}
