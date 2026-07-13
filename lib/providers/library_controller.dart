import 'package:flutter/foundation.dart';

import '../core/settings/settings_controller.dart';
import '../models/song.dart';
import '../services/download_service.dart';
import '../services/library_service.dart';

/// Mantiene la lista de canciones cargadas. Cada vez que cambia
/// [SettingsController] (fuente o ruta de carpeta) se recarga automáticamente.
///
/// **Downloads de streaming**: si se pasa [_downloads], las canciones
/// descargadas (que originalmente son streaming pero ahora viven en el
/// device) se MEZCLAN con los archivos locales y se agrupan junto en
/// álbumes/artistas. Así un álbum de YT Music descargado completo
/// aparece como una entrada de álbum en la vista local, junto a la
/// música del disco.
class LibraryController extends ChangeNotifier {
  LibraryController(this._service, this._settings, {DownloadService? downloads})
      : _downloads = downloads {
    _settings.addListener(_onSettingsChanged);
    _last = _settings.value.librarySource;
    _lastPath = _settings.value.manualFolderPath;
    _downloads?.addListener(_onDownloadsChanged);
  }

  final LibraryService _service;
  final SettingsController _settings;
  final DownloadService? _downloads;

  /// Snapshot del set de IDs descargados en el último regroup. Usado
  /// para detectar si una notificación de `DownloadService` es realmente
  /// un cambio de set (nueva canción/borrada) o solo un tick de progreso
  /// (`_inProgress` cambia varias veces por segundo durante una descarga
  /// activa). Sin este dedup, cada chunk de descarga disparaba un
  /// regroup completo de la biblioteca (O(n) en canciones × log para
  /// sort) → stutter visible al descargar.
  Set<String> _lastDownloadedIds = const {};

  void _onDownloadsChanged() {
    final dl = _downloads;
    if (dl == null) return;
    final current = dl.downloadedIds.toSet();
    // Set unchanged → era solo progreso de una descarga en curso. Skip.
    if (current.length == _lastDownloadedIds.length &&
        current.containsAll(_lastDownloadedIds)) {
      return;
    }
    _lastDownloadedIds = current;
    _groupMetadata();
    notifyListeners();
  }

  // Recordamos los valores relevantes para evitar recargas innecesarias en
  // cada cambio de ajustes (los settings cambian para muchas cosas no
  // relacionadas con la biblioteca).
  late dynamic _last;
  late String? _lastPath;

  List<Song> _songs = const [];
  List<Album> _albums = const [];
  List<Artist> _artists = const [];
  bool _loading = false;
  String? _error;

  List<Song> get songs => _songs;
  List<Album> get albums => _albums;
  List<Artist> get artists => _artists;
  bool get isLoading => _loading;
  String? get error => _error;

  void _onSettingsChanged() {
    final s = _settings.value;
    if (s.librarySource != _last || s.manualFolderPath != _lastPath) {
      _last = s.librarySource;
      _lastPath = s.manualFolderPath;
      // ignore: discarded_futures
      reload();
    }
  }

  Future<void> reload() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _songs = await _service.load(_settings.value);
      _groupMetadata();
    } catch (e) {
      _error = e.toString();
      _songs = const [];
      _albums = const [];
      _artists = const [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _groupMetadata() {
    final albumMap = <String, List<Song>>{};
    final artistMap = <String, List<Song>>{};

    // Set unificado: locales + downloads de streaming. Las descargas
    // tienen URI file:// y metadata original del track de YT (album,
    // artist, etc.) → encajan en los mismos buckets que los locales si
    // matchea el album+artist. Dedupe por id para no doblar canciones
    // cuando un archivo local y su versión streaming tienen el mismo id.
    final allSongs = <Song>[..._songs];
    final downloads = _downloads?.downloaded;
    if (downloads != null && downloads.isNotEmpty) {
      final seen = _songs.map((s) => s.id).toSet();
      for (final dl in downloads) {
        if (seen.add(dl.id)) allSongs.add(dl);
      }
    }

    for (final song in allSongs) {
      final albumKey = '${song.album}|${song.artist}';
      albumMap.putIfAbsent(albumKey, () => []).add(song);
      artistMap.putIfAbsent(song.artist, () => []).add(song);
    }

    _albums = albumMap.entries.map((e) {
      final songs = e.value;
      // Usamos el arte de la primera canción que tenga uno.
      final firstWithArt = songs.firstWhere((s) => s.inlineArtwork != null, orElse: () => songs.first);
      return Album(
        name: songs.first.album,
        artist: songs.first.artist,
        songs: songs,
        inlineArtwork: firstWithArt.inlineArtwork,
        thumbnailUrl: firstWithArt.thumbnailUrl,
      );
    }).toList();

    // Ordenar álbumes por nombre.
    _albums.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _artists = artistMap.entries.map((e) {
      final songs = e.value;
      final firstWithArt = songs.firstWhere((s) => s.inlineArtwork != null, orElse: () => songs.first);
      return Artist(
        name: e.key,
        songs: songs,
        thumbnailUrl: firstWithArt.thumbnailUrl,
      );
    }).toList();

    _artists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _downloads?.removeListener(_onDownloadsChanged);
    super.dispose();
  }
}
