import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/lyrics.dart';
import '../core/dev_log.dart';

/// Cliente HTTP para lrclib.net — base de datos comunitaria de letras
/// sincronizadas. Es free, sin auth, y devuelve LRC (sincronizado) +
/// plainLyrics (fallback no sincronizado).
///
/// Estrategia de búsqueda:
///   1. `/api/search?q="title artist"` — el endpoint MÁS permisivo, hace
///      full-text matching. Resulta ser el más confiable en la práctica.
///   2. `/api/search` con track + artist separados.
///   3. `/api/get` exacto (track + artist + album + duration) si tenemos
///      todos los campos válidos.
class LyricsService {
  LyricsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _ua = 'Vibra/1.0 (https://github.com/dreadashes/vibra)';
  // 12s por request (antes 6s) — lrclib a veces responde lento desde
  // redes con latencia alta. Con 6s veíamos TimeoutException en cada
  // intento aunque el server estaba vivo.
  static const _timeout = Duration(seconds: 12);

  Future<Lyrics?> fetch({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final titleVariants = _titleVariants(title);
    final artistVariants = _artistVariants(artist);
    final cleanAlbum = _normalizeAlbum(album);

    devLog('[LYRICS] fetch '
        'title="$title" titleVariants=$titleVariants '
        'artist="$artist" artistVariants=$artistVariants '
        'album="$album"→cleanAlbum="$cleanAlbum" '
        'duration=${duration?.inSeconds}s');

    // Round 1: TODAS las búsquedas /search en PARALELO. Antes eran
    // secuenciales → si la red está lenta, esperábamos N × timeout. En
    // paralelo, esperamos solo 1 × timeout para todas. La primera que
    // devuelva un match no-null gana (el resto se ignoran).
    final searchFutures = <Future<Lyrics?>>[];
    for (final t in titleVariants) {
      for (final a in artistVariants) {
        searchFutures.add(_searchByQuery('$t $a'));
        searchFutures.add(_searchByFields(title: t, artist: a));
      }
    }
    final searchResults = await Future.wait(searchFutures);
    for (final r in searchResults) {
      if (r != null) {
        devLog('[LYRICS] HIT en round /search');
        return r;
      }
    }

    // Round 2: /api/get exacto en paralelo. Lo más estricto — requiere
    // album + duration al char. Solo intentamos si las búsquedas
    // anteriores no pegaron.
    final getFutures = <Future<Lyrics?>>[];
    for (final t in titleVariants) {
      for (final a in artistVariants) {
        getFutures.add(_getExact(
          title: t,
          artist: a,
          album: cleanAlbum,
          duration: duration,
        ));
      }
    }
    final getResults = await Future.wait(getFutures);
    for (final r in getResults) {
      if (r != null) {
        devLog('[LYRICS] HIT en round /get');
        return r;
      }
    }

    devLog('[LYRICS] MISS — sin match en lrclib');
    return null;
  }

  // ---------- Title variants ----------

  /// Genera variantes del título ordenadas por probabilidad de match.
  static List<String> _titleVariants(String title) {
    final out = <String>[];
    void add(String s) {
      final c = s.trim();
      if (c.isNotEmpty && !out.contains(c)) out.add(c);
    }

    final cleaned = _cleanTitle(title);
    add(cleaned);
    add(title);

    // Format "japonés - romaji" o "title - subtitle": probar cada lado.
    // Lrclib indexa el romaji o el título en latín en la mayoría de casos.
    if (cleaned.contains(' - ')) {
      final parts = cleaned.split(' - ');
      // Prefiere la parte con más ASCII (romaji típica).
      parts.sort((a, b) {
        final aAscii = a.runes.where((r) => r < 128).length;
        final bAscii = b.runes.where((r) => r < 128).length;
        return bAscii.compareTo(aAscii);
      });
      for (final p in parts) {
        add(p);
      }
    }
    return out;
  }

  // ---------- Artist variants ----------

  /// Genera variantes del artist. Primer item: el limpio (sin "- Topic",
  /// "VEVO", etc.). Siguientes: el "artista principal" cuando hay
  /// colaboraciones (& X, feat. Y, x Z, etc.).
  static List<String> _artistVariants(String artist) {
    final out = <String>[];
    void add(String s) {
      final c = s.trim();
      if (c.isNotEmpty && !out.contains(c)) out.add(c);
    }

    final cleaned = _cleanArtist(artist);
    add(cleaned);
    add(artist);

    // "X & Y" / "X feat. Y" / "X x Y" / "X / Y" → solo "X".
    final sep =
        RegExp(r'\s*(?:&|feat\.?|ft\.?|x|×|/|,|\sand\s)\s*',
            caseSensitive: false);
    final parts = cleaned.split(sep);
    if (parts.length > 1) {
      add(parts.first);
    }
    return out;
  }

  // ---------- HTTP wrappers ----------

  /// `/api/search?q=...` con query libre — el endpoint más permisivo.
  Future<Lyrics?> _searchByQuery(String query) async {
    try {
      final resp = await _client
          .get(
            Uri.https('lrclib.net', '/api/search', {'q': query}),
            headers: const {'User-Agent': _ua},
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        devLog(
            '[LYRICS] /search?q status=${resp.statusCode} query="$query"');
        return null;
      }
      return _pickFromList(resp.body);
    } catch (e) {
      devLog('[LYRICS] /search?q error: $e');
      return null;
    }
  }

  /// `/api/search?track_name=X&artist_name=Y` con campos separados.
  Future<Lyrics?> _searchByFields({
    required String title,
    required String artist,
  }) async {
    try {
      final resp = await _client
          .get(
            Uri.https(
              'lrclib.net',
              '/api/search',
              {'track_name': title, 'artist_name': artist},
            ),
            headers: const {'User-Agent': _ua},
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        devLog('[LYRICS] /search status=${resp.statusCode} '
            't="$title" a="$artist"');
        return null;
      }
      return _pickFromList(resp.body);
    } catch (e) {
      devLog('[LYRICS] /search fields error: $e');
      return null;
    }
  }

  Future<Lyrics?> _getExact({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
  }) async {
    final params = <String, String>{
      'track_name': title,
      'artist_name': artist,
      'album_name': ?album,
      'duration': ?duration?.inSeconds.toString(),
    };
    try {
      final resp = await _client
          .get(Uri.https('lrclib.net', '/api/get', params),
              headers: const {'User-Agent': _ua})
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        devLog('[LYRICS] /get status=${resp.statusCode} '
            't="$title" a="$artist" album="$album"');
        return null;
      }
      final json = jsonDecode(resp.body);
      if (json is! Map<String, dynamic>) return null;
      return _fromJson(json);
    } catch (e) {
      devLog('[LYRICS] /get error: $e');
      return null;
    }
  }

