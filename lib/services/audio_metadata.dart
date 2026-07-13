import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/dev_log.dart';

/// Info técnica de formato de un archivo de audio local: codec, bit depth,
/// sample rate, canales, bitrate. Lo que un DAP audiophile muestra al lado
/// del cover ("FLAC · 24-bit / 96 kHz", "Hi-Res" badge, etc.).
///
/// Inmutable, serializable a String via [toString] para logs.
@immutable
class AudioFormatInfo {
  const AudioFormatInfo({
    required this.codec,
    required this.isLossless,
    this.bitDepth,
    this.sampleRateHz,
    this.channels,
    this.bitrateBps,
  });

  /// Etiqueta corta del codec: `FLAC`, `WAV`, `ALAC`, `MP3`, `AAC`, `OGG`,
  /// `DSD`, `AIFF`, `OPUS`, o `?` si no se pudo determinar.
  final String codec;

  /// True para formatos lossless (FLAC, WAV, ALAC, AIFF, DSD). False para
  /// lossy (MP3, AAC, OGG/Opus). El badge "Hi-Res" solo aplica a lossless.
  final bool isLossless;

  /// Bits por sample. 16, 24 o 32 típicamente. Null para lossy (concepto
  /// no aplica al cuantizado del codec) o cuando no se pudo leer.
  final int? bitDepth;

  /// Sample rate en Hz. 44100 (CD), 48000, 88200, 96000, 176400, 192000.
  final int? sampleRateHz;

  /// Número de canales: 1 mono, 2 estéreo, 6 5.1, etc.
  final int? channels;

  /// Bitrate efectivo del archivo en bits por segundo. Para lossless lo
  /// calculamos `bitDepth * sampleRate * channels`. Para lossy se lee del
  /// header del codec (no implementado aún → null).
  final int? bitrateBps;

  /// True cuando el archivo es lossless Y supera la calidad CD:
  /// bit depth ≥ 24 Y sample rate ≥ 88.2 kHz. Es la definición que usa
  /// la Japan Audio Society para el logo "Hi-Res Audio". DSD también
  /// cuenta como hi-res por su naturaleza.
  bool get isHiRes {
    if (codec == 'DSD') return true;
    if (!isLossless) return false;
    final bd = bitDepth;
    final sr = sampleRateHz;
    if (bd == null || sr == null) return false;
    return bd >= 24 && sr >= 88200;
  }

  /// Texto humano para chip/badge en el player.
  /// Ejemplos:
  ///   FLAC → "FLAC · 24-bit / 96 kHz"
  ///   MP3  → "MP3 · 320 kbps"  (cuando tengamos bitrate de lossy)
  ///   MP3 sin bitrate → "MP3"
  String get displayText {
    if (!isLossless) {
      if (bitrateBps != null) {
        return '$codec · ${(bitrateBps! / 1000).round()} kbps';
      }
      return codec;
    }
    if (bitDepth != null && sampleRateHz != null) {
      final sr = sampleRateHz!;
      // 44100 → "44.1 kHz", 96000 → "96 kHz". Mostramos decimales solo
      // cuando es necesario (44.1, 88.2, 176.4, etc.).
      final srKhz = sr / 1000;
      final srStr = (srKhz * 10).round() % 10 == 0
          ? '${srKhz.round()} kHz'
          : '${srKhz.toStringAsFixed(1)} kHz';
      return '$codec · $bitDepth-bit / $srStr';
    }
    return codec;
  }

  @override
  String toString() =>
      'AudioFormatInfo($codec, ${bitDepth ?? '?'}b/${sampleRateHz ?? '?'}Hz, '
      '${channels ?? '?'}ch, ${bitrateBps ?? '?'}bps, lossless=$isLossless, '
      'hiRes=$isHiRes)';
}

/// Lee información de formato del header del archivo SIN cargar todo el
/// audio en memoria. Soporta:
///   - **FLAC**: parser completo del bloque STREAMINFO.
///   - **WAV**: parser del chunk `fmt `.
///   - **ALAC** (en contenedor .m4a / .mp4): walking básico de atoms hasta
///     encontrar `alac`.
///   - **DSD** (.dsf): lectura del chunk `fmt ` del header DSF.
///   - **Resto** (MP3, AAC, OGG, AIFF, OPUS): se reconoce por extensión y
///     devolvemos codec + lossless flag, sin bit depth ni sample rate
///     (esos formatos requieren parsers más complejos que no son críticos
///     porque el usuario no los marketea como audiophile).
///
/// Hecho 100% en Dart sin plugins — todos los parsers leen los primeros
/// ~512 bytes del archivo, así que es barato (typical <2ms).
class AudioMetadataReader {
  /// Cache de resultados por path absoluto. Evita re-leer el mismo archivo
  /// cuando el usuario vuelve a una canción ya escuchada. Sin invalidación
  /// — el formato de un archivo no cambia mientras existe el path.
  static final Map<String, AudioFormatInfo?> _cache = {};

