import 'package:flutter/foundation.dart';

import 'song.dart';

/// Playlist local del usuario — vive en este dispositivo, no se sincroniza
/// con YouTube Music. Persistencia en SharedPreferences vía PlaylistService.
@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.songs,
    required this.createdAt,
    this.coverThumbnailUrl,
  });

  /// Slug único: timestamp en ms al crear. Estable, no depende del nombre
  /// (así renombrar no rompe referencias futuras).
  final String id;
  final String name;
  final List<Song> songs;
  final DateTime createdAt;

  /// Override opcional de la carátula. Si es null, la UI usa la portada de
  /// la primera canción.
  final String? coverThumbnailUrl;

  /// Carátula a mostrar: override → primera canción → null (placeholder).
  String? get displayThumbnailUrl {
    if (coverThumbnailUrl != null && coverThumbnailUrl!.isNotEmpty) {
      return coverThumbnailUrl;
    }
    for (final s in songs) {
      if (s.thumbnailUrl != null && s.thumbnailUrl!.isNotEmpty) {
        return s.thumbnailUrl;
      }
    }
    return null;
  }

  Playlist copyWith({
    String? name,
    List<Song>? songs,
    String? coverThumbnailUrl,
  }) =>
      Playlist(
        id: id,
        name: name ?? this.name,
        songs: songs ?? this.songs,
        createdAt: createdAt,
        coverThumbnailUrl: coverThumbnailUrl ?? this.coverThumbnailUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (coverThumbnailUrl != null) 'coverThumbnailUrl': coverThumbnailUrl,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  factory Playlist.fromJson(Map<String, dynamic> m) => Playlist(
        id: m['id'] as String,
        name: m['name'] as String? ?? 'Sin nombre',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (m['createdAt'] as num?)?.toInt() ?? 0),
        coverThumbnailUrl: m['coverThumbnailUrl'] as String?,
        songs: (m['songs'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Song.fromJson)
            .toList(),
      );
}