  // ---------- Parsing helpers ----------

  /// Toma una respuesta JSON-array de `/api/search` y devuelve el primer
  /// resultado con syncedLyrics (o el primero con plain si no hay synced).
  Lyrics? _pickFromList(String body) {
    final list = jsonDecode(body);
    if (list is! List || list.isEmpty) return null;
    Map<String, dynamic>? bestSynced;
    Map<String, dynamic>? firstAny;
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      firstAny ??= raw;
      final s = raw['syncedLyrics'];
      if (s is String && s.isNotEmpty) {
        bestSynced = raw;
        break;
      }
    }
    final pick = bestSynced ?? firstAny;
    return pick == null ? null : _fromJson(pick);
  }

  Lyrics? _fromJson(Map<String, dynamic> json) {
    if (json['instrumental'] == true) {
      return const Lyrics(
        lines: [LyricLine(time: Duration.zero, text: '♪ Instrumental ♪')],
        synced: false,
      );
    }
    final synced = json['syncedLyrics'];
    if (synced is String && synced.isNotEmpty) {
      final lines = LrcParser.parse(synced);
      if (lines.isNotEmpty) return Lyrics(lines: lines, synced: true);
    }
    final plain = json['plainLyrics'];
    if (plain is String && plain.isNotEmpty) {
      final lines = plain
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) => LyricLine(time: Duration.zero, text: l))
          .toList();
      if (lines.isNotEmpty) return Lyrics(lines: lines, synced: false);
    }
    return null;
  }

  // ---------- Field cleaners ----------

  /// Quita sufijos comunes que rompen el match en lrclib.
  static String _cleanTitle(String t) {
    var r = t;
    final patterns = [
      RegExp(r'\s*[\[(][^\])]*official[^\])]*[\])]', caseSensitive: false),
      RegExp(r'\s*[\[(][^\])]*lyrics?[^\])]*[\])]', caseSensitive: false),
      RegExp(r'\s*[\[(][^\])]*(hd|hq|4k|remaster\w*)[^\])]*[\])]',
          caseSensitive: false),
      RegExp(r'\s*[\[(][^\])]*audio[^\])]*[\])]', caseSensitive: false),
      RegExp(r'\s*[\[(][^\])]*video[^\])]*[\])]', caseSensitive: false),
      RegExp(r'\s*[\[(][^\])]*(tv|live|short|full)[^\])]*[\])]',
          caseSensitive: false),
    ];
    for (final p in patterns) {
      r = r.replaceAll(p, '');
    }
    return r.trim();
  }

  /// Quita sufijos comunes que YouTube Music añade al artist.
  static String _cleanArtist(String a) {
    var r = a.trim();
    final patterns = [
      RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false),
      RegExp(r'\s+VEVO\s*$', caseSensitive: false),
      RegExp(r'\s+Records?\s*$', caseSensitive: false),
      RegExp(r'\s*\(?(feat\.?|ft\.?)\s+[^)]+\)?', caseSensitive: false),
    ];
    for (final p in patterns) {
      r = r.replaceAll(p, '');
    }
    return r.trim();
  }

  /// Normaliza el album: devuelve `null` para valores que no son nombres
  /// reales (placeholder "—", "-", vacío, etc). Sin esto el `/get` exacto
  /// fallaba para canciones de streaming donde el campo album viene como
  /// `"—"` placeholder.
  static String? _normalizeAlbum(String? album) {
    if (album == null) return null;
    final t = album.trim();
    if (t.isEmpty) return null;
    if (t == '—' || t == '-' || t == '–' || t == '?' || t == '_') return null;
    return t;
  }
}