  /// Reads format info for [filePath]. Returns null on any error or for
  /// remote URIs (http, content://, etc.). El caller debe filtrar antes:
  /// solo llamar para archivos locales del filesystem.
  static Future<AudioFormatInfo?> read(String filePath) async {
    final cached = _cache[filePath];
    if (cached != null) return cached;
    if (_cache.containsKey(filePath)) return null; // miss negativa cacheada

    RandomAccessFile? raf;
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _cache[filePath] = null;
        return null;
      }

      // Leemos los primeros 4 KiB. Suficiente para FLAC STREAMINFO (38B
      // tras el magic), WAV fmt chunk (típicamente offset 12-40), y la
      // mayoría de atoms iniciales de MP4. Si necesitamos más bytes para
      // ALAC, el parser hace lecturas extra random-access.
      raf = await file.open();
      final fileSize = await raf.length();
      final headerLen = fileSize < 4096 ? fileSize : 4096;
      final header = Uint8List(headerLen);
      await raf.readInto(header);

      final ext = _extOf(filePath);

      AudioFormatInfo? info;
      // Orden importa: probamos magic numbers ANTES de la extensión porque
      // a veces los archivos vienen con extensión "engañosa" (.wav que en
      // realidad es FLAC dentro). Magic number es la verdad.
      if (_startsWith(header, _flacMagic)) {
        info = _parseFlac(header);
      } else if (_startsWith(header, _riffMagic) &&
          header.length >= 12 &&
          _startsWithAt(header, 8, _waveMagic)) {
        info = _parseWav(header);
      } else if (_startsWith(header, _id3Magic)) {
        // ID3v2 header al inicio → MP3 (o WAV con ID3 raro, pero en práctica MP3).
        info = const AudioFormatInfo(codec: 'MP3', isLossless: false);
      } else if (_isMp4(header)) {
        info = await _parseMp4(raf, header, fileSize);
      } else if (_startsWith(header, _dsfMagic)) {
        info = _parseDsf(header);
      } else if (_startsWith(header, _formMagic) &&
          header.length >= 12 &&
          (_startsWithAt(header, 8, _aiffMagic) ||
              _startsWithAt(header, 8, _aifcMagic))) {
        info = _parseAiff(header);
      } else if (_startsWith(header, _oggMagic)) {
        // OGG container: puede tener Vorbis (lossy) o FLAC (lossless).
        // Detectar el codec interno requiere parsear las páginas Ogg, que es
        // verboso. Para v1, marcamos genérico — la extensión .oga/.opus
        // ayuda a inferir.
        if (ext == 'opus') {
          info = const AudioFormatInfo(codec: 'Opus', isLossless: false);
        } else {
          info = const AudioFormatInfo(codec: 'OGG', isLossless: false);
        }
      } else {
        // Cae por extensión cuando no reconocemos magic.
        info = _inferFromExtension(ext);
      }

