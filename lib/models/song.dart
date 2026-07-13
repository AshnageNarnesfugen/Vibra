import 'package:flutter/foundation.dart';

@immutable
class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.uri,
    this.durationMs,
    this.albumId,
    this.inlineArtwork,
    this.streamingId,
    this.thumbnailUrl,
    this.artistBrowseId,
    this.albumBrowseId,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String? artistBrowseId;
  final String? albumBrowseId;

  /// Ruta o URI de reproducción.
  /// - Local file: ruta absoluta o `file://`
  /// - Android system: `content://`
  /// - Streaming (YouTube Music): `ytmusic://${videoId}` — placeholder; la URL
  ///   real se resuelve JIT en [PlaybackController.playAt] vía
  ///   [StreamingService.resolveStreamUrl].
  final String uri;
  final int? durationMs;
  final int? albumId;

  /// Bytes de portada ya leídos (modo carpeta manual usa esto).
  final Uint8List? inlineArtwork;

  /// Si está presente, la canción es de streaming (YouTube Music) y este
  /// es el videoId con el que pedimos el stream a la API InnerTube.
  final String? streamingId;

  /// URL HTTPS de la portada para canciones de streaming. Para canciones
  /// locales usamos [inlineArtwork] o consultamos al sistema.
  final String? thumbnailUrl;

  bool get isStreaming => streamingId != null;

  Duration get duration => Duration(milliseconds: durationMs ?? 0);

  Song copyWith({
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? thumbnailUrl,
    String? uri,
  }) =>
      Song(
        id: id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        uri: uri ?? this.uri,
        durationMs: durationMs ?? this.durationMs,
        albumId: albumId,
        inlineArtwork: inlineArtwork,
        streamingId: streamingId,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        artistBrowseId: artistBrowseId,
        albumBrowseId: albumBrowseId,
      );

  /// Para persistencia (playlists locales). `inlineArtwork` queda fuera —
  /// son bytes pesados; se recarga vía LibraryService al cargar la playlist.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'uri': uri,
        if (durationMs != null) 'durationMs': durationMs,
        if (albumId != null) 'albumId': albumId,
        if (streamingId != null) 'streamingId': streamingId,
        if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
        if (artistBrowseId != null) 'artistBrowseId': artistBrowseId,
        if (albumBrowseId != null) 'albumBrowseId': albumBrowseId,
      };

  factory Song.fromJson(Map<String, dynamic> m) => Song(
        id: m['id'] as String,
        title: m['title'] as String? ?? '',
        artist: m['artist'] as String? ?? '',
        album: m['album'] as String? ?? '',
        uri: m['uri'] as String? ?? '',
        durationMs: (m['durationMs'] as num?)?.toInt(),
        albumId: (m['albumId'] as num?)?.toInt(),
        streamingId: m['streamingId'] as String?,
        thumbnailUrl: m['thumbnailUrl'] as String?,
        artistBrowseId: m['artistBrowseId'] as String?,
        albumBrowseId: m['albumBrowseId'] as String?,
      );
}

/// Representa un álbum agrupado artificialmente a partir de la metadata.
@immutable
class Album {
  const Album({
    required this.name,
    required this.artist,
    required this.songs,
    this.thumbnailUrl,
    this.inlineArtwork,
  });

  final String name;
  final String artist;
  final List<Song> songs;
  final String? thumbnailUrl;
  final Uint8List? inlineArtwork;

  String get id => '$name-$artist';
}

/// Representa un artista agrupado artificialmente.
@immutable
class Artist {
  const Artist({
    required this.name,
    required this.songs,
    this.thumbnailUrl,
  });

  final String name;
  final List<Song> songs;
  final String? thumbnailUrl;
}

/// Resultado de cargar artwork. Mantenemos la representación cruda en bytes
/// para alimentar a la vez `Image.memory` y `palette_generator`.
@immutable
class Artwork {
  const Artwork(this.bytes);
  final Uint8List bytes;
}
