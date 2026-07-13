import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import 'yt_auth.dart';
import 'yt_music_client.dart';
import '../../core/dev_log.dart';

/// Resultado de `resolveVideoUrl`: URL de un stream con video + flag de si la
/// pista trae audio. Los formats COMBINADOS (mp4 itag 18/22) traen ambos en
/// la misma pista; los `adaptiveFormats` de video son video-only. Sin esta
/// distinción, al activar "audio del video" caíamos en silencio.
@immutable
class VideoStreamInfo {
  const VideoStreamInfo({required this.url, required this.hasAudio});
  final String url;
  final bool hasAudio;
}

/// Resultado de búsqueda preformateado como [Song]. La `uri` queda como un
/// placeholder con scheme `ytmusic://${videoId}` — la URL real se resuelve
/// JIT en el momento de reproducir, porque las URLs de YouTube expiran.
@immutable
class StreamingTrack {
  const StreamingTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.album,
    required this.thumbnailUrl,
    this.durationMs,
    this.artistBrowseId,
    this.albumBrowseId,
  });

  final String videoId;
  final String title;
  final String artist;
  final String album;
  final String thumbnailUrl;
  final int? durationMs;
  final String? artistBrowseId;
  final String? albumBrowseId;

  Song toSong() => Song(
        id: 'yt:$videoId',
        title: title,
        artist: artist,
        album: album,
        uri: 'ytmusic://$videoId',
        durationMs: durationMs,
        streamingId: videoId,
        thumbnailUrl: thumbnailUrl,
        artistBrowseId: artistBrowseId,
        albumBrowseId: albumBrowseId,
      );
}

/// Sección horizontal estilo OpenTune (Music carousel shelf): un título +
/// una lista heterogénea de items. La interpretación de qué hacer con cada
/// item al tocarlo la decide la UI (canciones se reproducen; playlists/álbumes
/// abren browse — no implementado aún).
@immutable
class HomeShelf {
  const HomeShelf({
    required this.title,
    required this.items,
    this.moreBrowseId,
    this.moreParams,
  });

  final String title;
  final List<ShelfItem> items;

  /// `browseId` del endpoint "ver todo" del shelf (botón `More` del header
  /// en YT Music). Si está presente, el caller puede pedir el listado
  /// completo de items via `StreamingService.getShelfFull`.
  final String? moreBrowseId;

  /// `params` opaco que acompaña al `moreBrowseId` — YT Music los
  /// requiere juntos para que la response sea la lista correcta.
  final String? moreParams;
}

/// Item polimórfico de un shelf. Solo `kind == song` es reproducible
/// directamente — el resto se mostrarán como placeholders por ahora.
enum ShelfItemKind { song, album, playlist, artist }

@immutable
class ShelfItem {
  const ShelfItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.thumbnailUrl,
    this.streamingId, // solo para songs
    this.artistBrowseId,
    this.albumBrowseId,
  });

  final ShelfItemKind kind;
  final String id;
  final String title;
  final String subtitle;
  final String thumbnailUrl;
  final String? streamingId;

  /// browseId del artista (UC*) — extraído del run linkeado del subtitle.
  /// Permite que el subtitle sea clickeable para navegar al ArtistScreen.
  final String? artistBrowseId;

  /// browseId del álbum (MPREb_*) — análogo, para songs del shelf que
  /// linkean a su álbum.
  final String? albumBrowseId;
}

/// Capa "user-facing" sobre [YtMusicClient]:
///   - `search(query)` → lista de [StreamingTrack].
///   - `resolveStreamUrl(videoId)` → URL HTTPS lista para `just_audio`.
///   - `getHome()` → lista de [HomeShelf] (carruseles personalizados; mucho
///     más rico cuando hay sesión activa).
///   - `getLikedSongs()` → tus canciones marcadas con "Me gusta".
///   - `setAuth(...)` / `clearAuth()` → sincroniza la sesión con el cliente
///     HTTP subyacente.
class StreamingService {
  StreamingService([YtMusicClient? client])
      : _client = client ?? YtMusicClient();

  final YtMusicClient _client;

  /// Random compartido para el shuffle de items de shelves al recargar
  /// home. Sin semilla → seedea desde el system clock automáticamente,
  /// pero como instancia única no perdemos varianza al disparar varios
  /// shuffles cercanos en el tiempo.
  final math.Random _random = math.Random();

  bool get hasAuth => _client.auth?.isUsable ?? false;

  /// True si la sesión es UTILIZABLE Y COMPLETA (tiene todas las cookies
  /// críticas). Útil para detectar el caso "el usuario pegó solo SAPISID y
  /// guardamos una sesión que el server siempre va a rechazar con 401".
  bool get hasCompleteAuth => _client.auth?.isCompleteSession ?? false;

  /// Cookies críticas que faltan en la sesión actual (vacío si todo OK).
  List<String> get missingCookies =>
      _client.auth?.missingEssentialCookies ?? const [];

  /// Callback opcional que el cliente invoca cuando el access_token está
  /// expirado pero hay refresh_token. Lo registra el caller (típicamente
  /// `main.dart`) apuntando a una función que:
  ///   1. Llama a `YtOauthService.refresh(refreshToken)`
  ///   2. Persiste los nuevos tokens en settings
  ///   3. Construye un nuevo `YtMusicAuth` y lo devuelve
  ///
  /// Sin esto registrado, los tokens expirados producen 401 hasta que el
  /// usuario manualmente vuelva a entrar a la pantalla de login.
  set onAuthRefresh(Future<YtMusicAuth?> Function()? cb) {
    _client.onAuthRefresh = cb;
  }

  void setAuth(YtMusicAuth auth) {
    _client.auth = auth;
    // Cuando cambia la sesión invalidamos el cache de URLs — pueden depender
    // de personalización por usuario.
    _streamCache.clear();
    // Diag: cuántas variantes SAPISID detectamos. 0 = la cookie no tiene
    // ningún SAPISID/__Secure-?PAPISID → todas las requests irán como guest.
    final variants = auth.sapisidVariants.map((v) => v.prefix).toList();
    devLog('[YTM] auth set: usable=${auth.isUsable} '
        'variants=$variants '
        'bearer=${auth.hasValidBearer ? "valid" : (auth.hasRefreshToken ? "refreshable" : "no")} '
        'visitorData=${auth.visitorData != null ? "yes(${auth.visitorData!.length})" : "no"}');
  }

  void clearAuth() {
    _client.auth = null;
    _streamCache.clear();
  }

  Future<String?> fetchVisitorData() => _client.fetchVisitorData();

  /// Refresca visitorData + dataSyncId desde el HTML de music.youtube.com.
  /// El dataSyncId identifica al usuario logueado y es lo que activa
  /// personalización (Quick Picks, Volver a escuchar, etc).
  Future<({String? visitorData, String? dataSyncId})> fetchSessionIds() =>
      _client.fetchSessionIds();

  // Cache muy simple: videoId → (url, expiresAt).
  final _streamCache = <String, ({String url, DateTime expiresAt})>{};
  static const _cacheTtl = Duration(hours: 5);

  // -------- Cache de getEnrichedHome --------
  //
  // **Por qué existe**: sin esto, `LibraryScreen` re-entraba a
  // `_maybeLoadHome` cada vez que se reconstruía el state (cambio de tab,
  // unmount/remount, etc). Estando offline el endpoint fallaba CADA vez
  // → spam de "FAILED: SocketException Failed host lookup" en logcat,
  // batería gastada en reintentos inútiles.
  //
  // - TTL de 5min para resultado exitoso (cache hit no toca red).
  // - Backoff de 30s tras error de red: durante ese tiempo retornamos el
  //   cache (vacío o último éxito) sin tocar red.
  List<HomeShelf>? _enrichedHomeCache;
  DateTime? _enrichedHomeCacheTime;
  DateTime? _enrichedHomeLastError;
  static const _enrichedHomeTtl = Duration(minutes: 5);
  static const _enrichedHomeErrorBackoff = Duration(seconds: 30);

  /// Invalida el cache de enrichedHome — útil para el botón "Reintentar"
  /// del UI que debería forzar un fetch fresco.
  void clearEnrichedHomeCache() {
    _enrichedHomeCache = null;
    _enrichedHomeCacheTime = null;
    _enrichedHomeLastError = null;
  }

  // -------- Search --------

  Future<List<StreamingTrack>> search(String query, {String? filter}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final json = await _client.search(q, filter: filter);
    return _parseSearchResponse(json);
  }

