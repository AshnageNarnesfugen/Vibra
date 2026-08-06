import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'play_stats_service.dart';
import 'streaming/streaming_service.dart';
import '../core/dev_log.dart';

/// Importa las señales del algoritmo de YouTube Music y las fusiona con
/// las estadísticas locales de [PlayStatsService]:
///
///   1. **Historial** (`FEmusic_history`): shelves agrupados por día
///      ("Hoy", "Ayer", días de la semana). YT no expone conteos exactos,
///      pero la PRESENCIA por día es exactamente lo que la constancia del
///      score necesita — y cubre lo que escuchas fuera de Vibra.
///   2. **"Vuelve a escucharlo"** del home: el output directo del
///      algoritmo de repetición de YT. La posición en el shelf se vuelve
///      un boost 0..1.
///   3. **Likes** (`FEmusic_liked_videos`): señal de gusto explícita.
///
/// Sync con cooldown de 1h (persistido) — el perfil lo dispara al abrir
/// y con el botón de refresh.
class YtStatsImporter {
  YtStatsImporter({required this.streaming, required this.stats});

  final StreamingService streaming;
  final PlayStatsService stats;

  static const _kLastSyncKey = 'vibra.ytstats.lastSync';
  static const _cooldown = Duration(hours: 1);

  bool _syncing = false;
  bool get syncing => _syncing;

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Última sincronización, o null si nunca.
  Future<DateTime?> lastSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_kLastSyncKey);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Sincroniza si hay sesión de YT Music y pasó el cooldown (o [force]).
  /// Devuelve true si corrió un sync.
  Future<bool> sync({bool force = false}) async {
    if (_syncing) return false;
    if (!streaming.hasAuth) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force) {
        final last = prefs.getInt(_kLastSyncKey);
        if (last != null &&
            DateTime.now().millisecondsSinceEpoch - last <
                _cooldown.inMilliseconds) {
          return false;
        }
      }
      _syncing = true;

      final results = await Future.wait<Object?>([
        streaming.getHistory().catchError((Object e) {
          devLog('[YTSTATS] history failed: $e');
          return <HomeShelf>[];
        }),
        streaming.getHome().catchError((Object e) {
          devLog('[YTSTATS] home failed: $e');
          return <HomeShelf>[];
        }),
        streaming.getLikedSongs().catchError((Object e) {
          devLog('[YTSTATS] liked failed: $e');
          return <StreamingTrack>[];
        }),
      ]);
      final history = results[0] as List<HomeShelf>;
      final home = results[1] as List<HomeShelf>;
      final liked = results[2] as List<StreamingTrack>;

      _importHistory(history);
      _importListenAgain([...home, ...history]);
      _importLiked(liked);
      stats.commitYtImport();

      await prefs.setInt(
          _kLastSyncKey, DateTime.now().millisecondsSinceEpoch);
      devLog('[YTSTATS] sync ok: ${history.length} shelves historial, '
          '${liked.length} likes');
      return true;
    } catch (e) {
      devLog('[YTSTATS] sync failed: $e');
      return false;
    } finally {
      _syncing = false;
    }
  }

  Song? _songFromItem(ShelfItem item) {
    final vid = item.streamingId;
    if (vid == null || vid.isEmpty) return null;
    // El subtitle de los shelves suele venir "Artista • Álbum • …".
    final artist = item.subtitle.split('•').first.trim();
    return Song(
      id: 'yt:$vid',
      title: item.title,
      artist: artist.isEmpty ? item.subtitle : artist,
      album: '—',
      uri: 'ytmusic://$vid',
      streamingId: vid,
      thumbnailUrl: item.thumbnailUrl,
      artistBrowseId: item.artistBrowseId,
      albumBrowseId: item.albumBrowseId,
    );
  }

  /// Mapea el título del shelf de historial a una fecha concreta. YT
  /// agrupa por "Hoy"/"Ayer"/día de la semana (localizado es/en); los
  /// grupos más viejos ("Marzo 2026") no se pueden fechar con precisión
  /// y se saltan — la ventana reciente es la que alimenta la constancia.
  DateTime? _dateForShelfTitle(String title, DateTime now) {
    final t = title.trim().toLowerCase();
    if (t == 'hoy' || t == 'today') return now;
    if (t == 'ayer' || t == 'yesterday') {
      return now.subtract(const Duration(days: 1));
    }
    const weekdays = {
      'monday': 1, 'lunes': 1,
      'tuesday': 2, 'martes': 2,
      'wednesday': 3, 'miércoles': 3, 'miercoles': 3,
      'thursday': 4, 'jueves': 4,
      'friday': 5, 'viernes': 5,
      'saturday': 6, 'sábado': 6, 'sabado': 6,
      'sunday': 7, 'domingo': 7,
    };
    final wd = weekdays[t];
    if (wd == null) return null;
    // El día de la semana más reciente EN EL PASADO (2..7 días atrás —
    // hoy/ayer ya tienen sus propios grupos).
    for (var back = 2; back <= 7; back++) {
      final d = now.subtract(Duration(days: back));
      if (d.weekday == wd) return d;
    }
    return null;
  }

  void _importHistory(List<HomeShelf> shelves) {
    final now = DateTime.now();
    for (final shelf in shelves) {
      final date = _dateForShelfTitle(shelf.title, now);
      if (date == null) continue;
      final key = _dayKey(date);
      for (final item in shelf.items) {
        final song = _songFromItem(item);
        if (song != null) stats.mergeYtDay(song, key);
      }
    }
  }

  void _importListenAgain(List<HomeShelf> shelves) {
    final la = shelves.where((s) {
      final t = s.title.toLowerCase();
      return t.contains('listen again') ||
          t.contains('vuelve a escuchar') ||
          t.contains('escucha de nuevo') ||
          t.contains('escuchar de nuevo');
    }).toList();
    if (la.isEmpty) return;
    // Reset: una canción que salió del shelf pierde su boost.
    stats.clearYtListenAgain();
    final items = la.first.items;
    for (var i = 0; i < items.length; i++) {
      final song = _songFromItem(items[i]);
      if (song == null) continue;
      final boost = items.length <= 1 ? 1.0 : 1.0 - i / (items.length - 1);
      stats.setYtListenAgain(song, boost.clamp(0.0, 1.0));
    }
  }

  void _importLiked(List<StreamingTrack> liked) {
    for (final t in liked) {
      stats.setYtLiked(t.toSong(), true);
    }
  }
}
