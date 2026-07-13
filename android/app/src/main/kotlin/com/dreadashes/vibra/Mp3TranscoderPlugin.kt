package com.dreadashes.vibra

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import de.sciss.jump3r.Main as Jump3rMain
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Transcodifica el audio descargado de YT Music (m4a/aac u opus/webm) a
 * MP3 con metadata ID3v2.3 incrustada (título, artista, álbum, carátula).
 *
 * Pipeline:
 *   1. **Decode** — `MediaExtractor` + `MediaCodec` (decoders de hardware/
 *      software del sistema) → PCM 16-bit intercalado → archivo WAV temporal.
 *   2. **Encode** — `jump3r` (port Java completo de LAME 3.98, sin NDK)
 *      WAV → MP3 CBR al bitrate pedido.
 *   3. **Tag** — writer propio de ID3v2.3 (frames TIT2/TPE1/TALB en UTF-16
 *      + APIC con la carátula JPEG) prepend al MP3.
 *
 * Corre en un executor de un solo hilo — un transcode a la vez es
 * suficiente y evita saturar CPU/memoria si el usuario descarga en lote.
 * El resultado vuelve al main thread para el MethodChannel.
 *
 * Por qué jump3r y no LAME/NDK: cero toolchain nativo, compila para todos
 * los ABIs sin CMake, y es LAME de verdad (mismo encoder, portado). Es
 * varias veces más lento que el nativo, pero el transcode ocurre en
 * background después de la descarga — no bloquea nada.
 */
