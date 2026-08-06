import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../core/dev_log.dart';

/// Rating de una canción: 0.5–5.0 estrellas en pasos de media estrella
/// (escala estilo RateYourMusic). Guarda un snapshot de la metadata de la
/// canción para que la lista de calificaciones se pueda renderizar aunque
/// la canción ya no esté en la biblioteca / cache de streaming.
@immutable
class SongRating {
  const SongRating({
    required this.song,
    required this.rating,
    required this.ratedAt,
  });

  final Song song;

  /// 0.5–5.0 en pasos de 0.5.
  final double rating;
  final DateTime ratedAt;

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'rating': rating,
        'ratedAt': ratedAt.millisecondsSinceEpoch,
      };

  factory SongRating.fromJson(Map<String, dynamic> m) => SongRating(
        song: Song.fromJson(m['song'] as Map<String, dynamic>),
        rating: ((m['rating'] as num?)?.toDouble() ?? 0).clamp(0.5, 5.0),
        ratedAt: DateTime.fromMillisecondsSinceEpoch(
            (m['ratedAt'] as num?)?.toInt() ?? 0),
      );
}

/// Calificaciones locales de canciones.
///
/// Nota sobre RateYourMusic: RYM NO tiene API pública (la "Sonemic API"
/// lleva años prometida sin salir) y su ToS prohíbe automatizar el sitio —
/// intentar sincronizar via scraping/credenciales arriesga el ban de la
/// cuenta del usuario. Por eso el rating vive LOCAL con export a CSV; si
/// RYM publica su API algún día, este service es el punto de enganche.
class RatingsService extends ChangeNotifier {
  RatingsService._(this._prefs, Map<String, SongRating> initial)
      : _ratings = initial;

  static const _kKey = 'vibra.ratings.v1';

  final SharedPreferences? _prefs;
  final Map<String, SongRating> _ratings;

  static Future<RatingsService> create() async {
    SharedPreferences? prefs;
    final map = <String, SongRating>{};
    try {
      prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          try {
            map[e.key] = SongRating.fromJson(e.value as Map<String, dynamic>);
          } catch (_) {}
        }
      }
    } catch (e) {
      devLog('RatingsService load failed: $e');
    }
    return RatingsService._(prefs, map);
  }

  /// Rating de [songId], o null si no está calificada.
  double? ratingOf(String songId) => _ratings[songId]?.rating;

  bool isRated(String songId) => _ratings.containsKey(songId);

  int get count => _ratings.length;

  /// Todas las calificaciones. Orden estable por fecha (recientes primero).
  List<SongRating> get all {
    final out = _ratings.values.toList()
      ..sort((a, b) => b.ratedAt.compareTo(a.ratedAt));
    return out;
  }

  /// Promedio global de las calificaciones (null sin datos).
  double? get average {
    if (_ratings.isEmpty) return null;
    final sum = _ratings.values.fold<double>(0, (a, r) => a + r.rating);
    return sum / _ratings.length;
  }

  /// Histograma por media estrella: clave "0.5".."5.0" → conteo.
  Map<double, int> get histogram {
    final out = <double, int>{};
    for (var v = 0.5; v <= 5.0; v += 0.5) {
      out[v] = 0;
    }
    for (final r in _ratings.values) {
      out[r.rating] = (out[r.rating] ?? 0) + 1;
    }
    return out;
  }

  /// Califica [song] con [rating] (0.5–5.0, se redondea a media estrella).
  Future<void> rate(Song song, double rating) async {
    final snapped = (rating * 2).round() / 2;
    _ratings[song.id] = SongRating(
      song: song,
      rating: snapped.clamp(0.5, 5.0),
      ratedAt: DateTime.now(),
    );
    notifyListeners();
    await _persist();
  }

  /// Quita la calificación de [songId].
  Future<void> unrate(String songId) async {
    if (_ratings.remove(songId) == null) return;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final out = <String, dynamic>{
        for (final e in _ratings.entries) e.key: e.value.toJson(),
      };
      await _prefs?.setString(_kKey, jsonEncode(out));
    } catch (e) {
      devLog('RatingsService persist failed: $e');
    }
  }

  /// CSV con todas las calificaciones (respaldo / uso externo). Columnas
  /// compatibles con hojas de cálculo: título, artista, álbum, rating,
  /// fecha ISO.
  String toCsv() {
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final b = StringBuffer('title,artist,album,rating,rated_at\n');
    for (final r in all) {
      b.writeln('${esc(r.song.title)},${esc(r.song.artist)},'
          '${esc(r.song.album)},${r.rating},'
          '${r.ratedAt.toIso8601String()}');
    }
    return b.toString();
  }
}
