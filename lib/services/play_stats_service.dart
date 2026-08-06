import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../core/dev_log.dart';

/// Estadísticas de escucha de una canción. Alimentan el perfil musical —
/// la clave es que guardamos SEÑALES DE CALIDAD de la escucha, no solo el
/// conteo bruto: completadas vs saltadas, ms realmente escuchados, y en
/// QUÉ días se escuchó (presencia, no volumen) tanto histórico como
/// reciente. Con eso el score de "canción espiritual" puede promediar
/// devoción real en vez de asumir que favorita = la más reproducida.
class SongStats {
  SongStats({
    required this.song,
    this.plays = 0,
    this.completes = 0,
    this.skips = 0,
    this.msListened = 0,
    this.firstAt,
    this.lastAt,
    Map<String, int>? days,
    Map<String, int>? hours,
  })  : days = days ?? {},
        hours = hours ?? {};

  Song song;
  int plays;
  int completes;
  int skips;
  int msListened;
  DateTime? firstAt;
  DateTime? lastAt;

  /// 'yyyy-MM-dd' → reproducciones ese día. Cap de 400 días (los más
  /// antiguos se colapsan en [plays] que ya los cuenta).
  final Map<String, int> days;

  /// '0'..'23' → reproducciones en esa hora del día (hábitos horarios).
  final Map<String, int> hours;

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'plays': plays,
        'completes': completes,
        'skips': skips,
        'msListened': msListened,
        'firstAt': firstAt?.millisecondsSinceEpoch,
        'lastAt': lastAt?.millisecondsSinceEpoch,
        'days': days,
        'hours': hours,
      };

  factory SongStats.fromJson(Map<String, dynamic> m) => SongStats(
        song: Song.fromJson(m['song'] as Map<String, dynamic>),
        plays: (m['plays'] as num?)?.toInt() ?? 0,
        completes: (m['completes'] as num?)?.toInt() ?? 0,
        skips: (m['skips'] as num?)?.toInt() ?? 0,
        msListened: (m['msListened'] as num?)?.toInt() ?? 0,
        firstAt: m['firstAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['firstAt'] as num).toInt()),
        lastAt: m['lastAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['lastAt'] as num).toInt()),
        days: (m['days'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
            {},
        hours: (m['hours'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
            {},
      );
}

/// Registra los eventos de reproducción que el [PlaybackController] le
/// reporta (start / end con posición / complete) y los persiste
/// debounceados en prefs. Sin tracking histórico previo, el perfil
/// empieza vacío y se enriquece con el uso.
class PlayStatsService extends ChangeNotifier {
  PlayStatsService._(this._prefs, Map<String, SongStats> initial)
      : _stats = initial;

  static const _kKey = 'vibra.playstats.v1';

  /// Umbral de "salto": si la canción se abandonó antes del 30% (y de
  /// menos de 4 min escuchados) cuenta como skip, no como escucha.
  static const _skipRatio = 0.3;

  /// Escuchas de menos de 5s no cuentan para nada (zapping).
  static const _minCountMs = 5000;

  final SharedPreferences? _prefs;
  final Map<String, SongStats> _stats;
  Timer? _persistDebounce;

  /// Canción con sesión de escucha abierta (entre onTrackStart y
  /// onTrackEnd/onTrackComplete).
  String? _openId;
  bool _openClosed = false;

  static Future<PlayStatsService> create() async {
    SharedPreferences? prefs;
    final map = <String, SongStats>{};
    try {
      prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          try {
            map[e.key] = SongStats.fromJson(e.value as Map<String, dynamic>);
          } catch (_) {}
        }
      }
    } catch (e) {
      devLog('PlayStatsService load failed: $e');
    }
    return PlayStatsService._(prefs, map);
  }

  SongStats? statsOf(String songId) => _stats[songId];
  List<SongStats> get all => _stats.values.toList(growable: false);
  int get trackedCount => _stats.length;

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Empieza una sesión de escucha para [song].
  void onTrackStart(Song song) {
    _openId = song.id;
    _openClosed = false;

    final now = DateTime.now();
    final s = _stats.putIfAbsent(song.id, () => SongStats(song: song));
    // Refrescar snapshot de metadata (títulos/carátulas pueden mejorar).
    s.song = song;
    s.plays += 1;
    s.firstAt ??= now;
    s.lastAt = now;
    s.days[_dayKey(now)] = (s.days[_dayKey(now)] ?? 0) + 1;
    s.hours['${now.hour}'] = (s.hours['${now.hour}'] ?? 0) + 1;
    // Cap del mapa de días (400 entradas ≈ más de un año de granularidad).
    if (s.days.length > 400) {
      final keys = s.days.keys.toList()..sort();
      for (final k in keys.take(s.days.length - 400)) {
        s.days.remove(k);
      }
    }
    _schedulePersist();
  }

  /// La canción terminó completa (el player llegó al final).
  void onTrackComplete(Song song, {required Duration duration}) {
    final s = _stats[song.id];
    if (s == null) return;
    s.completes += 1;
    s.msListened += duration.inMilliseconds;
    if (_openId == song.id) _openClosed = true;
    _schedulePersist();
  }

  /// La canción terminó por transición (skip manual, cambio de cola…) en
  /// [position] de [duration]. Ignorado si la sesión ya se cerró por
  /// onTrackComplete.
  void onTrackEnd(Song song, {
    required Duration position,
    required Duration duration,
  }) {
    if (_openId == song.id && _openClosed) {
      // Ya contada como completa — la transición posterior no suma.
      _openId = null;
      return;
    }
    final s = _stats[song.id];
    if (s == null) return;
    final ms = position.inMilliseconds.clamp(0, duration.inMilliseconds);
    if (ms < _minCountMs) {
      // Zapping: revertimos el play contado en onTrackStart.
      s.plays = (s.plays - 1).clamp(0, 1 << 30);
    } else {
      s.msListened += ms;
      final durMs = duration.inMilliseconds;
      final abandonedEarly =
          durMs > 0 && ms / durMs < _skipRatio && ms < 240000;
      if (abandonedEarly) s.skips += 1;
    }
    if (_openId == song.id) _openId = null;
    _schedulePersist();
  }

  void _schedulePersist() {
    notifyListeners();
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 2), () {
      // ignore: discarded_futures
      _persist();
    });
  }

  Future<void> _persist() async {
    try {
      final out = <String, dynamic>{
        for (final e in _stats.entries) e.key: e.value.toJson(),
      };
      await _prefs?.setString(_kKey, jsonEncode(out));
    } catch (e) {
      devLog('PlayStatsService persist failed: $e');
    }
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    super.dispose();
  }
}
