import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/dev_log.dart';

/// Rutas de almacenamiento de la app, resueltas UNA vez al arranque.
///
/// En Android usa el platform channel `vibra/storage` para obtener las
/// carpetas de sistema propias de la app:
///   - [mediaDir]   → `Android/media/<pkg>` (PÚBLICA, visible en file managers)
///   - [filesDir]   → `Android/data/<pkg>/files` (sandboxed en A11+)
///   - [obbDir]     → `Android/obb/<pkg>`
///   - [musicDir]   → `Android/media/<pkg>/Vibra Music` (destino de descargas)
///
/// En plataformas non-Android (o si el channel falla) cae a
/// `getApplicationDocumentsDirectory()` — almacenamiento interno privado.
/// La app sigue funcionando; solo que las descargas no serían visibles
/// desde fuera (aceptable en desktop/iOS donde no hay "Android/media").
class AppStorage {
  AppStorage._({
    required this.mediaDir,
    required this.filesDir,
    required this.obbDir,
    required this.musicDir,
    required this.isPublicMusic,
  });

  static const _channel = MethodChannel('vibra/storage');

  /// `Android/media/<pkg>` o null si no disponible.
  final String? mediaDir;

  /// `Android/data/<pkg>/files` o null.
  final String? filesDir;

  /// `Android/obb/<pkg>` o null.
  final String? obbDir;

  /// Carpeta donde van las descargas. Nunca null (siempre hay un fallback).
  final String musicDir;

  /// True si [musicDir] es una ubicación pública (visible en el explorador
  /// de archivos). False si cayó al fallback interno privado.
  final bool isPublicMusic;

  static AppStorage? _instance;
  static AppStorage get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('AppStorage.init() no fue llamado todavía');
    }
    return i;
  }

  static bool get isInitialized => _instance != null;

  /// Resuelve las rutas + crea las carpetas de sistema. Idempotente.
  static Future<AppStorage> init() async {
    if (_instance != null) return _instance!;

    // Fallback interno para non-Android o si el channel revienta.
    Future<AppStorage> fallback() async {
      final docs = await getApplicationDocumentsDirectory();
      final music = Directory('${docs.path}/downloads');
      if (!await music.exists()) await music.create(recursive: true);
      return AppStorage._(
        mediaDir: null,
        filesDir: docs.path,
        obbDir: null,
        musicDir: music.path,
        isPublicMusic: false,
      );
    }

    if (kIsWeb || !Platform.isAndroid) {
      _instance = await fallback();
      return _instance!;
    }

    try {
      final res = await _channel
          .invokeMapMethod<String, String?>('ensureAppDirs');
      final music = res?['music'];
      if (music == null || music.isEmpty) {
        // La media dir no está disponible (sin almacenamiento externo
        // montado, ROM rara). Caemos al interno.
        devLog('AppStorage: media dir null, using internal fallback');
        _instance = await fallback();
        return _instance!;
      }
      // Garantizamos que la carpeta de música exista desde Dart también
      // (el channel ya la crea, pero doble check no daña).
      final dir = Directory(music);
      if (!await dir.exists()) await dir.create(recursive: true);
      _instance = AppStorage._(
        mediaDir: res?['media'],
        filesDir: res?['files'],
        obbDir: res?['obb'],
        musicDir: music,
        isPublicMusic: true,
      );
      devLog('AppStorage ready: music=$music public=true');
      return _instance!;
    } catch (e) {
      devLog('AppStorage.init channel failed: $e — fallback interno');
      _instance = await fallback();
      return _instance!;
    }
  }

  /// Notifica a MediaStore que un archivo nuevo existe → aparece de
  /// inmediato en exploradores y otras apps de música. No-op fuera de
  /// Android.
  Future<void> scanFile(String path) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('scanFile', {'path': path});
    } catch (e) {
      devLog('AppStorage.scanFile failed: $e');
    }
  }
}
