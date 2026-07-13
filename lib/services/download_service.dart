import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings/settings_controller.dart';
import '../models/song.dart';
import 'app_storage.dart';
import 'mp3_transcoder.dart';
import 'streaming/streaming_service.dart';
import '../core/dev_log.dart';

/// Manages descargas offline de canciones de streaming.
///
/// **Por qué solo streaming**: las canciones locales ya están en disco; no
/// hay nada que descargar.
///
/// **Storage**: archivos en la carpeta pública de la app
/// (`Android/media/<pkg>/Vibra Music/`) cuando está disponible, así el
/// usuario puede verlos/copiarlos desde el explorador de archivos y otras
/// apps de música los indexan. En desktop/iOS cae a almacenamiento
/// interno. El mapa `songId → ruta + meta` se persiste en SharedPreferences
/// (key `vibra.downloads.v1`).
///
/// **Progreso**: durante una descarga `progressOf(songId)` devuelve 0..1 y
/// `notifyListeners()` se dispara cuando el progreso cambia significativamente
/// (cada ~5% para no inundar de rebuilds).
class DownloadService extends ChangeNotifier {
  DownloadService._(this._prefs, this._streaming, this._downloadsDir,
      Map<String, _DownloadedTrack> initial,
      {SettingsController? settings})
      : _settings = settings,
        _downloaded = initial;

  static const _kKey = 'vibra.downloads.v1';

  final SharedPreferences? _prefs;
  final StreamingService _streaming;
  final Directory _downloadsDir;

  /// Settings para leer `downloadAsMp3` en tiempo de descarga. Opcional
  /// (tests / plataformas sin settings) — sin él, se conserva el formato
  /// original del stream.
  final SettingsController? _settings;
  final Map<String, _DownloadedTrack> _downloaded;
  final Map<String, double> _inProgress = {};
  final Map<String, StreamSubscription<List<int>>> _activeSubs = {};

  /// Ruta de la carpeta donde viven las descargas. Útil para la UI de
  /// ajustes que muestra "tu música está en …".
  String get downloadsPath => _downloadsDir.path;

  /// True si las descargas están en una carpeta pública (visible en el
  /// explorador de archivos).
  bool get isPublicStorage => AppStorage.isInitialized
      ? AppStorage.instance.isPublicMusic
      : false;

  static Future<DownloadService> create(StreamingService streaming,
      {SettingsController? settings}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      devLog('DownloadService prefs load failed: $e');
    }

