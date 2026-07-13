import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/dev_log.dart';

/// Decodifica archivos DSD (.dsf) a PCM WAV para reproducción con
/// `just_audio` — ExoPlayer no soporta DSD nativamente.
///
/// **Arquitectura honesta:**
///
/// DSD (Direct Stream Digital) es audio de 1 bit muestreado a frecuencias
/// muy altas (2.8224 MHz para DSD64, 5.6448 para DSD128, etc.). Para
/// reproducir necesitamos convertir a PCM multi-bit, lo cual requiere
/// un filtro pasa-bajos para eliminar el ruido de cuantización que DSD
/// distribuye sobre los 20 kHz audibles.
///
/// Esta implementación:
///   - **Parser** del header DSF (chunk DSD + chunk fmt + chunk data).
///   - **FIR pasa-bajos** de 96 taps con ventana Hann, decimación 16:1
///     (DSD64 2.8224MHz → PCM 176.4kHz). Cutoff a 20 kHz.
///   - **Output PCM 24-bit / 176.4 kHz** (estándar para DSD64 → PCM).
///   - Corre en `Isolate` via `compute()` para no congelar el UI thread.
///   - Cache en `getTemporaryDirectory()` con clave SHA-1 del (path, mtime,
///     fileSize). Si el archivo cambia o se mueve, se re-decodifica.
///
/// **Lo que NO entrega esta versión** (en honor a la verdad):
///   - **Calidad audiófila bit-perfect**: el FIR 96-tap es bueno pero no
///     compite con `dsd2pcm` de Sebastian Gesemann (gold standard). Para
///     eso hace falta JNI a una librería C.
///   - **.dff (DSDIFF)**: el container viejo, solo .dsf por ahora.
///   - **DoP (DSD over PCM)** a DAC USB externo: requiere driver USB
///     Audio Class propio, fuera del scope de la app.
///   - **Cache LRU**: el cache se trim sólo cuando supera 1 GB total, no
///     hay tracking de uso por archivo. Suficiente para uso típico.
class DsdDecoder {
  DsdDecoder._();

  /// Cache directory donde viven los WAVs decodificados.
  static Directory? _cacheDir;

  static Future<Directory> _getCacheDir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/dsd_pcm_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  /// True si [filePath] es un archivo DSD que necesita decode (por extensión).
  static bool isDsdFile(String filePath) {
    final lower = filePath.toLowerCase();
    return lower.endsWith('.dsf') || lower.endsWith('.dff');
  }

  /// Resuelve [dsdPath] a un WAV PCM listo para `just_audio`. Si ya está
  /// cacheado, devuelve el path al instante. Si no, decodifica en isolate.
  ///
  /// Devuelve null en error (parser falla, formato no soportado, etc.).
  /// El caller debe caer a su flow normal (probablemente loggear y skip).
  static Future<String?> resolveToPcm(String dsdPath) async {
    try {
      final source = File(dsdPath);
      if (!await source.exists()) return null;

      // Clave del cache: hash de (path absoluto + mtime + size). Si el
      // usuario reemplaza el archivo en mismo path, se re-decodifica.
      final stat = await source.stat();
      final key = sha1
          .convert(utf8.encode(
              '$dsdPath|${stat.modified.millisecondsSinceEpoch}|${stat.size}'))
          .toString();
      final dir = await _getCacheDir();
      final outPath = '${dir.path}/$key.wav';
      final outFile = File(outPath);
      if (await outFile.exists()) {
        return outPath;
      }

      // Decode en isolate para no bloquear UI con la FIR convolution
      // (puede tardar varios segundos en archivos largos).
      final ok = await compute(_decodeIsolate, _DecodeJob(
        srcPath: dsdPath,
        dstPath: outPath,
      ));
      if (!ok) {
        // Limpiamos cualquier archivo parcial.
        if (await outFile.exists()) {
          await outFile.delete();
        }
        return null;
      }

      // Trim del cache si pasamos de 1 GB total.
      // ignore: discarded_futures
      _maybeTrimCache(dir);

      return outPath;
    } catch (e) {
      devLog('DsdDecoder.resolveToPcm failed: $e');
      return null;
    }
  }