  /// Búsqueda unificada que devuelve canciones, álbumes y artistas por separado.
  ///
  /// Los `params` filtran el tipo de resultado en YouTube Music — son cadenas
  /// base64 fijas usadas por todas las libs (ytmusicapi, OpenTune, etc.). El
  /// byte distintivo está en la posición ~7: `II` = songs, `IY` = albums,
  /// `Ig` = artists. Tener `Ih` (el bug previo) devolvía resultados vacíos.
  Future<
      ({
        List<Song> songs,
        List<ShelfItem> albums,
        List<ShelfItem> artists,
        List<Song> videos,
      })> searchUnified(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      return (
        songs: <Song>[],
        albums: <ShelfItem>[],
        artists: <ShelfItem>[],
        videos: <Song>[],
      );
    }

    // Filter bytes (posición 7 del base64): II=songs, IQ=videos, IY=albums,
    // Ig=artists. El sufijo `AWoKEAMQBBAJEAoQBQ%3D%3D` es el mismo para
    // todos — controla ordering/spellcheck ignoring del lado del server.
    const songsFilter = 'EgWKAQIIAWoKEAMQBBAJEAoQBQ%3D%3D';
    const videosFilter = 'EgWKAQIQAWoKEAMQBBAJEAoQBQ%3D%3D';
    const albumsFilter = 'EgWKAQIYAWoKEAMQBBAJEAoQBQ%3D%3D';
    const artistsFilter = 'EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D';

    final results = await Future.wait([
      search(q, filter: songsFilter),
      searchItems(q, filter: albumsFilter, requiredKind: ShelfItemKind.album),
      searchItems(q,
          filter: artistsFilter, requiredKind: ShelfItemKind.artist),
      search(q, filter: videosFilter),
    ]);

