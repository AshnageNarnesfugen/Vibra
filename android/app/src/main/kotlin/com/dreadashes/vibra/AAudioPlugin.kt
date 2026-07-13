package com.dreadashes.vibra

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin nativo del modo bit-perfect / Hi-Fi.
 *
 * **Estado actual (scaffolding):**
 *
 * Expone `isAvailable` y `queryCapability` que retornan info real del SO:
 *   - `isAvailable`: true en API 26+ (cuando AAudio fue introducido).
 *   - `queryCapability`: consulta el `AudioManager` por output device activo,
 *     extrae sample rates soportados, native sample rate, burst frames, y el
 *     nombre del device.
 *
 * **Lo que NO implementa todavía** (claro en la cabeza):
 *
 *   - **Stream AAudio EXCLUSIVE real**: requiere abrir un `AAudioStream`
 *     con `AAUDIO_SHARING_MODE_EXCLUSIVE` desde JNI (la API nativa C),
 *     no expuesta en SDK Kotlin. Las llamadas JNI se hacen vía
 *     `System.loadLibrary("aaudio_bridge")` con un `.so` propio que
 *     todavía no existe en `jniLibs/`.
 *   - **Playback completo bypassando ExoPlayer**: cuando bit-perfect ON
 *     y el archivo es lossless local, deberíamos decodificar a PCM
 *     (FLAC/WAV/ALAC) y pushear los samples directamente al AAudio
 *     stream. Eso es lo que hacen UAPP, Neutron, etc.
 *   - **Sample rate matching**: setear el output al SR del archivo así
 *     Android no resamplea. Hoy lo SOLO reportamos en queryCapability.
 *
 * El path hacia la implementación completa:
 *   1. Crear `android/app/src/main/cpp/aaudio_bridge.cpp` con funciones
 *      JNI para abrir/cerrar streams.
 *   2. Configurar CMake en `app/build.gradle.kts` para construir el .so.
 *   3. Ampliar este plugin con métodos `openStream`, `writeFrames`, `close`.
 *   4. Crear un `AAudioBackedPlayer` en Dart que use estos primitives.
 *   5. En `PlaybackController` switchear entre just_audio y el AAudio
 *      player según `bitPerfectModeEnabled && file is lossless local`.
 *
 * Por hoy: scaffolding que reporta capability real y deja el `MethodChannel`
 * listo para que el lado Dart muestre info útil al usuario.
 */
class AAudioPlugin private constructor(
    private val context: Context,
) {
    companion object {
        private const val TAG = "VibraAAudio"
        private const val CHANNEL = "vibra/aaudio"

        fun register(engine: FlutterEngine, context: Context) {
            val plugin = AAudioPlugin(context)
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                CHANNEL,
            )
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(plugin.isAvailable())
                    "queryCapability" -> result.success(plugin.queryCapability())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * AAudio fue agregado en API 26 (Oreo, Android 8.0). Antes solo OpenSL ES,
     * que no tiene EXCLUSIVE mode ni el resto del API.
     */
    private fun isAvailable(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
    }

    /**
     * Consulta el `AudioManager` por:
     *   - Output device activo (USB DAC, BT, builtin speaker, etc.)
     *   - Sample rates soportados por ese output
     *   - Burst frames recomendado (latencia mínima sin underruns)
     *   - Sample rate "nativo" del device (mejor candidato para bit-perfect)
     *
     * NO consulta capability AAudio EXCLUSIVE — eso requiere abrir un stream
     * de prueba y verificar `getSharingMode()`, lo cual lleva JNI nativo.
     * Por ahora retornamos `exclusiveSupported = (SDK >= 26)` como heurística:
     * si el SO lo expone, asumimos que al menos algunos paths funcionan.
     */
    private fun queryCapability(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf(
                "exclusiveSupported" to false,
                "preferredSampleRate" to 0,
                "supportedSampleRates" to emptyList<Int>(),
                "preferredBurstFrames" to 0,
                "deviceName" to "",
            )
        }
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

            // Preferred sample rate del output (PROPERTY_OUTPUT_SAMPLE_RATE).
            // El SO sugiere este valor para latencia mínima — coincide con
            // el SR de hardware del DAC interno (típicamente 48000 en mid-range,
            // 96000 en Pixel/Samsung high-end).
            val preferredSr = am.getProperty(
                AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE
            )?.toIntOrNull() ?: 0
            val preferredBurst = am.getProperty(
                AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER
            )?.toIntOrNull() ?: 0

            // Output device activo: priorizamos el primer USB DAC, sino
            // wired headphones, sino BT, sino el builtin.
            val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val activeDevice = pickPreferredOutput(outputs)

            // Sample rates soportados por el device activo. Si el output
            // es USB DAC, suele exponer múltiples SRs hi-res (44.1, 48, 88.2,
            // 96, 176.4, 192). Internal speaker típicamente solo 48000.
            val supportedRates = activeDevice
                ?.sampleRates
                ?.toList()
                ?: listOf(preferredSr).filter { it > 0 }

            val deviceName = activeDevice?.productName?.toString() ?: ""

            // EXCLUSIVE mode heurística: si tenemos USB DAC, asumimos que sí
            // (los DACs USB son el caso ideal). Si es speaker interno, no.
            // Para una respuesta definitiva habría que abrir un stream JNI
            // y verificar; eso queda para la implementación nativa completa.
            val exclusiveSupported = activeDevice?.type ==
                AudioDeviceInfo.TYPE_USB_DEVICE ||
                activeDevice?.type == AudioDeviceInfo.TYPE_USB_HEADSET

            Log.i(TAG, "capability: device=$deviceName sr=$preferredSr " +
                "supported=$supportedRates burst=$preferredBurst " +
                "exclusive=$exclusiveSupported")

            mapOf(
                "exclusiveSupported" to exclusiveSupported,
                "preferredSampleRate" to preferredSr,
                "supportedSampleRates" to supportedRates,
                "preferredBurstFrames" to preferredBurst,
                "deviceName" to deviceName,
            )
        } catch (e: Throwable) {
            Log.e(TAG, "queryCapability failed", e)
            mapOf(
                "exclusiveSupported" to false,
                "preferredSampleRate" to 0,
                "supportedSampleRates" to emptyList<Int>(),
                "preferredBurstFrames" to 0,
                "deviceName" to "",
            )
        }
    }

    /**
     * Prioridad: USB DAC > USB headset > wired headphones > BT A2DP > speaker.
     * Refleja la jerarquía de calidad — siempre que haya un USB DAC, ese es
     * el output que el audiophile quiere.
     */
    private fun pickPreferredOutput(devices: Array<AudioDeviceInfo>): AudioDeviceInfo? {
        if (devices.isEmpty()) return null
        val priority = listOf(
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )
        for (type in priority) {
            val match = devices.firstOrNull { it.type == type }
            if (match != null) return match
        }
        return devices.first()
    }
}
