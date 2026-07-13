import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/dev_log.dart';

/// Wrapper Dart del plugin nativo `vibra/mp3` (Mp3TranscoderPlugin.kt).
///
/// Transcodifica el audio descargado de YT Music (m4a/opus) a MP3 256kbps
/// con metadata ID3v2.3 incrustada (título, artista, álbum, carátula).
/// Pipeline nativo: MediaCodec decode → WAV → jump3r (LAME Java) → ID3.
///
/// Solo Android. En otras plataformas [isAvailable] devuelve false y el
/// caller debe conservar el formato original.
class Mp3Transcoder {
  Mp3Transcoder._();

  static const _channel = MethodChannel('vibra/mp3');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<bool> isAvailable() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Transcodifica [inputPath] → [outputPath] (debe terminar en .mp3) con
  /// la metadata dada. [coverPath] es un archivo de imagen local opcional
  /// (JPEG/PNG/WebP) que se incrusta como front cover.
  ///
  /// El trabajo corre en un hilo nativo — puede tardar 1-3 minutos por
  /// canción según el hardware (jump3r es LAME en Java, más lento que el
  /// nativo). Lanza en error; devuelve la ruta final en éxito.
  static Future<String> transcode({
    required String inputPath,
    required String outputPath,
    required String title,
    required String artist,
    required String album,
    String? coverPath,
    int bitrateKbps = 256,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Mp3Transcoder solo disponible en Android');
    }
    devLog('[MP3] transcoding $inputPath → $outputPath @ ${bitrateKbps}kbps');
    final res = await _channel.invokeMethod<String>('transcode', {
      'input': inputPath,
      'output': outputPath,
      'title': title,
      'artist': artist,
      'album': album,
      'coverPath': coverPath,
      'bitrateKbps': bitrateKbps,
    });
    if (res == null) {
      throw StateError('transcode devolvió null');
    }
    devLog('[MP3] transcode OK → $res');
    return res;
  }
}
