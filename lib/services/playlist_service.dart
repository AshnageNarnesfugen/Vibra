import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../core/dev_log.dart';

/// Persistencia y CRUD de [Playlist] del usuario.
///
/// Guardado: `SharedPreferences` con clave `vibra.playlists.v1` →
/// `List<String>` (JSON de cada playlist). No usamos SQLite porque las
/// playlists son típicamente decenas, no miles — el overhead de SQLite no
/// se justifica y SharedPreferences es la persistencia que ya tiene la app.
class PlaylistService extends ChangeNotifier {
  PlaylistService._(this._prefs, this._playlists);

  static const _kKey = 'vibra.playlists.v1';

  final SharedPreferences? _prefs;
  final List<Playlist> _playlists;

  List<Playlist> get playlists => List.unmodifiable(_playlists);

  static Future<PlaylistService> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      devLog('PlaylistService prefs load failed: $e');
    }
    final raw = prefs?.getStringList(_kKey) ?? const <String>[];
    final loaded = <Playlist>[];
    for (final json in raw) {
      try {
        loaded.add(Playlist.fromJson(jsonDecode(json) as Map<String, dynamic>));
      } catch (e) {
        devLog('PlaylistService skip malformed: $e');
      }
    }
    return PlaylistService._(prefs, loaded);
  }

  Future<void> _persist() async {
    final raw = _playlists.map((p) => jsonEncode(p.toJson())).toList();
    try {
      await _prefs?.setStringList(_kKey, raw);
    } catch (e) {
      devLog('PlaylistService persist failed: $e');
    }
  }

  Future<Playlist> create({required String name, List<Song>? initialSongs}) async {
    final pl = Playlist(
      id: 'pl_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Nueva playlist' : name.trim(),
      songs: List<Song>.from(initialSongs ?? const []),
      createdAt: DateTime.now(),
    );
    _playlists.add(pl);
    notifyListeners();
    await _persist();
    return pl;
  }

  Future<void> rename(String id, String newName) async {
    final i = _playlists.indexWhere((p) => p.id == id);
    if (i < 0) return;
    _playlists[i] = _playlists[i].copyWith(name: newName);
    notifyListeners();
    await _persist();
  }

  Future<void> delete(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    notifyListeners();
    await _persist();
  }

  /// Añade [songs] a la playlist, evitando duplicados por `Song.id`.
  /// Devuelve cuántas canciones quedaron NUEVAS (las repetidas no cuentan).
  Future<int> addSongs(String playlistId, List<Song> songs) async {
    final i = _playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return 0;
    final existing = _playlists[i].songs;
    final existingIds = existing.map((s) => s.id).toSet();
    final additions = songs.where((s) => !existingIds.contains(s.id)).toList();
    if (additions.isEmpty) return 0;
    _playlists[i] = _playlists[i].copyWith(songs: [...existing, ...additions]);
    notifyListeners();
    await _persist();
    return additions.length;
  }

  Future<void> removeSong(String playlistId, String songId) async {
    final i = _playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return;
    final next = _playlists[i].songs.where((s) => s.id != songId).toList();
    _playlists[i] = _playlists[i].copyWith(songs: next);
    notifyListeners();
    await _persist();
  }

  /// Reordena una canción dentro de la playlist (drag-and-drop).
  Future<void> reorder(String playlistId, int from, int to) async {
    final i = _playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return;
    final list = List<Song>.from(_playlists[i].songs);
    if (from < 0 || from >= list.length) return;
    final adj = to > from ? to - 1 : to;
    final song = list.removeAt(from);
    list.insert(adj.clamp(0, list.length), song);
    _playlists[i] = _playlists[i].copyWith(songs: list);
    notifyListeners();
    await _persist();
  }
}