class Mp3TranscoderPlugin private constructor() {
    companion object {
        private const val TAG = "VibraMp3"
        private const val CHANNEL = "vibra/mp3"

        fun register(engine: FlutterEngine) {
            val plugin = Mp3TranscoderPlugin()
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                CHANNEL,
            )
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(true)
                    "transcode" -> plugin.transcodeAsync(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Suppress("UNCHECKED_CAST")
    private fun transcodeAsync(rawArgs: Any?, result: MethodChannel.Result) {
        val args = rawArgs as? Map<String, Any?>
        val input = args?.get("input") as? String
        val output = args?.get("output") as? String
        if (input == null || output == null) {
            result.error("ARG", "input/output requeridos", null)
            return
        }
        val title = args["title"] as? String ?: ""
        val artist = args["artist"] as? String ?: ""
        val album = args["album"] as? String ?: ""
        val coverPath = args["coverPath"] as? String
        val bitrate = (args["bitrateKbps"] as? Number)?.toInt() ?: 256

        executor.execute {
            try {
                transcode(input, output, title, artist, album, coverPath, bitrate)
                mainHandler.post { result.success(output) }
            } catch (e: Throwable) {
                Log.e(TAG, "transcode failed", e)
                mainHandler.post {
                    result.error("TRANSCODE", e.message ?: "unknown", null)
                }
            }
        }
    }

    private fun transcode(
        input: String,
        output: String,
        title: String,
        artist: String,
        album: String,
        coverPath: String?,
        bitrateKbps: Int,
    ) {
        val wavTmp = File("$output.wav.tmp")
        val mp3Tmp = File("$output.mp3.tmp")
        try {
            // 1. Decode a WAV.
            decodeToWav(input, wavTmp)

            // 2. Encode con jump3r (LAME Java). Main.run procesa args
            //    estilo CLI de LAME. --silent para no spamear stdout.
            Jump3rMain().run(arrayOf(
                "-b", bitrateKbps.toString(),
                "--silent",
                wavTmp.absolutePath,
                mp3Tmp.absolutePath,
            ))
            if (!mp3Tmp.exists() || mp3Tmp.length() == 0L) {
                throw IllegalStateException("jump3r no produjo salida")
            }

            // 3. ID3v2.3 tag + MP3 → archivo final.
            val coverBytes = coverPath?.let { p ->
                val f = File(p)
                if (f.exists() && f.length() in 1..(2L * 1024 * 1024)) {
                    f.readBytes()
                } else null
            }
            val tag = buildId3v2(title, artist, album, coverBytes)
            FileOutputStream(File(output)).use { out ->
                out.write(tag)
                mp3Tmp.inputStream().use { it.copyTo(out, 1 shl 16) }
            }
            Log.i(TAG, "transcode OK → $output (${File(output).length() / 1024} KB)")
        } finally {
            wavTmp.delete()
            mp3Tmp.delete()
        }
    }

    // ───────────────────── Decode (MediaCodec) ─────────────────────

    /**
     * Decodifica la pista de audio de [input] a PCM 16-bit y la escribe
     * como WAV en [wavOut]. El header WAV se escribe con placeholders y se
     * corrige al final (cuando ya se conoce el tamaño real del PCM).
     */
    private fun decodeToWav(input: String, wavOut: File) {
        val extractor = MediaExtractor()
        extractor.setDataSource(input)
        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                trackIndex = i
                format = f
                break
            }
        }
        if (trackIndex < 0 || format == null) {
            extractor.release()
            throw IllegalStateException("Sin pista de audio en $input")
        }
        extractor.selectTrack(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME)!!

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        // sampleRate/channels REALES: pueden cambiar en el output format
        // (p.ej. opus 48000). Los tomamos del formato de salida cuando
        // MediaCodec lo anuncie; estos son el valor inicial.
        var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        RandomAccessFile(wavOut, "rw").use { raf ->
            raf.setLength(0)
            raf.write(ByteArray(44)) // placeholder del header
            var pcmBytes = 0L

            val bufferInfo = MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            val timeoutUs = 10_000L

            while (!sawOutputEOS) {
                if (!sawInputEOS) {
                    val inIdx = codec.dequeueInputBuffer(timeoutUs)
                    if (inIdx >= 0) {
                        val inBuf = codec.getInputBuffer(inIdx)!!
                        val n = extractor.readSampleData(inBuf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(
                                inIdx, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEOS = true
                        } else {
                            codec.queueInputBuffer(
                                inIdx, 0, n, extractor.sampleTime, 0,
                            )
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
                when {
                    outIdx >= 0 -> {
                        if (bufferInfo.size > 0) {
                            val outBuf = codec.getOutputBuffer(outIdx)!!
                            val chunk = ByteArray(bufferInfo.size)
                            outBuf.position(bufferInfo.offset)
                            outBuf.get(chunk)
                            raf.write(chunk)
                            pcmBytes += chunk.size
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (bufferInfo.flags and
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        ) {
                            sawOutputEOS = true
                        }
                    }
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val of = codec.outputFormat
                        sampleRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                }
            }

            codec.stop()
            codec.release()
            extractor.release()

            // Reescribir el header WAV con los valores reales.
            raf.seek(0)
            raf.write(wavHeader(sampleRate, channels, pcmBytes))
        }
    }

    /** Header WAV PCM 16-bit little-endian estándar de 44 bytes. */
    private fun wavHeader(sampleRate: Int, channels: Int, dataLen: Long): ByteArray {
        val byteRate = sampleRate * channels * 2
        val blockAlign = channels * 2
        val bb = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        bb.put("RIFF".toByteArray())
        bb.putInt((36 + dataLen).toInt())
        bb.put("WAVE".toByteArray())
        bb.put("fmt ".toByteArray())
        bb.putInt(16)
        bb.putShort(1) // PCM
        bb.putShort(channels.toShort())
        bb.putInt(sampleRate)
        bb.putInt(byteRate)
        bb.putShort(blockAlign.toShort())
        bb.putShort(16) // bits per sample
        bb.put("data".toByteArray())
        bb.putInt(dataLen.toInt())
        return bb.array()
    }

    // ───────────────────── ID3v2.3 writer ─────────────────────

    /**
     * Construye un tag ID3v2.3 con TIT2/TPE1/TALB (UTF-16 con BOM — v2.3
     * no soporta UTF-8, y UTF-16 cubre títulos japoneses/coreanos/etc.)
     * y APIC (front cover, JPEG) si hay carátula.
     *
     * Detalles del formato validados contra `file` y parsers reales:
     *   - Header: "ID3" + version 3.0 + flags 0 + tamaño SYNCHSAFE.
     *   - Frame: id(4) + tamaño big-endian NORMAL (synchsafe es v2.4) +
     *     flags(2=0) + payload.
     *   - Text payload: encoding 0x01 + BOM FF FE + UTF-16LE.
     *   - APIC payload: encoding 0x00 + mime NUL + pictureType 0x03 +
     *     description NUL (latin-1 → un solo NUL) + bytes de imagen.
     */
    private fun buildId3v2(
        title: String,
        artist: String,
        album: String,
        cover: ByteArray?,
    ): ByteArray {
        val frames = ArrayList<ByteArray>()
        if (title.isNotBlank()) frames.add(textFrame("TIT2", title))
        if (artist.isNotBlank()) frames.add(textFrame("TPE1", artist))
        if (album.isNotBlank()) frames.add(textFrame("TALB", album))
        if (cover != null && cover.isNotEmpty()) {
            frames.add(apicFrame(cover))
        }
        val body = frames.fold(ByteArray(0)) { acc, f -> acc + f }
        val header = ByteBuffer.allocate(10)
        header.put("ID3".toByteArray())
        header.put(3) // v2.3
        header.put(0)
        header.put(0) // flags
        header.put(synchsafe(body.size))
        return header.array() + body
    }

    private fun textFrame(id: String, text: String): ByteArray {
        // 0x01 = UTF-16 con BOM. BOM little-endian FF FE + UTF-16LE.
        val bom = byteArrayOf(0xFF.toByte(), 0xFE.toByte())
        val payload = byteArrayOf(0x01) + bom +
            text.toByteArray(Charsets.UTF_16LE)
        return frameHeader(id, payload.size) + payload
    }

    private fun apicFrame(image: ByteArray): ByteArray {
        val mime = detectMime(image)
        val payload = byteArrayOf(0x00) + // encoding latin-1 (para description)
            mime.toByteArray(Charsets.ISO_8859_1) + byteArrayOf(0) +
            byteArrayOf(0x03) + // picture type: front cover
            byteArrayOf(0) + // description vacía + terminator
            image
        return frameHeader("APIC", payload.size) + payload
    }

    private fun frameHeader(id: String, size: Int): ByteArray {
        val bb = ByteBuffer.allocate(10)
        bb.put(id.toByteArray(Charsets.ISO_8859_1))
        bb.putInt(size) // big-endian normal (v2.3)
        bb.putShort(0) // flags
        return bb.array()
    }

    private fun synchsafe(n: Int): ByteArray = byteArrayOf(
        ((n shr 21) and 0x7F).toByte(),
        ((n shr 14) and 0x7F).toByte(),
        ((n shr 7) and 0x7F).toByte(),
        (n and 0x7F).toByte(),
    )

    private fun detectMime(img: ByteArray): String {
        if (img.size >= 3 &&
            img[0] == 0xFF.toByte() && img[1] == 0xD8.toByte()
        ) return "image/jpeg"
        if (img.size >= 8 && img[1] == 'P'.code.toByte() &&
            img[2] == 'N'.code.toByte() && img[3] == 'G'.code.toByte()
        ) return "image/png"
        if (img.size >= 12 && img[8] == 'W'.code.toByte() &&
            img[9] == 'E'.code.toByte() && img[10] == 'B'.code.toByte()
        ) return "image/webp"
        return "image/jpeg"
    }
}