  /// Trim sencillo del cache: si excede 1 GB, borra los archivos más viejos
  /// hasta bajar de 800 MB. No es LRU real (no trackeamos uso), pero el
  /// `mtime` del archivo se actualiza cada vez que decodificamos uno nuevo,
  /// así que aproxima "menos usado recientemente".
  static Future<void> _maybeTrimCache(Directory dir) async {
    const limitBytes = 1024 * 1024 * 1024; // 1 GB
    const targetBytes = 800 * 1024 * 1024; // bajar a 800 MB
    try {
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      var total = 0;
      final stats = <(File, FileStat)>[];
      for (final f in files) {
        final st = await f.stat();
        stats.add((f, st));
        total += st.size;
      }
      if (total < limitBytes) return;
      // Ordenamos por mtime ascendente — borramos los más viejos primero.
      stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      var i = 0;
      while (total > targetBytes && i < stats.length) {
        try {
          await stats[i].$1.delete();
          total -= stats[i].$2.size;
        } catch (_) {}
        i++;
      }
    } catch (e) {
      devLog('DsdDecoder cache trim failed: $e');
    }
  }
}

// ───────────────── Isolate worker ─────────────────

/// Job que viaja al isolate via `compute()`. Solo paths (strings), no
/// referencias a objetos compartidos.
class _DecodeJob {
  const _DecodeJob({required this.srcPath, required this.dstPath});
  final String srcPath;
  final String dstPath;
}

/// Worker que corre en otro isolate. Lee el .dsf, decodifica, escribe el
/// .wav. Returns true en éxito.
bool _decodeIsolate(_DecodeJob job) {
  try {
    final src = File(job.srcPath).openSync(mode: FileMode.read);
    try {
      return _decodeDsfToWav(src, job.dstPath);
    } finally {
      src.closeSync();
    }
  } catch (e) {
    // No tenemos devLog en isolate; printeamos a stderr para `adb logcat`.
    // ignore: avoid_print
    print('DSD decode isolate failed: $e');
    return false;
  }
}

