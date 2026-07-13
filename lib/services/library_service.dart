import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/settings/ui_settings.dart';
import '../models/song.dart';
import '../core/dev_log.dart';

/// Abstracción de la fuente de música. Internamente usa:
///   - `on_audio_query` cuando [LibrarySource.auto] (solo Android).
///   - Escáner Dart puro cuando [LibrarySource.manualFolder] (cualquier
///     plataforma, incluyendo Linux/desktop).
///
/// El controlador de UI llama a [load] pasándole los settings actuales y
/// recibe la lista resultante. Sin estado interno persistente — el resultado
/// vive en `LibraryController`.
class LibraryService {
  LibraryService();

  static const _audioExtensions = {
    '.mp3', '.m4a', '.aac', '.ogg', '.opus',
    '.flac', '.wav', '.wma', '.mp4',
  };

  final _query = OnAudioQuery();

  Future<List<Song>> load(UiSettings settings) async {
    if (settings.librarySource == LibrarySource.streaming) {
      // Streaming no precarga: la pantalla de biblioteca se vuelve un buscador
      // en vivo contra YouTube Music. La lógica vive en `StreamingService` y
      // en la UI directamente.
      return const [];
    }
    if (settings.librarySource == LibrarySource.manualFolder) {
      final path = settings.manualFolderPath;
      if (path == null) return const [];
      return scanFolder(path);
    }
    return _loadFromSystem();
  }

  // -------- Auto (Android) --------

  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  Future<List<Song>> _loadFromSystem() async {
    if (!Platform.isAndroid) return const [];
    final granted = await requestPermission();
    if (!granted) return const [];

    final raw = await _query.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    return raw
        .where((s) => (s.duration ?? 0) > 5000)
        .map(
          (s) => Song(
            id: s.id.toString(),
            title: s.title,
            artist: s.artist ?? 'Desconocido',
            album: s.album ?? '—',
            uri: s.data,
            durationMs: s.duration,
            albumId: s.albumId,
          ),
        )
        .toList(growable: false);
  }

  // -------- Manual (cualquier plataforma) --------

  /// Escanea recursivamente [folderPath] buscando archivos de audio. Lee
  /// metadata (título, artista, álbum, duración, portada) en paralelo
  /// usando isolates para no bloquear la UI.
  Future<List<Song>> scanFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return const [];

    final files = <File>[];
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final ext = _ext(entity.path);
        if (_audioExtensions.contains(ext)) {
          files.add(entity);
        }
      }
    } catch (e) {
      devLog('scanFolder list error: $e');
    }

    if (files.isEmpty) return const [];

    // Ordena alfabético por nombre antes de procesar.
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    // Procesamos en lotes o vía compute para no saturar el canal de isolates.
    // Para simplificar y ganar fluidez, usamos compute para el procesado de cada archivo.
    // NOTA: En una app real con miles de archivos, sería mejor procesar lotes de 50 en 50.
    final out = <Song>[];
    for (final f in files) {
      try {
        // compute() levanta un isolate, lo que evita que readMetadata (que es síncrono)
        // congele el frame de Flutter.
        final song = await compute(_readSingleFileMetadata, f.path);
        out.add(song);
      } catch (e) {
        out.add(Song(
          id: f.path,
          title: _basename(f.path),
          artist: 'Desconocido',
          album: '—',
          uri: f.path,
        ));
      }
    }
    return out;
  }

  /// Función estática para ser usada con `compute`.
  static Song _readSingleFileMetadata(String path) {
    final f = File(path);
    final meta = readMetadata(f, getImage: true);

    Uint8List? artBytes;
    if (meta.pictures.isNotEmpty) {
      artBytes = meta.pictures.first.bytes;
    }

    final name = _basename(path);
    return Song(
      id: path,
      title: meta.title?.trim().isNotEmpty == true ? meta.title!.trim() : name,
      artist:
          meta.artist?.trim().isNotEmpty == true ? meta.artist!.trim() : 'Desconocido',
      album: meta.album?.trim().isNotEmpty == true ? meta.album!.trim() : '—',
      uri: path,
      durationMs: meta.duration?.inMilliseconds,
      inlineArtwork: artBytes,
    );
  }

  // -------- Artwork --------

  Future<Uint8List?> loadArtwork(Song song) async {
    if (song.inlineArtwork != null) return song.inlineArtwork;
    if (!Platform.isAndroid) return null;
    final id = int.tryParse(song.id);
    if (id == null) return null;

    try {
      final byAudio = await _query.queryArtwork(
        id,
        ArtworkType.AUDIO,
        size: 512,
        quality: 85,
      );
      if (byAudio != null && byAudio.isNotEmpty) return byAudio;

      final albumId = song.albumId;
      if (albumId != null) {
        final byAlbum = await _query.queryArtwork(
          albumId,
          ArtworkType.ALBUM,
          size: 512,
          quality: 85,
        );
        if (byAlbum != null && byAlbum.isNotEmpty) return byAlbum;
      }
    } catch (e) {
      devLog('artwork error: $e');
    }
    return null;
  }

  // -------- helpers --------

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return '';
    return path.substring(i).toLowerCase();
  }

  static String _basename(String path) {
    final sep = Platform.pathSeparator;
    final i = path.lastIndexOf(sep);
    final name = i >= 0 ? path.substring(i + 1) : path;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
