import 'package:flutter/foundation.dart';

/// Detecta el formato de imagen leyendo los magic bytes del header.
///
/// Necesario porque Impeller + ImageDecoder nativo de Android NO soportan
/// HEIC/AVIF (devuelve "unimplemented"). Los archivos locales del usuario
/// pueden tener artwork embedido en estos formatos (típico de ripeos
/// recientes desde iPhone o de algunos rippers automatizados). Si pasamos
/// esos bytes a `Image.memory`, ImageDecoder falla y spamea el logcat con
/// `DecodeException` en cada rebuild.
///
/// Esta utilidad permite filtrar los bytes ANTES de construir el widget
/// → mostramos un placeholder en lugar de intentar decodificar formatos
/// que sabemos que fallarán.
enum ImageFormat { png, jpeg, webp, gif, bmp, heic, avif, unknown }

ImageFormat detectImageFormat(Uint8List bytes) {
  if (bytes.length < 12) return ImageFormat.unknown;

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return ImageFormat.png;
  }
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return ImageFormat.jpeg;
  }
  // GIF: 47 49 46 38
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return ImageFormat.gif;
  }
  // BMP: 42 4D
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return ImageFormat.bmp;
  }
  // RIFF (...) WEBP — los bytes 0..3 son "RIFF", 8..11 son "WEBP".
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return ImageFormat.webp;
  }
  // ISO Base Media File Format (HEIC, AVIF, MP4...): el chunk 4..7 es "ftyp".
  // El brand (8..11) determina el subformato.
  if (bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (brand.startsWith('hei') ||
        brand.startsWith('mif1') ||
        brand == 'msf1') {
      return ImageFormat.heic;
    }
    if (brand.startsWith('avif') || brand.startsWith('avis')) {
      return ImageFormat.avif;
    }
  }
  return ImageFormat.unknown;
}

/// Formatos que `dart:ui` + ImageDecoder nativo decodifican de forma fiable
/// en Android Impeller. Si un byte buffer no cae aquí, mejor mostrar
/// placeholder que arriesgar el "unimplemented" en logcat.
bool isDecodableImage(Uint8List bytes) {
  final fmt = detectImageFormat(bytes);
  return fmt == ImageFormat.png ||
      fmt == ImageFormat.jpeg ||
      fmt == ImageFormat.webp ||
      fmt == ImageFormat.gif ||
      fmt == ImageFormat.bmp;
}