bool _decodeDsfToWav(RandomAccessFile raf, String dstPath) {
  // ─── DSF header parsing ───
  // DSF layout:
  //   "DSD " chunk (28 bytes): magic + chunk size + total file size + metadata ptr
  //   "fmt " chunk (52 bytes): format version, format id, channel info,
  //                            sample rate, bits per sample (always 1 for DSD),
  //                            sample count, block size per channel (always 4096),
  //                            reserved
  //   "data" chunk: header (12 bytes) + raw DSD samples
  raf.setPositionSync(0);
  final dsdChunk = raf.readSync(28);
  if (dsdChunk[0] != 0x44 ||
      dsdChunk[1] != 0x53 ||
      dsdChunk[2] != 0x44 ||
      dsdChunk[3] != 0x20) {
    // ignore: avoid_print
    print('Not a DSF file (missing DSD magic)');
    return false;
  }

  final fmtHeader = raf.readSync(12);
  if (fmtHeader[0] != 0x66 ||
      fmtHeader[1] != 0x6D ||
      fmtHeader[2] != 0x74 ||
      fmtHeader[3] != 0x20) {
    // ignore: avoid_print
    print('Missing fmt chunk');
    return false;
  }
  final fmtSize = _u64le(fmtHeader, 4); // chunk size including header
  // Resto del fmt chunk: 40 bytes de contenido (52 total - 12 header).
  final fmtBody = raf.readSync((fmtSize - 12).toInt());
  // formatVersion(4) + formatId(4) + channelType(4) + channelNum(4)
  // + samplingFreq(4) + bitsPerSample(4) + sampleCount(8) + blockSize(4)
  // + reserved(4)
  final channels = _u32le(fmtBody, 12);
  final sampleRate = _u32le(fmtBody, 16);
  final bitsPerSample = _u32le(fmtBody, 20);
  final sampleCountPerChannel = _u64le(fmtBody, 24);
  final blockSizePerChannel = _u32le(fmtBody, 32);

  if (bitsPerSample != 1) {
    // ignore: avoid_print
    print('Not 1-bit DSD (bitsPerSample=$bitsPerSample)');
    return false;
  }

  // Decimación 16:1 para DSD64. Para DSD128 sería 32:1, DSD256 64:1.
  // sampleRate / 176400 da el factor — usamos esa relación.
  // 2822400 / 176400 = 16, 5644800 / 176400 = 32, etc.
  const targetPcmRate = 176400;
  final decim = sampleRate ~/ targetPcmRate;
  if (decim < 8 || decim > 64 || sampleRate % targetPcmRate != 0) {
    // ignore: avoid_print
    print('Unusual DSD rate $sampleRate; decim=$decim. Skipping.');
    return false;
  }

  // ─── Data chunk ───
  final dataHeader = raf.readSync(12);
  if (dataHeader[0] != 0x64 ||
      dataHeader[1] != 0x61 ||
      dataHeader[2] != 0x74 ||
      dataHeader[3] != 0x61) {
    // ignore: avoid_print
    print('Missing data chunk');
    return false;
  }
  final dataSize = _u64le(dataHeader, 4) - 12; // exclude header
  final dataStartOffset = raf.positionSync();

  // ─── FIR coefficients ───
  // Hann-windowed sinc low-pass. Cutoff ~20 kHz a la frecuencia DSD original.
  final firTaps = 96;
  final fir = _makeFir(
    cutoffHz: 20000.0,
    sampleRateHz: sampleRate.toDouble(),
    taps: firTaps,
  );

  // ─── Output WAV preparation ───
  // PCM 24-bit, sampleRate=176400, channels=<from source>.
  final outFile = File(dstPath).openSync(mode: FileMode.write);
  try {
    // Calculamos sampleCount de salida.
    final outSamplesPerChannel = sampleCountPerChannel ~/ decim;
    final outBytes = outSamplesPerChannel * channels * 3;
    final wavHeader = _makeWavHeader(
      channels: channels,
      sampleRate: targetPcmRate,
      bitsPerSample: 24,
      dataSize: outBytes,
    );
    outFile.writeFromSync(wavHeader);

    // ─── Convolution + decimation loop ───
    // DSD samples están organizados en BLOQUES por canal. Cada bloque son
    // `blockSizePerChannel` bytes consecutivos para el canal 0, luego
    // `blockSizePerChannel` bytes para canal 1, etc. Repetir hasta agotar.
    //
    // Dentro de un byte, los bits están en orden LSB-first (bit 0 = primer
    // sample temporal). Cada bit es 0 = -1, 1 = +1.
    //
    // Para hacer el FIR + decimación: por canal, mantenemos un buffer
    // circular con los últimos `firTaps` samples (±1.0), y cada `decim`
    // samples computamos la salida PCM como dot product con `fir`.

    // Buffers por canal.
    final ringBuffers = List<Float64List>.generate(
        channels, (_) => Float64List(firTaps));
    final ringPositions = List<int>.filled(channels, 0);
    final outSamples = List<int>.filled(channels, 0);

    raf.setPositionSync(dataStartOffset);
    final blockBuf = Uint8List(blockSizePerChannel * channels);
    var remaining = dataSize;
    // Buffer para escribir bytes PCM en chunks (no llamada a writeFromSync
    // por cada sample → muy lento). Tamaño = 1 segundo de PCM aprox.
    final pcmOutBuf = BytesBuilder(copy: false);
    const pcmFlushThreshold = 256 * 1024; // 256 KiB chunks

    while (remaining > 0) {
      final readSize = remaining < blockBuf.length ? remaining : blockBuf.length;
      raf.readIntoSync(blockBuf, 0, readSize);
      remaining -= readSize;

      // Procesamos canal por canal. Cada canal ocupa
      // `blockSizePerChannel` bytes en `blockBuf`.
      for (var ch = 0; ch < channels; ch++) {
        final chStart = ch * blockSizePerChannel;
        final chEnd = chStart + blockSizePerChannel;
        final ring = ringBuffers[ch];
        var pos = ringPositions[ch];
        var sCounter = outSamples[ch];

        for (var bytePos = chStart;
            bytePos < chEnd && bytePos < chStart + (readSize ~/ channels);
            bytePos++) {
          final byte = blockBuf[bytePos];
          // Bit-order LSB-first dentro del byte.
          for (var bit = 0; bit < 8; bit++) {
            final v = ((byte >> bit) & 1) == 1 ? 1.0 : -1.0;
            ring[pos] = v;
            pos = (pos + 1) % firTaps;
            sCounter++;
            if (sCounter >= decim) {
              sCounter = 0;
              // Compute convolution: sum(ring[(pos+i) % firTaps] * fir[i])
              // ring está organizado como ring buffer: index `pos` apunta a
              // donde va el PRÓXIMO sample, así que el más viejo está en
              // `pos`, el más nuevo en `(pos - 1)`. Para convolución, los
              // multiplicamos por fir[0..taps-1] que ya está time-reversed
              // (los coefs son simétricos en una FIR ventaneada).
              var acc = 0.0;
              var idx = pos;
              for (var i = 0; i < firTaps; i++) {
                acc += ring[idx] * fir[i];
                idx++;
                if (idx >= firTaps) idx = 0;
              }
              // Clamp a [-1, 1] y convertir a 24-bit signed int.
              if (acc > 1.0) acc = 1.0;
              if (acc < -1.0) acc = -1.0;
              final v24 = (acc * 8388607).toInt(); // 2^23 - 1
              // 24-bit little-endian: 3 bytes.
              pcmOutBuf.addByte(v24 & 0xFF);
              pcmOutBuf.addByte((v24 >> 8) & 0xFF);
              pcmOutBuf.addByte((v24 >> 16) & 0xFF);
            }
          }
        }

        ringPositions[ch] = pos;
        outSamples[ch] = sCounter;
      }

      if (pcmOutBuf.length > pcmFlushThreshold) {
        outFile.writeFromSync(pcmOutBuf.toBytes());
        pcmOutBuf.clear();
      }
    }
    if (pcmOutBuf.length > 0) {
      outFile.writeFromSync(pcmOutBuf.toBytes());
    }

    return true;
  } finally {
    outFile.closeSync();
  }
}