    // Carpeta destino: la pública de AppStorage (Android/media/<pkg>/…)
    // si está lista, sino un fallback interno.
    final storage = await AppStorage.init();
    final dir = Directory(storage.musicDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final raw = prefs?.getString(_kKey);
    final map = <String, _DownloadedTrack>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          var t = _DownloadedTrack.fromJson(
              entry.value as Map<String, dynamic>);
          // MIGRACIÓN: si la descarga está en una ruta vieja (interna) y
          // ahora tenemos carpeta pública, movemos el archivo. Así las
          // descargas previas también aparecen en el explorador sin que
          // el usuario tenga que re-descargar.
          t = await _migrateIfNeeded(t, dir);
          // Limpieza al cargar: si el archivo ya no existe físicamente
          // (storage limpiado, app reinstalada, etc.) lo descartamos para no
          // mostrar canciones "descargadas" inexistentes.
          if (await File(t.path).exists()) {
            map[entry.key] = t;
          }
        }
      } catch (e) {
        devLog('DownloadService parse failed: $e');
      }
    }

    final svc =
        DownloadService._(prefs, streaming, dir, map, settings: settings);
    // Persistir tras la migración para guardar las rutas nuevas.
    // ignore: discarded_futures
    svc._persist();
    return svc;
  }

  /// Mueve una descarga a la carpeta pública [targetDir] si su ruta actual
  /// no está ya ahí. Devuelve el track con la ruta actualizada (o el mismo
  /// si no hubo que mover / falló el move).
  static Future<_DownloadedTrack> _migrateIfNeeded(
      _DownloadedTrack t, Directory targetDir) async {
    // Ya está en la carpeta destino → nada que hacer.
    if (t.path.startsWith(targetDir.path)) return t;
    try {
      final src = File(t.path);
      if (!await src.exists()) return t;
      final name = t.path.split('/').last;
      final destPath = '${targetDir.path}/$name';
      // rename() cross-filesystem puede fallar (interno → externo son FS
      // distintos). Intentamos rename y si falla copiamos + borramos.
      File dest;
      try {
        dest = await src.rename(destPath);
      } catch (_) {
        dest = await src.copy(destPath);
        try {
          await src.delete();
        } catch (_) {}
      }
      devLog('DownloadService migrated ${t.song.title} → $destPath');
      // Notificar a MediaStore del archivo migrado.
      // ignore: discarded_futures
      AppStorage.instance.scanFile(dest.path);
      return _DownloadedTrack(
        song: t.song.copyWith(uri: 'file://${dest.path}'),
        path: dest.path,
        downloadedAt: t.downloadedAt,
      );
    } catch (e) {
      devLog('DownloadService migrate failed for ${t.song.title}: $e');
      return t;
    }
  }

  /// IDs de canciones descargadas. Útil para la UI.
  Iterable<String> get downloadedIds => _downloaded.keys;

  /// Lista de canciones descargadas (con metadata original + URI
  /// `file://...` apuntando al archivo local). Sirve a la biblioteca
  /// para mezclarlas con los archivos locales y agruparlas en
  /// álbumes/artistas.
  List<Song> get downloaded =>
      _downloaded.values.map((d) => d.song).toList(growable: false);

  bool isDownloaded(String songId) => _downloaded.containsKey(songId);
  String? localPath(String songId) => _downloaded[songId]?.path;
  Song? metadataOf(String songId) => _downloaded[songId]?.song;

  /// Progreso de una descarga en curso, o `null` si no se está descargando.
  double? progressOf(String songId) => _inProgress[songId];
  bool isDownloading(String songId) => _inProgress.containsKey(songId);

  Future<void> _persist() async {
    final out = <String, dynamic>{};
    for (final entry in _downloaded.entries) {
      out[entry.key] = entry.value.toJson();
    }
    try {
      await _prefs?.setString(_kKey, jsonEncode(out));
    } catch (e) {
      devLog('DownloadService persist failed: $e');
    }
  }

  /// Descarga una canción de streaming. Si ya está descargada o en curso,
  /// no hace nada (idempotente).
  Future<void> download(Song song) async {
    if (!song.isStreaming || song.streamingId == null) return;
    if (isDownloaded(song.id)) return;
    if (isDownloading(song.id)) return;

    _inProgress[song.id] = 0.0;
    notifyListeners();

    try {
      final url = await _streaming.resolveStreamUrl(song.streamingId!);
      // YouTube Music sirve audio típicamente como webm/opus o m4a/aac.
      // Inferimos la extensión del Content-Type real para reproducir bien.
      final tempPath = '${_downloadsDir.path}/${song.id}.part';
      final tempFile = File(tempPath);
      if (await tempFile.exists()) await tempFile.delete();

      final req = http.Request('GET', Uri.parse(url));
      final res = await http.Client().send(req);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final ext = _extFromContentType(res.headers['content-type']);
      var received = 0;
      var lastPct = -5;

      final sink = tempFile.openWrite();
      final completer = Completer<void>();
      final sub = res.stream.listen(
        (chunk) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            final pct = ((received / total) * 100).round();
            // Throttle: solo notify cuando el progreso avanza 5 puntos para
            // no inundar el árbol de rebuilds (cada chunk son 64KB).
            if (pct - lastPct >= 5) {
              lastPct = pct;
              _inProgress[song.id] = received / total;
              notifyListeners();
            }
          }
        },
        onDone: () async {
          await sink.flush();
          await sink.close();
          completer.complete();
        },
        onError: (e) async {
          await sink.close();
          completer.completeError(e);
        },
        cancelOnError: true,
      );
      _activeSubs[song.id] = sub;

      await completer.future;
      _activeSubs.remove(song.id);

      // Nombre de archivo LEGIBLE "Artista - Título.ext" en lugar del
      // songId opaco. Como ahora los archivos viven en una carpeta
      // pública que el usuario explora, un nombre entendible importa.
      // El songId va como sufijo corto para garantizar unicidad si dos
      // canciones tienen el mismo artista+título.
      String finalPath;

      // ── Transcode a MP3 (default ON) ──
      // El stream de YT llega como m4a/aac u opus/webm. Si el usuario
      // tiene "Descargar como MP3" activo, lo pasamos por el plugin
      // nativo (MediaCodec decode → LAME Java → ID3v2 con carátula).
      // Si el transcode FALLA por lo que sea, conservamos el original —
      // nunca perdemos una descarga completada por un fallo de conversión.
      final wantMp3 = (_settings?.value.downloadAsMp3 ?? false) &&
          Mp3Transcoder.isSupported;
      if (wantMp3) {
        // Señal a la UI de que estamos en la fase de conversión (la
        // barra queda casi llena — el encode puede tardar ~1-2 min).
        _inProgress[song.id] = 0.99;
        notifyListeners();
        finalPath = '${_downloadsDir.path}/${_safeFileName(song)}.mp3';
        String? coverTmp;
        try {
          coverTmp = await _fetchCoverToTemp(song);
          await Mp3Transcoder.transcode(
            inputPath: tempPath,
            outputPath: finalPath,
            title: song.title,
            artist: song.artist,
            // '—' es el placeholder de album de los tracks de streaming;
            // no lo escribimos como TALB basura.
            album: song.album == '—' ? '' : song.album,
            coverPath: coverTmp,
          );
          try {
            await tempFile.delete();
          } catch (_) {}
        } catch (e) {
          devLog('DownloadService: transcode MP3 falló para '
              '${song.title}, conservando original: $e');
          finalPath = '${_downloadsDir.path}/${_safeFileName(song)}$ext';
          await tempFile.rename(finalPath);
        } finally {
          if (coverTmp != null) {
            try {
              await File(coverTmp).delete();
            } catch (_) {}
          }
        }
      } else {
        finalPath = '${_downloadsDir.path}/${_safeFileName(song)}$ext';
        await tempFile.rename(finalPath);
      }

      _downloaded[song.id] = _DownloadedTrack(
        song: song.copyWith(uri: 'file://$finalPath'),
        path: finalPath,
        downloadedAt: DateTime.now(),
      );
      _inProgress.remove(song.id);
      notifyListeners();
      await _persist();
      // Notificar a MediaStore para que el archivo aparezca de inmediato
      // en el explorador y en otras apps de música.
      if (AppStorage.isInitialized) {
        // ignore: discarded_futures
        AppStorage.instance.scanFile(finalPath);
      }
    } catch (e) {
      devLog('DownloadService download ${song.id} failed: $e');
      _inProgress.remove(song.id);
      _activeSubs.remove(song.id);
      // Limpia el .part parcial.
      try {
        final part = File('${_downloadsDir.path}/${song.id}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
      notifyListeners();
      rethrow;
    }
  }

  /// Cancela una descarga en curso (libera el .part).
  Future<void> cancel(String songId) async {
    final sub = _activeSubs.remove(songId);
    await sub?.cancel();
    _inProgress.remove(songId);
    try {
      final part = File('${_downloadsDir.path}/$songId.part');
      if (await part.exists()) await part.delete();
    } catch (_) {}
    notifyListeners();
  }

  /// Elimina un archivo descargado del disco.
  Future<void> delete(String songId) async {
    final track = _downloaded.remove(songId);
    if (track != null) {
      try {
        final f = File(track.path);
        if (await f.exists()) await f.delete();
        // Notificar a MediaStore del borrado → desaparece del explorador
        // y de otras apps de música sin esperar el rescan del sistema.
        if (AppStorage.isInitialized) {
          // ignore: discarded_futures
          AppStorage.instance.scanFile(track.path);
        }
      } catch (e) {
        devLog('DownloadService delete file failed: $e');
      }
      notifyListeners();
      await _persist();
    }
  }

  /// Descarga la carátula de [song] a un archivo temporal (para incrustar
  /// en el MP3). Intenta subir la resolución del thumbnail de YT (que
  /// suele venir en 120px) reescribiendo el sufijo `wN-hN` a 544px.
  /// Devuelve null si no hay URL o el fetch falla — la carátula es
  /// opcional, nunca bloquea la descarga.
  Future<String?> _fetchCoverToTemp(Song song) async {
    var url = song.thumbnailUrl;
    if (url == null || url.isEmpty) return null;
    url = url.replaceAll(RegExp(r'w\d+-h\d+'), 'w544-h544');
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final safeId = song.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
      final tmp = File('${_downloadsDir.path}/.$safeId.cover');
      await tmp.writeAsBytes(res.bodyBytes);
      return tmp.path;
    } catch (e) {
      devLog('DownloadService: cover fetch falló: $e');
      return null;
    }
  }

  /// Nombre de archivo seguro y legible: "Artista - Título" saneado de
  /// caracteres inválidos en FAT/ext4 + un sufijo corto del songId para
  /// unicidad. Limitado a 120 chars para no exceder límites de nombre.
  static String _safeFileName(Song song) {
    final artist = song.artist.trim();
    final title = song.title.trim();
    var base = artist.isEmpty ? title : '$artist - $title';
    // Reemplaza caracteres inválidos en nombres de archivo por espacio.
    base = base.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), ' ');
    base = base.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (base.isEmpty) base = 'track';
    if (base.length > 100) base = base.substring(0, 100).trim();
    // Sufijo corto del id para unicidad (últimos 6 chars alfanuméricos).
    final idSuffix =
        song.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final tail =
        idSuffix.length > 6 ? idSuffix.substring(idSuffix.length - 6) : idSuffix;
    return tail.isEmpty ? base : '$base [$tail]';
  }

  static String _extFromContentType(String? ct) {
    if (ct == null) return '.m4a';
    final lc = ct.toLowerCase();
    if (lc.contains('webm') || lc.contains('opus')) return '.webm';
    if (lc.contains('mpeg')) return '.mp3';
    if (lc.contains('ogg')) return '.ogg';
    if (lc.contains('mp4') || lc.contains('aac')) return '.m4a';
    return '.m4a';
  }
}

class _DownloadedTrack {
  _DownloadedTrack({
    required this.song,
    required this.path,
    required this.downloadedAt,
  });

  final Song song;
  final String path;
  final DateTime downloadedAt;

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'path': path,
        'downloadedAt': downloadedAt.millisecondsSinceEpoch,
      };

  factory _DownloadedTrack.fromJson(Map<String, dynamic> m) =>
      _DownloadedTrack(
        song: Song.fromJson(m['song'] as Map<String, dynamic>),
        path: m['path'] as String,
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(
            (m['downloadedAt'] as num?)?.toInt() ?? 0),
      );
}