      _cache[filePath] = info;
      return info;
    } catch (e) {
      devLog('AudioMetadataReader.read($filePath) failed: $e');
      _cache[filePath] = null;
      return null;
    } finally {
      // finally garantiza el close incluso si un parser lanza — sin esto,
      // cada archivo corrupto filtraba un file descriptor. Con suficientes
      // archivos malos en la librería, el proceso agota su límite de fds
      // y TODA la app empieza a fallar (sockets incluidos) sin error claro.
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// Limpia el cache (ej: rescan de librería). No invalida files individuales
  /// porque el formato no cambia para un path estable.
  static void clearCache() => _cache.clear();

  // ───────────────────── FLAC ─────────────────────

  /// FLAC layout: `fLaC` (4B) → METADATA_BLOCK_HEADER (4B) → STREAMINFO (34B).
  /// STREAMINFO empieza en offset 8. Estructura (big-endian, bit-packed):
  ///   16b min block size
  ///   16b max block size
  ///   24b min frame size
  ///   24b max frame size
  ///   20b sample rate
  ///    3b channels - 1
  ///    5b bits per sample - 1
  ///   36b total samples
  ///  128b MD5 signature
  /// Nos interesan los bits 80–139 (offset 18–21 + parte del 22).
  static AudioFormatInfo? _parseFlac(Uint8List b) {
    if (b.length < 8 + 34) return null;
    // STREAMINFO en offset 8 (cabecera de bloque) + 4 bytes de header = offset 12.
    // Pero el bloque header son 4 bytes (1B tipo + 3B size), así que el cuerpo
    // de STREAMINFO arranca en offset 12. Sample rate son los siguientes
    // bytes 18-20 (después de min/max block + min/max frame).
    const off = 12;
    // Bytes 0-1: min block
    // Bytes 2-3: max block
    // Bytes 4-6: min frame (24b)
    // Bytes 7-9: max frame (24b)
    // Bytes 10-11 + 4 bits del 12: sample rate (20b)
    // Bits 4-6 del byte 12: channels-1 (3b)
    // Bits 7 del 12 + 4 bits del 13: bits per sample - 1 (5b)
    if (b.length < off + 14) return null;
    final sr = ((b[off + 10] << 12) |
            (b[off + 11] << 4) |
            ((b[off + 12] & 0xF0) >> 4))
        .toInt();
    final ch = ((b[off + 12] & 0x0E) >> 1) + 1;
    final bps = (((b[off + 12] & 0x01) << 4) | ((b[off + 13] & 0xF0) >> 4)) + 1;
    final bitrate = bps * sr * ch;
    return AudioFormatInfo(
      codec: 'FLAC',
      isLossless: true,
      bitDepth: bps,
      sampleRateHz: sr,
      channels: ch,
      bitrateBps: bitrate,
    );
  }

  // ───────────────────── WAV ─────────────────────

  /// WAV: RIFF(4) + size(4) + WAVE(4) + chunks. El chunk `fmt ` típicamente
  /// está justo después (offset 12), pero puede haber `JUNK` u otros antes;
  /// hay que escanear.
  static AudioFormatInfo? _parseWav(Uint8List b) {
    var off = 12;
    while (off + 8 <= b.length) {
      // Chunk ID (4) + size (4 LE).
      final id = String.fromCharCodes(b.sublist(off, off + 4));
      final size = b[off + 4] |
          (b[off + 5] << 8) |
          (b[off + 6] << 16) |
          (b[off + 7] << 24);
      if (id == 'fmt ') {
        if (off + 8 + 16 > b.length) return null;
        final fmt = off + 8;
        final audioFormat = b[fmt] | (b[fmt + 1] << 8);
        final ch = b[fmt + 2] | (b[fmt + 3] << 8);
        final sr = b[fmt + 4] |
            (b[fmt + 5] << 8) |
            (b[fmt + 6] << 16) |
            (b[fmt + 7] << 24);
        final bps = b[fmt + 14] | (b[fmt + 15] << 8);
        // audioFormat 1 = PCM, 3 = IEEE float, 0xFFFE = extensible.
        // Todos son lossless en práctica.
        return AudioFormatInfo(
          codec: audioFormat == 3 ? 'WAV (Float)' : 'WAV',
          isLossless: true,
          bitDepth: bps,
          sampleRateHz: sr,
          channels: ch,
          bitrateBps: bps * sr * ch,
        );
      }
      off += 8 + size + (size.isOdd ? 1 : 0); // padding a múltiplo de 2
    }
    return null;
  }

  // ───────────────────── ALAC / M4A ─────────────────────

  /// MP4 atom walking: leemos atoms top-level hasta encontrar `moov`, luego
  /// recursivamente bajamos hasta `stsd` y leemos el primer sample entry,
  /// que para audio contiene el codec FourCC (`alac` o `mp4a`) seguido del
  /// header con sample rate.
  ///
  /// Estructura típica para audio:
  ///   ftyp(8B) → free/mdat/moov → moov → trak → mdia → minf → stbl →
  ///   stsd → entry(8B header + 8B reserved + 2B channels + 2B sample size
  ///   + 4B reserved + 4B sample rate fixed-point)
  ///
  /// Implementación simplificada: buscamos el FourCC `alac` o `mp4a` en
  /// los primeros 64 KiB; cuando lo encontramos, leemos los 16 bytes
  /// siguientes para extraer channels/bit depth/sample rate (formato de
  /// AudioSampleEntry de QuickTime).
  static Future<AudioFormatInfo?> _parseMp4(
      RandomAccessFile raf, Uint8List head, int fileSize) async {
    // Cargamos hasta 64 KiB para buscar los atoms relevantes. La mayoría de
    // moov está dentro de los primeros 32 KiB en archivos faststart.
    final scanLen = fileSize < 65536 ? fileSize : 65536;
    Uint8List buf = head;
    if (scanLen > head.length) {
      await raf.setPosition(0);
      buf = Uint8List(scanLen);
      await raf.readInto(buf);
    }

    final alacIdx = _indexOf(buf, _alacFourcc);
    final mp4aIdx = _indexOf(buf, _mp4aFourcc);
    // Preferimos ALAC si está; si no, mp4a (AAC).
    final isAlac = alacIdx >= 0;
    final idx = isAlac ? alacIdx : mp4aIdx;
    if (idx < 0) {
      // No detectamos codec → fallback genérico M4A.
      return const AudioFormatInfo(codec: 'M4A', isLossless: false);
    }

    // AudioSampleEntry (QTFF / ISO 14496-12):
    //   FourCC (4) + 6 reserved + 2 data ref index + 8 reserved (version+...)
    //   + 2 channels + 2 sample size + 2 pre-defined + 2 reserved
    //   + 4 sample rate (16.16 fixed)
    final entryOff = idx; // FourCC
    // Sample rate viene en offset entryOff + 24 (típico).
    if (entryOff + 28 > buf.length) {
      return AudioFormatInfo(codec: isAlac ? 'ALAC' : 'AAC', isLossless: isAlac);
    }
    final channels = (buf[entryOff + 16] << 8) | buf[entryOff + 17];
    final bps = (buf[entryOff + 18] << 8) | buf[entryOff + 19];
    final srHi = (buf[entryOff + 24] << 8) | buf[entryOff + 25];
    // sample rate es 16.16 fixed; solo nos interesa la parte entera (16 bits altos).
    return AudioFormatInfo(
      codec: isAlac ? 'ALAC' : 'AAC',
      isLossless: isAlac,
      bitDepth: isAlac ? bps : null,
      sampleRateHz: srHi,
      channels: channels,
      bitrateBps: isAlac ? bps * srHi * channels : null,
    );
  }

  // ───────────────────── DSD (.dsf) ─────────────────────

  /// DSF: `DSD ` chunk (28B) + `fmt ` chunk con formato.
  /// fmt layout (LE):
  ///   4B id "fmt "
  ///   8B chunk size
  ///   4B format version (1)
  ///   4B format id (0 = DSD raw)
  ///   4B channel type
  ///   4B channel num
  ///   4B sampling frequency
  ///   4B bits per sample (1 para DSD)
  static AudioFormatInfo? _parseDsf(Uint8List b) {
    // DSD chunk son 28 bytes; fmt empieza en offset 28.
    const fmtOff = 28;
    if (b.length < fmtOff + 28) return null;
    // Verificamos "fmt " ID.
    if (b[fmtOff] != 0x66 ||
        b[fmtOff + 1] != 0x6D ||
        b[fmtOff + 2] != 0x74 ||
        b[fmtOff + 3] != 0x20) {
      return null;
    }
    final channels = _u32le(b, fmtOff + 24);
    final sr = _u32le(b, fmtOff + 28);
    // DSD64 = 2.8224 MHz, DSD128 = 5.6448 MHz, etc. Mostramos la frecuencia
    // real en displayText vía override del codec.
    final mhz = sr / 1000000;
    final dsdRate = mhz < 3
        ? 'DSD64'
        : (mhz < 6 ? 'DSD128' : (mhz < 12 ? 'DSD256' : 'DSD512'));
    return AudioFormatInfo(
      codec: dsdRate,
      isLossless: true,
      sampleRateHz: sr,
      channels: channels,
      // bit depth de DSD es 1, pero ponerlo como "1-bit" en la UI confunde
      // — el usuario espera "DSD64 / 2.8 MHz" no "1-bit". Lo dejamos null
      // y dejamos que displayText derive el formato del codec.
      bitDepth: null,
    );
  }

  // ───────────────────── AIFF ─────────────────────

  /// AIFF: FORM(4) + size(4) + AIFF/AIFC(4) + chunks. Buscamos `COMM`.
  /// COMM layout: 2B channels, 4B numSampleFrames, 2B sampleSize, 10B sampleRate (80-bit extended IEEE).
  static AudioFormatInfo? _parseAiff(Uint8List b) {
    var off = 12;
    while (off + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(off, off + 4));
      final size = (b[off + 4] << 24) |
          (b[off + 5] << 16) |
          (b[off + 6] << 8) |
          b[off + 7];
      if (id == 'COMM') {
        if (off + 8 + 18 > b.length) return null;
        final c = off + 8;
        final ch = (b[c] << 8) | b[c + 1];
        final bps = (b[c + 6] << 8) | b[c + 7];
        // 80-bit IEEE 754 extended → solo necesitamos parte significativa.
        // Para sample rates audio (8000-192000), los bits relevantes están
        // en exponente + primeros bytes de la mantisa.
        final sr = _ieee80ToInt(b.sublist(c + 8, c + 18));
        return AudioFormatInfo(
          codec: 'AIFF',
          isLossless: true,
          bitDepth: bps,
          sampleRateHz: sr,
          channels: ch,
          bitrateBps: sr * bps * ch,
        );
      }
      off += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  // ───────────────────── Helpers ─────────────────────

  static AudioFormatInfo _inferFromExtension(String ext) {
    switch (ext) {
      case 'flac':
        return const AudioFormatInfo(codec: 'FLAC', isLossless: true);
      case 'wav':
        return const AudioFormatInfo(codec: 'WAV', isLossless: true);
      case 'alac':
      case 'm4a':
      case 'mp4':
        return const AudioFormatInfo(codec: 'M4A', isLossless: false);
      case 'mp3':
        return const AudioFormatInfo(codec: 'MP3', isLossless: false);
      case 'aac':
        return const AudioFormatInfo(codec: 'AAC', isLossless: false);
      case 'ogg':
      case 'oga':
        return const AudioFormatInfo(codec: 'OGG', isLossless: false);
      case 'opus':
        return const AudioFormatInfo(codec: 'Opus', isLossless: false);
      case 'aiff':
      case 'aif':
        return const AudioFormatInfo(codec: 'AIFF', isLossless: true);
      case 'dsf':
      case 'dff':
        return const AudioFormatInfo(codec: 'DSD', isLossless: true);
      default:
        return AudioFormatInfo(
            codec: ext.toUpperCase(), isLossless: false);
    }
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '';
    return path.substring(i + 1).toLowerCase();
  }

  static bool _startsWith(Uint8List src, List<int> needle) {
    if (src.length < needle.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (src[i] != needle[i]) return false;
    }
    return true;
  }

  static bool _startsWithAt(Uint8List src, int off, List<int> needle) {
    if (src.length < off + needle.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (src[off + i] != needle[i]) return false;
    }
    return true;
  }

  static int _indexOf(Uint8List src, List<int> needle) {
    final max = src.length - needle.length;
    outer:
    for (var i = 0; i <= max; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (src[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static int _u32le(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  /// MP4 magic detection: el primer atom debe ser `ftyp` con compatibilidad
  /// para `mp4a` / `M4A ` / `isom`. Conservadores: solo true si hay un
  /// `ftyp` atom al inicio.
  static bool _isMp4(Uint8List b) {
    if (b.length < 12) return false;
    // Offset 4-7 debe ser "ftyp".
    return b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70;
  }

  /// IEEE 80-bit extended float → int. Para sample rates típicos (8k-192k)
  /// el valor es entero positivo, así que extracción simplificada vale.
  static int _ieee80ToInt(Uint8List b) {
    final exponent = (((b[0] & 0x7F) << 8) | b[1]) - 16383;
    // Mantissa son 64 bits (b[2..9]); para valores típicos solo nos importan
    // los bits altos. Construimos uint64 con la mantissa.
    var mantissa = 0;
    for (var i = 0; i < 8; i++) {
      mantissa = (mantissa << 8) | b[2 + i];
    }
    if (exponent < 0) return 0;
    // El bit más alto de la mantissa es 1 explícito en formato extended.
    // mantissa shift = 63 - exponent (para integer truncation).
    final shift = 63 - exponent;
    if (shift < 0 || shift > 63) return 0;
    return (mantissa >> shift);
  }

  // Magic numbers.
  static const _flacMagic = [0x66, 0x4C, 0x61, 0x43]; // "fLaC"
  static const _riffMagic = [0x52, 0x49, 0x46, 0x46]; // "RIFF"
  static const _waveMagic = [0x57, 0x41, 0x56, 0x45]; // "WAVE"
  static const _id3Magic = [0x49, 0x44, 0x33]; // "ID3"
  static const _formMagic = [0x46, 0x4F, 0x52, 0x4D]; // "FORM" (AIFF)
  static const _aiffMagic = [0x41, 0x49, 0x46, 0x46]; // "AIFF"
  static const _aifcMagic = [0x41, 0x49, 0x46, 0x43]; // "AIFC"
  static const _oggMagic = [0x4F, 0x67, 0x67, 0x53]; // "OggS"
  static const _dsfMagic = [0x44, 0x53, 0x44, 0x20]; // "DSD "
  static const _alacFourcc = [0x61, 0x6C, 0x61, 0x63]; // "alac"
  static const _mp4aFourcc = [0x6D, 0x70, 0x34, 0x61]; // "mp4a"
}