    return (
      songs:
          (results[0] as List<StreamingTrack>).map((t) => t.toSong()).toList(),
      albums: results[1] as List<ShelfItem>,
      artists: results[2] as List<ShelfItem>,
      videos:
          (results[3] as List<StreamingTrack>).map((t) => t.toSong()).toList(),
    );
  }

  /// Versión de search que devuelve ShelfItems (útil para álbumes y artistas).
  Future<List<ShelfItem>> searchItems(String query, {String? filter, ShelfItemKind? requiredKind}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final json = await _client.search(q, filter: filter);
    return _parseSearchItemsResponse(json, requiredKind: requiredKind);
  }

  List<ShelfItem> _parseSearchItemsResponse(Map<String, dynamic> root, {ShelfItemKind? requiredKind}) {
    final contents = _extractSearchContents(root);
    final out = <ShelfItem>[];
    for (final item in contents) {
      final si = _parseShelfItem(item);
      if (si != null) {
        if (requiredKind == null || si.kind == requiredKind) {
          out.add(si);
        }
      }
    }
    return out;
  }

  List<dynamic> _extractSearchContents(Map<String, dynamic> root) {
    final List<dynamic> contents = [];
    final tabs = _at(root, ['contents', 'tabbedSearchResultsRenderer', 'tabs']);
    if (tabs is List) {
      for (final tab in tabs) {
        final sectionList = _at(tab, ['tabRenderer', 'content', 'sectionListRenderer', 'contents']);
        if (sectionList is List) {
          for (final section in sectionList) {
            final shelf = _at(section, ['musicShelfRenderer', 'contents']) ??
                        _at(section, ['musicCardShelfRenderer', 'contents']);
            if (shelf is List) contents.addAll(shelf);
          }
        }
      }
    }
    return contents;
  }

  List<StreamingTrack> _parseSearchResponse(Map<String, dynamic> root) {
    final contents = _extractSearchContents(root);
    final out = <StreamingTrack>[];
    for (final item in contents) {
      final track = _parseTrackItem(item);
      if (track != null) out.add(track);
    }
    return out;
  }

  StreamingTrack? _parseTrackItem(dynamic item) {
    if (item is! Map) return null;

    final r = _at(item, ['musicResponsiveListItemRenderer']) ?? 
              _at(item, ['playlistPanelVideoRenderer']) ??
              _at(item, ['musicTwoRowItemRenderer']) ?? 
              _at(item, ['musicAlbumReleaseRenderer']) ??
              item; 
    
    if (r is! Map) return null;

    // 1. VideoId
    final videoId = (r['videoId'] as String?) ?? 
                    (_at(r, ['playlistItemData', 'videoId']) as String?) ??
                    (_at(r, ['navigationEndpoint', 'watchEndpoint', 'videoId']) as String?) ??
                    (_at(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'videoId']) as String?);
    
    if (videoId == null) return null;

    // 2. Title
    String? title;
    final titleObj = r['title'] ?? r['text'] ?? r['header'];
    if (titleObj is String) {
      title = titleObj;
    } else if (titleObj is Map) {
      title = _at(titleObj, ['runs', 0, 'text']) as String? ??
              _at(titleObj, ['simpleText']) as String?;
    }

    // 3. Metadata (Artist, Album, Duration)
    String artist = 'YouTube Music';
    String album = '—';
    int? durationMs;
    String? artistBrowseId;
    String? albumBrowseId;
    // El artista LINKED (texto cuyo browseId es UC*) gana sobre cualquier
    // candidato de texto plano — es la fuente más fiable. Si no hay UC,
    // caemos a candidatos filtrando play counts.
    String? linkedArtist;
    String? linkedAlbum;

    final flex = _at(r, ['flexColumns']);
    if (flex is List) {
      final candidates = <String>[]; // runs que no son metadata de YT (no play count, no duración, no "Song"/"Album"/...)
      for (var i = 0; i < flex.length; i++) {
        final col = _at(flex[i],
            ['musicResponsiveListItemFlexColumnRenderer', 'text', 'runs']);
        if (col is! List) continue;
        for (final run in col) {
          final text = _at(run, ['text']);
          if (text is! String) continue;
          if (i == 0 && title == null) {
            title = text;
            continue;
          }
          if (i == 0) continue;
          final trimmed = text.trim();
          if (trimmed.isEmpty || trimmed == '•') continue;

          final bId = _at(run,
              ['navigationEndpoint', 'browseEndpoint', 'browseId']) as String?;
          if (bId != null) {
            if (bId.startsWith('UC')) {
              artistBrowseId = bId;
              linkedArtist ??= text;
              continue; // texto linked al artista → no es candidato genérico
            }
            if (bId.startsWith('MPREb_')) {
              albumBrowseId = bId;
              linkedAlbum ??= text;
              continue;
            }
          }

          final maybeDur = _parseDuration(text);
          if (maybeDur != null) {
            durationMs = maybeDur;
            continue;
          }

          // Filtra "Song"/"Album"/"Video" (etiquetas de tipo) y play counts
          // tipo "5.4M reproducciones" o "1.2K plays".
          if (_isTypeLabel(trimmed)) continue;
          if (_looksLikePlayCount(trimmed)) continue;

          candidates.add(text);
        }
      }

      if (linkedArtist != null) {
        artist = linkedArtist;
      } else if (candidates.isNotEmpty) {
        artist = candidates[0];
      }
      if (linkedAlbum != null) {
        album = linkedAlbum;
      } else if (candidates.length > 1) {
        album = candidates[1];
      }
    } else {
      // Fallback para otros renderers (como playlistPanelVideoRenderer)
      final byline =
          _at(r, ['longBylineText', 'runs']) ?? _at(r, ['shortBylineText', 'runs']);
      if (byline is List) {
        for (final run in byline) {
          final text = run['text'] as String?;
          if (text == null || text.trim() == '•') continue;
          final bId = _at(run,
              ['navigationEndpoint', 'browseEndpoint', 'browseId']) as String?;
          if (bId != null) {
            if (bId.startsWith('UC')) {
              artistBrowseId = bId;
              linkedArtist ??= text;
              continue;
            }
            if (bId.startsWith('MPREb_')) {
              albumBrowseId = bId;
              linkedAlbum ??= text;
              continue;
            }
          }
          final maybeDur = _parseDuration(text);
          if (maybeDur != null) {
            durationMs = maybeDur;
            continue;
          }
          if (_isTypeLabel(text) || _looksLikePlayCount(text)) continue;
          if (artist == 'YouTube Music') {
            artist = text;
          } else if (album == '—') {
            album = text;
          }
        }
      }
      if (linkedArtist != null) artist = linkedArtist;
      if (linkedAlbum != null) album = linkedAlbum;
    }

    if (title == null) return null;

    // 4. Thumbnail
    final thumbs = _at(r, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']) ??
                   _at(r, ['thumbnail', 'thumbnails']) ??
                   _at(r, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']);
    final thumbUrl = _bestThumbnail(thumbs);

    return StreamingTrack(
      videoId: videoId,
      title: title,
      artist: artist,
      album: album,
      thumbnailUrl: thumbUrl ?? '',
      durationMs: durationMs,
      artistBrowseId: artistBrowseId,
      albumBrowseId: albumBrowseId,
    );
  }

  // -------- Album / Artist Details --------

  /// Tipos de renderer de header que YT Music puede devolver para álbumes,
  /// EPs, singles, playlists y compilaciones. Los probamos en orden y caemos
  /// a búsqueda recursiva si ninguno aparece en el path estándar.
  ///
  /// `musicResponsiveHeaderRenderer` es el formato NUEVO (2024+) — guarda el
  /// artista en `straplineTextOne.runs` en lugar de `subtitle.runs`. Sin
  /// soportarlo, el headerArtist quedaba null y caíamos al "YouTube Music"
  /// por defecto del parser de track.
  static const _albumHeaderKeys = [
    'musicResponsiveHeaderRenderer',
    'musicDetailHeaderRenderer',
    'musicImmersiveHeaderRenderer',
    'musicVisualHeaderRenderer',
    'musicEditablePlaylistDetailHeaderRenderer',
  ];

  Future<({String title, String subtitle, String thumb, List<StreamingTrack> tracks})?> getAlbumDetails(String browseId) async {
    try {
      final json = await _client.browse(browseId: browseId);

      dynamic header;
      String? headerType;
      for (final key in _albumHeaderKeys) {
        final h = _at(json, ['header', key]);
        if (h != null) {
          header = h;
          headerType = key;
          break;
        }
      }
      // Si no está en `header.*`, búsqueda recursiva — algunos endpoints
      // ponen el renderer dentro de `contents` o `secondaryContents`.
      if (header == null) {
        for (final key in _albumHeaderKeys) {
          final h = _findKeyRecursive(json, key);
          if (h != null) {
            header = h;
            headerType = key;
            break;
          }
        }
      }

      if (header == null) {
        devLog('[YTM] album $browseId → no header found, emergency parse');
        return _emergencyAlbumParse(json, browseId);
      }
      devLog('[YTM] album $browseId → header type: $headerType');
      return _parseAlbumFromHeader(header, json, browseId);
    } catch (e) {
      devLog('[YTM] getAlbumDetails error: $e');
      return null;
    }
  }

  /// Extrae el nombre + browseId del artista a partir de un header de álbum.
  /// Cubre los 3 layouts que YT Music usa hoy:
  ///   - `subtitle.runs` (musicDetailHeaderRenderer clásico).
  ///   - `straplineTextOne.runs` (musicResponsiveHeaderRenderer nuevo).
  ///   - `secondSubtitle.runs` (algunos compilados).
  ///
  /// Prioriza el run con browseId UC* (link real al artista). Si no, cae al
  /// primer texto que no sea etiqueta de tipo, año o play count.
  ({String? name, String? browseId}) _extractHeaderArtist(dynamic header) {
    final candidates = <List>[
      _at(header, ['subtitle', 'runs']) ?? const [],
      _at(header, ['straplineTextOne', 'runs']) ?? const [],
      _at(header, ['secondSubtitle', 'runs']) ?? const [],
    ].whereType<List>().expand((l) => l).toList();

    if (candidates.isEmpty) return (name: null, browseId: null);

    // Prioridad 1: cualquier run con UC* browseId (link real al artista).
    for (final run in candidates) {
      final text = _at(run, ['text']);
      if (text is! String) continue;
      final bId = _at(run, ['navigationEndpoint', 'browseEndpoint', 'browseId'])
          as String?;
      if (bId != null && bId.startsWith('UC')) {
        return (name: text, browseId: bId);
      }
    }

    // Prioridad 2: primer texto descartando ruido.
    for (final run in candidates) {
      final text = _at(run, ['text']);
      if (text is! String) continue;
      final t = text.trim();
      if (t.isEmpty || t == '•') continue;
      if (_isTypeLabel(t)) continue;
      if (RegExp(r'^\d{4}$').hasMatch(t)) continue;
      if (_looksLikePlayCount(t)) continue;
      return (name: text, browseId: null);
    }

    return (name: null, browseId: null);
  }

  ({String title, String subtitle, String thumb, List<StreamingTrack> tracks})? _emergencyAlbumParse(Map<String, dynamic> json, String browseId) {
    // Buscamos cualquier cosa que parezca un título
    final titleCandidate = _findKeyRecursive(json, 'title');
    String title = 'Álbum Desconocido';
    if (titleCandidate is Map) {
      title = _at(titleCandidate, ['runs', 0, 'text']) ?? _at(titleCandidate, ['simpleText']) ?? title;
    } else if (titleCandidate is String) {
      title = titleCandidate;
    }

    final List<dynamic> shelfContents = [];
    _findTracksRecursive(json, shelfContents);

    if (shelfContents.isEmpty) return null;

    // REFINAMIENTO: Buscamos la mejor carátula posible pero con un filtro de "calidad"
    // para no agarrar fotos de artistas.
    final thumb = _scavengeThumbnail(json) ?? '';

    // Aunque entremos por el path de emergencia, todavía intentamos sacar el
    // artista buscando recursivamente un header reconocible. Sin esto, las
    // pistas se quedaban con el 'YouTube Music' por defecto cuando el album
    // no tenía header en el path esperado.
    String? emergencyHeaderArtist;
    String? emergencyHeaderArtistBrowseId;
    for (final key in _albumHeaderKeys) {
      final h = _findKeyRecursive(json, key);
      if (h == null) continue;
      final info = _extractHeaderArtist(h);
      if (info.name != null) {
        emergencyHeaderArtist = info.name;
        emergencyHeaderArtistBrowseId = info.browseId;
        break;
      }
    }

    final tracks = <StreamingTrack>[];
    final seen = <String>{};
    for (final item in shelfContents) {
      final t = _parseTrackItem(item);
      if (t != null && !seen.contains(t.videoId)) {
        seen.add(t.videoId);
        final resolvedArtist =
            t.artist == 'YouTube Music' && emergencyHeaderArtist != null
                ? emergencyHeaderArtist
                : t.artist;
        tracks.add(StreamingTrack(
          videoId: t.videoId,
          title: t.title,
          artist: resolvedArtist,
          album: title,
          thumbnailUrl: t.thumbnailUrl.isEmpty ? thumb : t.thumbnailUrl,
          durationMs: t.durationMs,
          artistBrowseId: t.artistBrowseId ?? emergencyHeaderArtistBrowseId,
          albumBrowseId: browseId,
        ));
      }
    }

    if (tracks.isEmpty) return null;

    return (
      title: title,
      subtitle: emergencyHeaderArtist ?? tracks.first.artist,
      thumb: thumb.isEmpty ? tracks.first.thumbnailUrl : thumb,
      tracks: tracks
    );
  }

  ({String title, String subtitle, String thumb, List<StreamingTrack> tracks}) _parseAlbumFromHeader(dynamic header, Map<String, dynamic> fullJson, String browseId) {
    final title = _at(header, ['title', 'runs', 0, 'text']) as String? ??
                  _at(header, ['title', 'simpleText']) as String? ?? 'Álbum';

    // Subtitle textual (Album • Artist • 2024) — para mostrar bajo el título
    // de la card del álbum. Concatenamos los runs si existen, o caemos al
    // straplineTextOne si es el formato responsive nuevo.
    final subtitleRuns = _at(header, ['subtitle', 'runs']);
    final straplineRuns = _at(header, ['straplineTextOne', 'runs']);
    final subtitle = subtitleRuns is List
        ? subtitleRuns.map((r) => r['text']).join('')
        : straplineRuns is List
            ? straplineRuns.map((r) => r['text']).join('')
            : '';

    // Artista del header: usamos el helper que ya cubre los 3 layouts
    // (subtitle, straplineTextOne, secondSubtitle) y prioriza UC* links.
    final headerArtistInfo = _extractHeaderArtist(header);
    final headerArtist = headerArtistInfo.name;
    final headerArtistBrowseId = headerArtistInfo.browseId;
    devLog('[YTM] album header artist: $headerArtist '
        '(browseId: $headerArtistBrowseId)');
        
    final thumb = _bestThumbnail(_at(header, ['thumbnail', 'croppedSquareThumbnailRenderer', 'thumbnail', 'thumbnails'])) ?? 
                  _bestThumbnail(_at(header, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])) ?? 
                  _bestThumbnail(_at(header, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])) ??
                  _scavengeThumbnail(header) ?? '';

    // PRIORIDAD: Buscar contenedores de tracks conocidos
    final List<dynamic> shelfContents = [];
    
    final shelf = _findKeyRecursive(fullJson, 'musicPlaylistShelfRenderer') ??
                  _findKeyRecursive(fullJson, 'musicShelfRenderer');
    
    if (shelf != null && shelf['contents'] is List) {
      shelfContents.addAll(shelf['contents'] as List);
    } else {
      _findTracksRecursive(fullJson, shelfContents);
    }

    final tracks = <StreamingTrack>[];
    // Evitar duplicados (por videoId)
    final seen = <String>{};

    for (final item in shelfContents) {
      final t = _parseTrackItem(item);
      if (t != null && !seen.contains(t.videoId)) {
        seen.add(t.videoId);
        // Fallback de artist: si el parser de track no detectó un nombre
        // (queda en 'YouTube Music' por defecto), usamos el del header del
        // álbum — en respuestas de álbum las filas suelen omitir al artista
        // porque ya está en el header.
        final resolvedArtist =
            t.artist == 'YouTube Music' && headerArtist != null
                ? headerArtist
                : t.artist;
        tracks.add(StreamingTrack(
          videoId: t.videoId,
          title: t.title,
          artist: resolvedArtist,
          album: title,
          thumbnailUrl: t.thumbnailUrl.isEmpty ? thumb : t.thumbnailUrl,
          durationMs: t.durationMs,
          artistBrowseId: t.artistBrowseId ?? headerArtistBrowseId,
          albumBrowseId: browseId,
        ));
      }
    }
    
    return (title: title, subtitle: subtitle, thumb: thumb, tracks: tracks);
  }

  dynamic _findKeyRecursive(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final v in node.values) {
        final found = _findKeyRecursive(v, key);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final i in node) {
        final found = _findKeyRecursive(i, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  void _findTracksRecursive(dynamic node, List<dynamic> out) {
    if (node is Map) {
      if (node.containsKey('musicResponsiveListItemRenderer')) {
        out.add(node['musicResponsiveListItemRenderer']);
      } else if (node.containsKey('playlistPanelVideoRenderer')) {
        out.add(node['playlistPanelVideoRenderer']);
      } else if (node.containsKey('videoId') && (node.containsKey('title') || node.containsKey('text'))) {
        out.add(node);
      }
      
      // Siempre continuamos recursando para asegurar que encontramos TODOS los tracks,
      // incluso si están en ramas paralelas o anidadas.
      for (final v in node.values) {
        _findTracksRecursive(v, out);
      }
    } else if (node is List) {
      for (final i in node) {
        _findTracksRecursive(i, out);
      }
    }
  }

  Future<({String name, String thumb, List<HomeShelf> shelves})?> getArtistDetails(String browseId) async {
    final json = await _client.browse(browseId: browseId);
    
    final header = _at(json, ['header', 'musicImmersiveHeaderRenderer']);
    final name = _at(header, ['title', 'runs', 0, 'text']) as String? ?? 'Artista';
    final thumb = _bestThumbnail(_at(header, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails'])) ?? '';

    final shelves = _parseShelves(json);
    
    return (name: name, thumb: thumb, shelves: shelves);
  }

  // -------- Home / personal library --------

  /// Carruseles del home: "Listen again", "Quick picks", "Mixed for you", etc.
  /// Sin sesión devuelve solo trending genérico; con sesión, contenido
  /// personalizado.
  Future<List<HomeShelf>> getHome() async {
    final json = await _client.browse(browseId: 'FEmusic_home');
    return _parseShelves(json);
  }

  /// Historial de escucha — `FEmusic_history`. Es la mejor fuente para una
  /// fila "Listen again" garantizada cuando el home oficial no la incluye.
  /// Devuelve los shelves tal como los entrega YT Music (suelen agruparse
  /// por día: "Today", "Yesterday", "This week", etc.).
  Future<List<HomeShelf>> getHistory() async {
    final json = await _client.browse(browseId: 'FEmusic_history');
    return _parseShelves(json);
  }

  /// Landing de "Library" — playlists, álbumes guardados, suscripciones a
  /// artistas. Útil para mostrar "Tu biblioteca" como shelf en el home.
  Future<List<HomeShelf>> getLibraryLanding() async {
    final json = await _client.browse(browseId: 'FEmusic_library_landing');
    return _parseShelves(json);
  }

  /// Combina home + history + library en una sola lista de shelves. Útil para
  /// la página de Inicio: garantiza que "Listen again" / actividad reciente
  /// aparezca aunque YT Music no la incluya en el home oficial ese día.
  ///
  /// Estrategia:
  ///   1. Pide los 3 endpoints en paralelo. Falla parcialmente sin tirar
  ///      todo (si history requiere auth y no hay sesión, se ignora).
  ///   2. Empieza con los shelves del home (que ya pueden traer Listen again).
  ///   3. Si NO había Listen again en home, prepende el primer shelf de
  ///      history como "Escucha de nuevo".
  ///   4. Añade al final shelves de library no duplicados por título.
  /// Devuelve las "siguientes" canciones recomendadas a partir del
  /// videoId dado — el equivalente al panel "Up next" de YT Music que se
  /// usa para autoplay. Combina canciones similares (radio del track),
  /// mezclas relacionadas y el algoritmo de recomendación del usuario.
  ///
  /// Útil para llenar el queue cuando el usuario reproduce solo 1 canción:
  /// en vez de quedarse con esa sola, automáticamente cola ~25 más del
  /// mismo "ambiente" sin necesidad de elegirlas manualmente.
  ///
  /// Devuelve lista vacía si el endpoint falla (red, auth, etc.) — el
  /// caller debe seguir funcionando con el queue de 1 sola canción.
  Future<List<StreamingTrack>> getRecommendedQueue(String videoId) async {
    try {
      final json = await _client.next(videoId: videoId);
      // El panel de la cola vive en una ubicación profunda dependiendo de
      // si es single-column (mobile/desktop modern) o legacy. Hacemos un
      // sweep recursivo buscando `playlistPanelVideoRenderer` que es el
      // wrapper de cada track del panel "Up next".
      final renderers = <dynamic>[];
      _findAllKeys(json, 'playlistPanelVideoRenderer', renderers);
      final out = <StreamingTrack>[];
      final seen = <String>{};
      for (final r in renderers) {
        if (r is! Map) continue;
        final track = _fromPlaylistPanelVideo(r);
        if (track == null) continue;
        if (track.videoId == videoId) continue; // skip la canción semilla
        if (seen.add(track.videoId)) out.add(track);
      }
      devLog('[YTM] getRecommendedQueue($videoId) → ${out.length} tracks');
      return out;
    } catch (e) {
      devLog('[YTM] getRecommendedQueue($videoId) failed: $e');
      return const [];
    }
  }

  /// Parsea un `playlistPanelVideoRenderer` a [StreamingTrack].
  /// Extrae title, artist, album, duration, thumbnailUrl.
  StreamingTrack? _fromPlaylistPanelVideo(Map r) {
    final videoId = _at(r, ['videoId']) as String?;
    if (videoId == null || videoId.isEmpty) return null;
    final title = _at(r, ['title', 'runs', 0, 'text']) as String? ??
        _at(r, ['title', 'simpleText']) as String?;
    if (title == null || title.isEmpty) return null;

    // longBylineText combina artist · album · year — extraemos el primer
    // run con browseId (que es el artist) y el segundo con browseId (album).
    String? artist;
    String? album;
    String? artistBrowseId;
    String? albumBrowseId;
    final runs = _at(r, ['longBylineText', 'runs']);
    if (runs is List) {
      for (final run in runs) {
        if (run is! Map) continue;
        final text = run['text'] as String?;
        if (text == null || text.trim() == '•' || text.trim().isEmpty) {
          continue;
        }
        final bid = _at(run, [
          'navigationEndpoint',
          'browseEndpoint',
          'browseId',
        ]) as String?;
        if (bid != null && bid.startsWith('UC')) {
          artist ??= text;
          artistBrowseId ??= bid;
        } else if (bid != null && bid.startsWith('MPRE')) {
          album ??= text;
          albumBrowseId ??= bid;
        } else if (artist == null) {
          artist = text;
        } else {
          album ??= text;
        }
      }
    }
    artist ??= 'YouTube Music';

    final thumbs = _at(r, ['thumbnail', 'thumbnails']);
    final thumb = _bestThumbnail(thumbs) ?? '';

    final lengthStr = _at(r, ['lengthText', 'runs', 0, 'text']) as String? ??
        _at(r, ['lengthText', 'simpleText']) as String?;
    int? durationMs;
    if (lengthStr != null) {
      final parts = lengthStr.split(':');
      if (parts.length == 2) {
        final mm = int.tryParse(parts[0]);
        final ss = int.tryParse(parts[1]);
        if (mm != null && ss != null) durationMs = (mm * 60 + ss) * 1000;
      } else if (parts.length == 3) {
        final hh = int.tryParse(parts[0]);
        final mm = int.tryParse(parts[1]);
        final ss = int.tryParse(parts[2]);
        if (hh != null && mm != null && ss != null) {
          durationMs = (hh * 3600 + mm * 60 + ss) * 1000;
        }
      }
    }

    return StreamingTrack(
      videoId: videoId,
      title: title,
      artist: artist,
      album: album ?? '',
      thumbnailUrl: thumb,
      durationMs: durationMs,
      artistBrowseId: artistBrowseId,
      albumBrowseId: albumBrowseId,
    );
  }

  Future<List<HomeShelf>> getEnrichedHome() async {
    final now = DateTime.now();
    // Cache hit dentro del TTL → no tocamos red.
    if (_enrichedHomeCache != null &&
        _enrichedHomeCacheTime != null &&
        now.difference(_enrichedHomeCacheTime!) < _enrichedHomeTtl) {
      return _enrichedHomeCache!;
    }
    // Estamos en backoff post-error: el último intento falló por red hace
    // menos de 30s. Devolver lo que tengamos en cache sin reintentar.
    if (_enrichedHomeLastError != null &&
        now.difference(_enrichedHomeLastError!) <
            _enrichedHomeErrorBackoff) {
      return _enrichedHomeCache ?? const <HomeShelf>[];
    }

    var sawNetworkError = false;
    Future<List<HomeShelf>> safeFetch(
        String name, Future<List<HomeShelf>> Function() fn) async {
      try {
        final s = await fn();
        devLog('[YTM] $name → ${s.length} shelves: '
            '${s.map((x) => x.title).join(", ")}');
        return s;
      } catch (e) {
        // Silenciamos el log para errores de red conocidos (SocketException,
        // host lookup). El primer error sí queda registrado en el campo
        // `_enrichedHomeLastError` y el debugPrint del siguiente bloque
        // → no necesitamos 3 líneas idénticas en logcat.
        final isNet = e.toString().contains('SocketException') ||
            e.toString().contains('Failed host lookup') ||
            e.toString().contains('Network is unreachable');
        if (isNet) {
          sawNetworkError = true;
        } else {
          devLog('[YTM] $name FAILED: $e');
        }
        return <HomeShelf>[];
      }
    }

    final results = await Future.wait([
      safeFetch('home', getHome),
      safeFetch('history', getHistory),
      safeFetch('library', getLibraryLanding),
    ]);

    if (sawNetworkError) {
      _enrichedHomeLastError = DateTime.now();
      devLog(
          '[YTM] enrichedHome offline — backoff ${_enrichedHomeErrorBackoff.inSeconds}s');
    }

    final homeShelves = results[0];
    final historyShelves = results[1];
    final libraryShelves = results[2];

    final out = <HomeShelf>[];
    final seenTitles = <String>{};

    bool hasListenAgain(List<HomeShelf> shelves) => shelves.any((s) {
          final t = s.title.toLowerCase();
          return t.contains('listen again') ||
              t.contains('escucha de nuevo') ||
              t.contains('escucha esto otra vez');
        });

    // Si home no trae Listen again y history sí, prepende el primer shelf
    // de history (suele ser "Today" o el más reciente) renombrado.
    if (!hasListenAgain(homeShelves) && historyShelves.isNotEmpty) {
      final first = historyShelves.first;
      out.add(HomeShelf(title: 'Escucha de nuevo', items: first.items));
      seenTitles.add('escucha de nuevo');
    }

    for (final s in homeShelves) {
      final key = s.title.toLowerCase();
      if (seenTitles.add(key)) out.add(s);
    }

    for (final s in libraryShelves) {
      final key = s.title.toLowerCase();
      if (seenTitles.add(key)) out.add(s);
    }

    // Shuffle de items DENTRO de cada shelf antes de cachear → cada
    // fetch fresco le da al usuario una rotación distinta de "música
    // diferente en el slider" sin alterar el orden de los shelves
    // (Listen again sigue primero, etc.) ni borrar nada. Como solo
    // shuffleamos en el momento del fetch, la cache mantiene una orden
    // estable durante el TTL — no hay re-shuffle al scrollear o cambiar
    // de tab. Próximo pull-to-refresh genera un orden nuevo.
    //
    // `_random` se inicializa una vez (init seed con dart:math.Random
    // sin semilla = depende del system clock). Si shuffleamos creando
    // un nuevo Random() por shelf, varios fetch en mismo ms compartían
    // estado interno y daban shuffles idénticos.
    final shuffled = out
        .map((s) => HomeShelf(
              title: s.title,
              items: List<ShelfItem>.from(s.items)..shuffle(_random),
              moreBrowseId: s.moreBrowseId,
              moreParams: s.moreParams,
            ))
        .toList();

    // Solo cacheamos si tuvimos al menos UN éxito. Si todo falló, dejamos
    // el cache anterior intacto (sirve como "stale-while-revalidate") y el
    // backoff se encarga de no machacar la red por 30s.
    if (shuffled.isNotEmpty) {
      _enrichedHomeCache = shuffled;
      _enrichedHomeCacheTime = DateTime.now();
      _enrichedHomeLastError = null;
    }
    return shuffled;
  }

  /// Tus canciones marcadas con "Me gusta" en YouTube Music. Requiere
  /// sesión.
  Future<List<StreamingTrack>> getLikedSongs() async {
    final json = await _client.browse(browseId: 'FEmusic_liked_videos');
    return _parseLikedSongs(json);
  }

  /// Encuentra y parsea TODOS los shelves del response.
  ///
  /// La estructura varía mucho entre endpoints (FEmusic_home,
  /// FEmusic_history, FEmusic_library_landing) y entre layouts (single/two
  /// column). Antes solo caminábamos `tabs[0]` de singleColumn/twoColumn → si
  /// el contenido vivía en otra tab o en `secondaryContents`, lo perdíamos
  /// silenciosamente.
  ///
  /// Estrategia robusta:
  ///   1. Recolectar **todos** los nodos `sectionListRenderer` del response
  ///      via búsqueda recursiva.
  ///   2. Para cada uno, iterar sus `contents` e intentar parsear cada
  ///      sección como shelf.
  ///   3. Dedupe por título (primer ocurrencia gana — preserva orden).
  List<HomeShelf> _parseShelves(Map<String, dynamic> root) {
    final sectionLists = <dynamic>[];
    _findAllKeys(root, 'sectionListRenderer', sectionLists);

    final out = <HomeShelf>[];
    final seen = <String>{};
    for (final sl in sectionLists) {
      final contents = _at(sl, ['contents']);
      if (contents is! List) continue;
      for (final section in contents) {
        final shelf = _parseCarouselShelf(section);
        if (shelf == null) continue;
        if (seen.add(shelf.title)) out.add(shelf);
      }
    }
    return out;
  }

  /// Acumula en `out` todos los valores de las keys con nombre `key`
  /// encontradas recursivamente bajo `node`. Útil cuando un mismo tipo de
  /// renderer aparece en múltiples ramas.
  void _findAllKeys(dynamic node, String key, List<dynamic> out) {
    if (node is Map) {
      if (node.containsKey(key)) out.add(node[key]);
      for (final v in node.values) {
        _findAllKeys(v, key, out);
      }
    } else if (node is List) {
      for (final i in node) {
        _findAllKeys(i, key, out);
      }
    }
  }

  HomeShelf? _parseCarouselShelf(dynamic section) {
    // YouTube Music usa 4 renderers principales para shelves del home:
    //   - musicCarouselShelfRenderer: carrusel horizontal (Volver a escuchar,
    //     Favoritos olvidados, Mixed for you, etc.).
    //   - musicImmersiveCarouselShelfRenderer: variante con bg image grande.
    //   - musicShelfRenderer: vertical/grid (Selección rápida / Quick picks).
    //   - musicCardShelfRenderer: single card destacada (raro en home).
    // Antes solo parseábamos los 2 primeros → "Selección rápida" y similares
    // desaparecían silenciosamente.
    final renderer = _at(section, ['musicCarouselShelfRenderer']) ??
        _at(section, ['musicImmersiveCarouselShelfRenderer']) ??
        _at(section, ['musicShelfRenderer']) ??
        _at(section, ['musicCardShelfRenderer']);
    if (renderer == null) return null;

    // El título puede venir en varios contenedores según el tipo de shelf.
    final title = _at(renderer, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          'title',
          'runs',
          0,
          'text',
        ]) as String? ??
        // musicShelfRenderer pone el título directo en `title.runs[0].text`.
        _at(renderer, ['title', 'runs', 0, 'text']) as String? ??
        _at(renderer, ['title', 'simpleText']) as String? ??
        // musicCardShelfRenderer puede tener subtitle en lugar de title.
        _at(renderer, ['header', 'musicCardShelfHeaderBasicRenderer', 'title',
          'runs', 0, 'text']) as String?;

    final contents = _at(renderer, ['contents']);
    if (contents is! List) return null;

    final items = <ShelfItem>[];
    for (final entry in contents) {
      final i = _parseShelfItem(entry);
      if (i != null) items.add(i);
    }
    if (items.isEmpty) return null;

    // "Ver todo" del shelf: el header puede traer un botón `More` con un
    // endpoint browseEndpoint. Lo extraemos para que el caller pueda
    // pedir la lista COMPLETA (sin esto, "Ver todo" solo mostraba los
    // ~10 items que YT devuelve en el shelf del artista, no los 30+
    // álbumes/singles totales).
    //
    // YT Music ubica este endpoint en varios lugares según el tipo de
    // shelf y la página — probamos todos.
    final candidatePaths = <List<dynamic>>[
      // musicCarouselShelfRenderer en artist pages.
      [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'moreContentButton',
        'buttonRenderer',
        'navigationEndpoint',
        'browseEndpoint',
      ],
      // Variante en home pages (a veces el header está envuelto distinto).
      [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        'endpoint',
        'browseEndpoint',
      ],
      // musicShelfRenderer (vertical/grid) con endpoint en el title.
      [
        'title',
        'runs',
        0,
        'navigationEndpoint',
        'browseEndpoint',
      ],
      // Botón "Más" en el bottom del renderer (algunos shelves).
      [
        'bottomEndpoint',
        'browseEndpoint',
      ],
    ];
    String? moreBrowseId;
    String? moreParams;
    for (final path in candidatePaths) {
      final ep = _at(renderer, path);
      if (ep is Map) {
        final bid = _at(ep, ['browseId']);
        final p = _at(ep, ['params']);
        if (bid is String && bid.isNotEmpty) {
          moreBrowseId = bid;
          if (p is String && p.isNotEmpty) moreParams = p;
          break;
        }
      }
    }

    return HomeShelf(
      title: title ?? 'Para ti',
      items: items,
      moreBrowseId: moreBrowseId,
      moreParams: moreParams,
    );
  }

  /// Pide la lista COMPLETA de items de un shelf usando el `moreBrowseId`
  /// + `params` que vienen del botón "Ver todo" del header del carousel
  /// en la página de artista. Sin esto, los carruseles del artista solo
  /// muestran ~10 items aunque haya 30+ álbumes reales.
  ///
  /// La página de "Ver todo" usa renderers distintos al carrusel
  /// (`gridRenderer` con `musicTwoRowItemRenderer`, o
  /// `musicShelfRenderer` con `musicResponsiveListItemRenderer`).
  /// `_parseShelves` puede no detectar todos los items porque busca
  /// `sectionListRenderer` y la página puede no estar envuelta en uno.
  ///
  /// Estrategia robusta: barrido recursivo del JSON entero buscando
  /// CUALQUIER `musicTwoRowItemRenderer` o `musicResponsiveListItemRenderer`,
  /// los parseamos individualmente y dedupeamos. Esto detecta todos los
  /// items sin importar dónde estén anidados.
  Future<List<ShelfItem>> getShelfFull(String browseId, String? params) async {
    devLog('[YTM] getShelfFull browseId=$browseId params=$params');
    final json = await _client.browse(browseId: browseId, params: params);

    // Barrido agresivo: encontrar TODOS los renderers de items en
    // cualquier parte del JSON.
    final twoRow = <dynamic>[];
    final listItems = <dynamic>[];
    _findAllKeys(json, 'musicTwoRowItemRenderer', twoRow);
    _findAllKeys(json, 'musicResponsiveListItemRenderer', listItems);
    devLog('[YTM] getShelfFull renderers '
        'twoRow=${twoRow.length} list=${listItems.length}');

    final seen = <String>{};
    final out = <ShelfItem>[];
    void addIfUnique(ShelfItem? item) {
      if (item == null) return;
      final key = '${item.kind.name}:${item.id}';
      if (seen.add(key)) out.add(item);
    }
    for (final r in twoRow) {
      if (r is Map) addIfUnique(_fromTwoRowItem(r));
    }
    for (final r in listItems) {
      if (r is Map) addIfUnique(_fromResponsiveListItem(r));
    }
    devLog('[YTM] getShelfFull → ${out.length} items totales');
    return out;
  }

  ShelfItem? _parseShelfItem(dynamic entry) {
    // Caso 1: musicTwoRowItemRenderer (cards grandes con thumbnail cuadrado).
    final two = _at(entry, ['musicTwoRowItemRenderer']);
    if (two != null) return _fromTwoRowItem(two);

    // Caso 2: musicResponsiveListItemRenderer (filas tipo lista de canciones).
    final list = _at(entry, ['musicResponsiveListItemRenderer']);
    if (list != null) return _fromResponsiveListItem(list);

    return null;
  }

  /// Extrae un subtitle LIMPIO de los runs de un shelf item — descarta
  /// etiquetas de tipo ("Song"/"Video"/"Album"), play counts ("5.4M reproducciones"),
  /// años ("2024") y separadores ("•"). Prefiere el run con browseId UC*
  /// (link real al artista) si existe.
  ///
  /// También devuelve los browseIds (UC para artista, MPREb_ para álbum) si
  /// los encuentra — la UI los necesita para que el subtitle sea clickeable
  /// y navegue al artista/álbum correspondiente.
  ({String subtitle, String? artistBrowseId, String? albumBrowseId})
      _cleanArtistSubtitle(List runs) {
    String? artistName;
    String? artistBrowseId;
    String? albumBrowseId;
    final clean = <String>[];

    for (final run in runs) {
      final text = _at(run, ['text']);
      if (text is! String) continue;
      final t = text.trim();
      if (t.isEmpty || t == '•') continue;

      final bId = _at(run,
          ['navigationEndpoint', 'browseEndpoint', 'browseId']) as String?;
      if (bId != null) {
        if (bId.startsWith('UC') && artistName == null) {
          artistName = t;
          artistBrowseId = bId;
          continue;
        }
        if (bId.startsWith('MPREb_') && albumBrowseId == null) {
          albumBrowseId = bId;
          // El álbum también va al subtitle (después del artista).
          clean.add(t);
          continue;
        }
      }

      if (_isTypeLabel(t)) continue;
      if (_looksLikePlayCount(t)) continue;
      if (RegExp(r'^\d{4}$').hasMatch(t)) continue;
      clean.add(t);
    }

    final subtitle = artistName ?? clean.join(' · ');

    return (
      subtitle: subtitle,
      artistBrowseId: artistBrowseId,
      albumBrowseId: albumBrowseId,
    );
  }

  ShelfItem? _fromTwoRowItem(Map two) {
    final title = _at(two, ['title', 'runs', 0, 'text']) as String?;
    final subRuns = _at(two, ['subtitle', 'runs']);
    final sub = subRuns is List
        ? _cleanArtistSubtitle(subRuns)
        : (subtitle: '', artistBrowseId: null, albumBrowseId: null);
    final thumbs = _at(two, [
      'thumbnailRenderer',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]);
    final thumbUrl = _bestThumbnail(thumbs);

    final videoId = _at(two, [
      'navigationEndpoint',
      'watchEndpoint',
      'videoId',
    ]) as String?;
    final browseId = _at(two, [
      'navigationEndpoint',
      'browseEndpoint',
      'browseId',
    ]) as String?;

    if (title == null) return null;

    if (videoId != null && browseId == null) {
      return ShelfItem(
        kind: ShelfItemKind.song,
        id: videoId,
        streamingId: videoId,
        title: title,
        subtitle: sub.subtitle,
        thumbnailUrl: thumbUrl ?? '',
        artistBrowseId: sub.artistBrowseId,
        albumBrowseId: sub.albumBrowseId,
      );
    }
    if (browseId != null) {
      // Distinguimos album/playlist/artist por prefijo del browseId:
      // MPREb_ → album, VL → playlist, UC → artist channel.
      final kind = browseId.startsWith('MPREb_')
          ? ShelfItemKind.album
          : browseId.startsWith('VL')
              ? ShelfItemKind.playlist
              : ShelfItemKind.artist;
      return ShelfItem(
        kind: kind,
        id: browseId,
        title: title,
        subtitle: sub.subtitle,
        thumbnailUrl: thumbUrl ?? '',
        artistBrowseId: sub.artistBrowseId,
        albumBrowseId: sub.albumBrowseId,
      );
    }
    return null;
  }

  ShelfItem? _fromResponsiveListItem(Map r) {
    final flex = _at(r, ['flexColumns']);
    if (flex is! List || flex.isEmpty) return null;

    String? title;
    String? videoId;
    String? rowBrowseId;
    // Acumulamos los runs CRUDOS (con browseId) en lugar de solo texto, para
    // poder usar el mismo helper de subtitle limpio que prefiere UC-links.
    final subtitleRuns = <dynamic>[];

    for (var i = 0; i < flex.length; i++) {
      final col = _at(flex[i], [
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]);
      if (col is! List) continue;
      for (final run in col) {
        final text = _at(run, ['text']);
        if (text is! String) continue;
        if (i == 0 && title == null) {
          title = text;
          videoId ??= _at(run, [
            'navigationEndpoint',
            'watchEndpoint',
            'videoId',
          ]) as String?;
          // Para álbumes/artistas/playlists, la navegación es `browseEndpoint`
          // — sin esto solo distinguíamos canciones (videoId) y descartábamos
          // todo lo demás.
          rowBrowseId ??= _at(run, [
            'navigationEndpoint',
            'browseEndpoint',
            'browseId',
          ]) as String?;
        } else if (i > 0) {
          subtitleRuns.add(run);
        }
      }
    }
    videoId ??= _at(r, ['playlistItemData', 'videoId']) as String?;

    // Browse a nivel de la fila entera (algunas respuestas lo ponen ahí en
    // lugar de en el primer run del título).
    rowBrowseId ??= _at(r, [
      'navigationEndpoint',
      'browseEndpoint',
      'browseId',
    ]) as String?;

    if (title == null) return null;

    final thumbUrl = _bestThumbnail(_at(r, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]));

    final sub = _cleanArtistSubtitle(subtitleRuns);

    // Canción: tiene videoId.
    if (videoId != null) {
      return ShelfItem(
        kind: ShelfItemKind.song,
        id: videoId,
        streamingId: videoId,
        title: title,
        subtitle: sub.subtitle,
        thumbnailUrl: thumbUrl ?? '',
        artistBrowseId: sub.artistBrowseId,
        albumBrowseId: sub.albumBrowseId,
      );
    }

    // Álbum/artista/playlist: distinguimos por prefijo del browseId. Mismo
    // criterio que `_fromTwoRowItem`.
    if (rowBrowseId != null) {
      final kind = rowBrowseId.startsWith('MPREb_')
          ? ShelfItemKind.album
          : rowBrowseId.startsWith('VL')
              ? ShelfItemKind.playlist
              : ShelfItemKind.artist;
      return ShelfItem(
        kind: kind,
        id: rowBrowseId,
        title: title,
        subtitle: sub.subtitle,
        thumbnailUrl: thumbUrl ?? '',
        artistBrowseId: sub.artistBrowseId,
        albumBrowseId: sub.albumBrowseId,
      );
    }

    return null;
  }

  /// Liked songs: la respuesta tiene un único `musicPlaylistShelfRenderer`
  /// con `contents[]` de `musicResponsiveListItemRenderer`.
  List<StreamingTrack> _parseLikedSongs(Map<String, dynamic> root) {
    // El renderer puede estar en singleColumn o twoColumn.
    final candidates = <dynamic>[
      _at(root, [
        'contents',
        'singleColumnBrowseResultsRenderer',
        'tabs',
        0,
        'tabRenderer',
        'content',
        'sectionListRenderer',
        'contents',
        0,
        'musicPlaylistShelfRenderer',
        'contents',
      ]),
      _at(root, [
        'contents',
        'twoColumnBrowseResultsRenderer',
        'secondaryContents',
        'sectionListRenderer',
        'contents',
        0,
        'musicPlaylistShelfRenderer',
        'contents',
      ]),
    ];

    final out = <StreamingTrack>[];
    for (final list in candidates) {
      if (list is! List) continue;
      for (final item in list) {
        final track = _parseTrackItem(item);
        if (track != null) out.add(track);
      }
      if (out.isNotEmpty) return out;
    }
    return out;
  }

  // -------- Player / stream URL --------

  /// Resuelve la URL HTTPS reproducible de un videoId. Cachea por 5 horas.
  /// Si [forceRefresh] es true, ignora el cache y vuelve a pedir al
  /// endpoint `player` — útil cuando una URL cacheada "se vence" antes
  /// de tiempo (YT a veces invalida URLs por throttling/banneo de IP) y
  /// el caller necesita una URL fresca para reintentar reproducción.
  Future<String> resolveStreamUrl(
    String videoId, {
    bool forceRefresh = false,
    int targetBitrateBps = 1 << 30,
  }) async {
    if (!forceRefresh) {
      final cached = _streamCache[videoId];
      if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
        return cached.url;
      }
    }

    String? lastError;
    // Cascada de clientes. Mismo orden que OpenTune (2025): IOS y ANDROID
    // (full clients, no MUSIC) primero porque suelen funcionar sin PoT
    // token. ANDROID_VR_NO_AUTH como fallback potente para videos
    // restringidos (bypassea age-gate y region-block al ir como visitante).
    final clients = YtMusicClient.playerClientsCascade;

    for (final clientId in clients) {
      try {
        final json = await _client.player(videoId, clientId: clientId);
        
        // Verificamos si el video es reproducible (vital para invitados)
        final status = _at(json, ['playabilityStatus', 'status']) as String?;
        if (status != 'OK') {
          lastError = 'Status $status con ${clientId.name}';
          continue;
        }

        final adaptive = _at(json, ['streamingData', 'adaptiveFormats']);
        final formats = _at(json, ['streamingData', 'formats']);
        final all = <dynamic>[
          if (adaptive is List) ...adaptive,
          if (formats is List) ...formats,
        ];
        if (all.isEmpty) {
          lastError = 'streamingData vacío con ${clientId.name}';
          continue;
        }

        final best = _pickBestAudio(all, targetBitrateBps: targetBitrateBps);
        if (best == null) {
          lastError = 'sin audio reproducible con ${clientId.name}';
          continue;
        }
        final url = best['url'] as String;
        _streamCache[videoId] = (
          url: url,
          expiresAt: DateTime.now().add(_cacheTtl),
        );
        return url;
      } catch (e) {
        lastError = '${clientId.name}: $e';
      }
    }

    throw StateError(
      'No se pudo obtener el stream para $videoId. '
      'Última causa: $lastError',
    );
  }

  /// Resuelve la URL de un FORMATO DE VIDEO del videoId — para usar como
  /// fondo dinámico (música video).
  ///
  /// **Filtro crítico — `musicVideoType`**: YT Music EMPAQUETA TODAS las
  /// canciones en formatos de video (mp4 con audio embebido) aunque no
  /// tengan música video real — para esas, `videoDetails.musicVideoType`
  /// es `MUSIC_VIDEO_TYPE_ATV` ("Audio Track Video" — solo cover estático).
  /// Sin filtrar por musicVideoType, devolvíamos URL de "video" para
  /// CUALQUIER canción y el toggle aparecía en todas → falso positivo.
  ///
  /// Aceptamos sólo:
  ///   - MUSIC_VIDEO_TYPE_OMV (Official Music Video).
  ///   - MUSIC_VIDEO_TYPE_UGC (User-Generated Content con video).
  /// Rechazamos:
  ///   - MUSIC_VIDEO_TYPE_ATV (no hay video real).
  ///   - MUSIC_VIDEO_TYPE_PODCAST_EPISODE.
  ///   - Cualquier valor desconocido por seguridad.
  Future<VideoStreamInfo?> resolveVideoUrl(String videoId) async {
    const allowedVideoTypes = {
      'MUSIC_VIDEO_TYPE_OMV',
      'MUSIC_VIDEO_TYPE_UGC',
      'MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC',
    };
    final clients = YtMusicClient.playerClientsCascade;
    for (final clientId in clients) {
      try {
        final json = await _client.player(videoId, clientId: clientId);
        final status = _at(json, ['playabilityStatus', 'status']) as String?;
        if (status != 'OK') continue;
        final mvType =
            _at(json, ['videoDetails', 'musicVideoType']) as String?;
        if (mvType != null && !allowedVideoTypes.contains(mvType)) {
          // Confirmado SIN video real (ATV / podcast / etc.). Salimos
          // inmediato — los demás clients devolverán el mismo tipo.
          return null;
        }
        final adaptive = _at(json, ['streamingData', 'adaptiveFormats']);
        final formats = _at(json, ['streamingData', 'formats']);
        final all = <dynamic>[
          if (adaptive is List) ...adaptive,
          if (formats is List) ...formats,
        ];
        if (all.isEmpty) continue;
        final best = _pickBestVideo(all);
        if (best != null) {
          return best;
        }
      } catch (_) {
        // Siguiente cliente.
      }
    }
    return null;
  }

  /// Filtra el mejor format de video. Prefiere formats COMBINADOS (video+audio
  /// en una sola pista) — son los que permiten al video_player reproducir
  /// audio sin necesidad de un decoder separado. Los `formats` no-adaptivos
  /// (itag 18 = 360p mp4 c/audio, itag 22 = 720p mp4 c/audio) son combinados.
  /// Los `adaptiveFormats` de video son típicamente video-only.
  ///
  /// Sin esto, al activar el toggle "ver video" el VideoPlayer cargaba un
  /// stream video-only → silencio total (porque también muteamos el audio
  /// principal asumiendo que el video traía audio).
  ///
  /// Resolución target: 360p–720p (ahorra ancho de banda sin perder calidad
  /// visible). Si no hay combinado, cae a video-only con `hasAudio: false`
  /// — el caller debe mantener el audio principal en ese caso.
  static VideoStreamInfo? _pickBestVideo(List<dynamic> formats) {
    Map<String, dynamic>? bestCombined;
    var bestCombinedScore = -1;
    Map<String, dynamic>? bestVideoOnly;
    var bestVideoOnlyScore = -1;
    for (final f in formats) {
      if (f is! Map) continue;
      final mime = _at(f, ['mimeType']);
      if (mime is! String) continue;
      if (!mime.startsWith('video/')) continue;
      final url = _at(f, ['url']);
      if (url is! String || url.isEmpty) continue;
      final h = (_at(f, ['height']) as num?)?.toInt() ?? 0;
      if (h == 0) continue;
      // Combinado = el format trae pista de audio. InnerTube expone esto
      // como `audioChannels` o `audioSampleRate` presentes.
      final hasAudio = _at(f, ['audioChannels']) != null ||
          _at(f, ['audioSampleRate']) != null;
      final inIdealRange = h >= 360 && h <= 720;
      final score = inIdealRange ? 1000 + h : h;
      if (hasAudio) {
        if (score > bestCombinedScore) {
          bestCombined = f.cast<String, dynamic>();
          bestCombinedScore = score;
        }
      } else {
        if (score > bestVideoOnlyScore) {
          bestVideoOnly = f.cast<String, dynamic>();
          bestVideoOnlyScore = score;
        }
      }
    }
    final pick = bestCombined ?? bestVideoOnly;
    if (pick == null) return null;
    return VideoStreamInfo(
      url: pick['url'] as String,
      hasAudio: bestCombined != null,
    );
  }

  /// Filtra el mejor format de audio (sin cipher) por bitrate.
  /// Selecciona el mejor format de audio respetando un [targetBitrateBps].
  /// Estrategia: prefiere el bitrate más alto que NO supere el target. Si
  /// nada queda bajo el target (formats todos arriba), cae al de menor
  /// bitrate disponible — mejor algo bajito que nada. Si `targetBitrateBps`
  /// es muy grande (= high), comportamiento equivale al "pick highest".
  static Map<String, dynamic>? _pickBestAudio(
    List<dynamic> formats, {
    int targetBitrateBps = 1 << 30,
  }) {
    Map<String, dynamic>? underTarget; // mejor format ≤ target
    var underBitrate = -1;
    Map<String, dynamic>? fallback; // mínimo absoluto
    var fallbackBitrate = -1;
    for (final f in formats) {
      if (f is! Map) continue;
      final mime = _at(f, ['mimeType']);
      if (mime is! String) continue;
      final isAudioOnly = mime.startsWith('audio/');
      if (!isAudioOnly) continue;
      final url = _at(f, ['url']);
      if (url is! String || url.isEmpty) continue;
      final bitrate = (_at(f, ['bitrate']) as num?)?.toInt() ?? 0;
      if (bitrate <= targetBitrateBps && bitrate > underBitrate) {
        underTarget = f.cast<String, dynamic>();
        underBitrate = bitrate;
      }
      if (fallback == null || bitrate < fallbackBitrate) {
        fallback = f.cast<String, dynamic>();
        fallbackBitrate = bitrate;
      }
    }
    return underTarget ?? fallback;
  }

  // -------- helpers --------

  /// Navega por una serie de keys dentro de un map/list anidado, devolviendo
  /// `null` en cuanto encuentra algo que no es navegable. Tolera índices `int`
  /// para listas.
  static dynamic _at(dynamic node, List<dynamic> path) {
    var cur = node;
    for (final key in path) {
      if (cur is Map && key is String) {
        cur = cur[key];
      } else if (cur is List && key is int) {
        if (key < 0 || key >= cur.length) return null;
        cur = cur[key];
      } else {
        return null;
      }
      if (cur == null) return null;
    }
    return cur;
  }

  static String? _bestThumbnail(dynamic list) {
    if (list is! List || list.isEmpty) return null;
    Map? best;
    var bestArea = -1;
    for (final t in list) {
      if (t is! Map) continue;
      final w = (t['width'] as num?)?.toInt() ?? 0;
      final h = (t['height'] as num?)?.toInt() ?? 0;
      final area = w * h;
      if (area > bestArea) {
        best = t;
        bestArea = area;
      }
    }
    String? url = best?['url'] as String?;
    if (url == null) return null;
    
    // Aseguramos protocolo HTTPS
    if (url.startsWith('//')) url = 'https:$url';

    // Mejoramos la resolución: YouTube a veces devuelve "=w120-h120-l90-rj" 
    // lo forzamos a 720 o 1080 si detectamos el patrón.
    if (url.contains('=w') && url.contains('-h')) {
      return url.replaceAll(RegExp(r'=w\d+-h\d+'), '=w720-h720');
    }
    return url;
  }

  /// Detecta etiquetas de tipo que YT Music mete en flexColumns y NO son
  /// metadatos útiles para el reproductor: "Song", "Video", "Album", "EP",
  /// "Single", y traducciones obvias. Sin este filtro, "Song" terminaba como
  /// nombre de artista en algunas vistas.
  static bool _isTypeLabel(String s) {
    final t = s.trim().toLowerCase();
    const labels = {
      'song', 'video', 'album', 'ep', 'single', 'playlist', 'artist',
      'canción', 'cancion', 'álbum', 'artista', 'reproducción', 'reproduccion',
    };
    return labels.contains(t);
  }

  /// Detecta strings que YT Music usa para mostrar conteos de reproducciones:
  /// "5.4M plays", "1.2K reproducciones", "892 views", "8.7 M de vistas",
  /// "1,234,567 plays", etc. Sin este filtro, el conteo se metía como nombre
  /// de artista en la cabecera del reproductor.
  static final _playCountRegex = RegExp(
    r'^\s*[\d.,]+\s*[KMBkmb]?\s*'
    r'(de\s+)?'
    r'(plays?|views?|reproducciones?|reproducción|vistas?|visualizaciones?)\b',
    caseSensitive: false,
  );
  static bool _looksLikePlayCount(String s) {
    return _playCountRegex.hasMatch(s);
  }

  /// Parsea cosas como "3:45" o "1:02:30" → milisegundos.
  static int? _parseDuration(String s) {
    final t = s.trim();
    final parts = t.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    try {
      final nums = parts.map(int.parse).toList();
      var total = 0;
      for (final n in nums) {
        total = total * 60 + n;
      }
      return total * 1000;
    } catch (_) {
      return null;
    }
  }

  static String? _scavengeThumbnail(dynamic node) {
    if (node is Map) {
      // 1. PRIORIDAD ALTA: Contenedores específicos de álbum/pista (suelen ser cuadrados)
      final albumArt = _at(node, ['thumbnail', 'croppedSquareThumbnailRenderer', 'thumbnail', 'thumbnails']) ??
                       _at(node, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']) ??
                       _at(node, ['header', 'musicDetailHeaderRenderer', 'thumbnail', 'croppedSquareThumbnailRenderer', 'thumbnail', 'thumbnails']);
      if (albumArt != null) return _bestThumbnail(albumArt);

      // 2. PRIORIDAD MEDIA: Thumbnails estándar
      final standard = _at(node, ['thumbnail', 'thumbnails']);
      if (standard != null) return _bestThumbnail(standard);
      
      // 3. RECURSIÓN: Buscamos más profundo, pero IGNORAMOS llaves que suelen ser de artista/canal
      for (final key in node.keys) {
        if (key == 'avatar' || key == 'channelThumbnail' || key == 'authorThumbnail' || key == 'navigationEndpoint') continue;
        final found = _scavengeThumbnail(node[key]);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final i in node) {
        final found = _scavengeThumbnail(i);
        if (found != null) return found;
      }
    }
    return null;
  }

  void dispose() => _client.dispose();
}