// ───────────────── Helpers ─────────────────

int _u32le(Uint8List b, int off) {
  return b[off] |
      (b[off + 1] << 8) |
      (b[off + 2] << 16) |
      (b[off + 3] << 24);
}

int _u64le(Uint8List b, int off) {
  // Dart ints son 64-bit en VM (puede haber issues en Web pero no usamos
  // este path ahí). Construimos directo.
  var lo = b[off] |
      (b[off + 1] << 8) |
      (b[off + 2] << 16) |
      (b[off + 3] << 24);
  var hi = b[off + 4] |
      (b[off + 5] << 8) |
      (b[off + 6] << 16) |
      (b[off + 7] << 24);
  return lo | (hi << 32);
}

/// FIR pasa-bajos con ventana Hann.
/// Cutoff normalizado = cutoffHz / sampleRateHz.
List<double> _makeFir({
  required double cutoffHz,
  required double sampleRateHz,
  required int taps,
}) {
  final cutoff = cutoffHz / sampleRateHz;
  final coeffs = Float64List(taps);
  final m = (taps - 1) / 2;
  var sum = 0.0;
  for (var n = 0; n < taps; n++) {
    final x = n - m;
    double h;
    if (x.abs() < 1e-9) {
      h = 2 * cutoff;
    } else {
      h = math.sin(2 * math.pi * cutoff * x) / (math.pi * x);
    }
    // Ventana Hann (mejor stopband que la rectangular sin ser tan suave
    // como Blackman; trade-off típico para audio de 96 taps).
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * n / (taps - 1));
    coeffs[n] = h * w;
    sum += coeffs[n];
  }
  // Normalizar para ganancia unitaria en DC.
  for (var i = 0; i < taps; i++) {
    coeffs[i] /= sum;
  }
  return coeffs;
}

/// Header WAV (RIFF) para PCM lineal. 24-bit se especifica con formato
/// `WAVE_FORMAT_PCM` (1), bitsPerSample = 24, byteAlign = channels * 3.
Uint8List _makeWavHeader({
  required int channels,
  required int sampleRate,
  required int bitsPerSample,
  required int dataSize,
}) {
  final h = BytesBuilder(copy: false);
  void wstr(String s) {
    for (var i = 0; i < s.length; i++) {
      h.addByte(s.codeUnitAt(i));
    }
  }

  void wu32(int v) {
    h.addByte(v & 0xFF);
    h.addByte((v >> 8) & 0xFF);
    h.addByte((v >> 16) & 0xFF);
    h.addByte((v >> 24) & 0xFF);
  }

  void wu16(int v) {
    h.addByte(v & 0xFF);
    h.addByte((v >> 8) & 0xFF);
  }

  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);

  wstr('RIFF');
  wu32(36 + dataSize); // ChunkSize
  wstr('WAVE');
  wstr('fmt ');
  wu32(16); // Subchunk1Size (PCM)
  wu16(1); // AudioFormat (PCM)
  wu16(channels);
  wu32(sampleRate);
  wu32(byteRate);
  wu16(blockAlign);
  wu16(bitsPerSample);
  wstr('data');
  wu32(dataSize);
  return h.toBytes();
}
