package com.dreadashes.vibra

import android.content.Context
import android.media.MediaScannerConnection
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Expone las rutas de almacenamiento externo ESPECÍFICAS de la app a Dart.
 *
 * Android organiza el almacenamiento externo de cada app en tres carpetas
 * bajo el almacenamiento compartido, todas nombradas por el package:
 *
 *   - `Android/data/<pkg>/files`  → `getExternalFilesDir(null)`.
 *       Sandboxed en Android 11+ (otras apps NO la ven, pero el file
 *       manager del sistema y la propia app sí). Sin permiso runtime.
 *   - `Android/media/<pkg>`       → `externalMediaDirs[0]`.
 *       **PÚBLICAMENTE visible** en cualquier explorador de archivos y
 *       indexable por MediaStore. Ideal para música descargada que el
 *       usuario quiere ver/copiar desde fuera de la app. Sin permiso.
 *   - `Android/obb/<pkg>`         → `obbDir`.
 *       Pensada para expansion files de juegos; la creamos por
 *       completitud a pedido del usuario.
 *
 * Ninguna de las tres requiere `WRITE_EXTERNAL_STORAGE` ni
 * `MANAGE_EXTERNAL_STORAGE` — son las carpetas propias de la app.
 */
class StoragePlugin private constructor(
    private val context: Context,
) {
    companion object {
        private const val TAG = "VibraStorage"
        private const val CHANNEL = "vibra/storage"

        fun register(engine: FlutterEngine, context: Context) {
            val plugin = StoragePlugin(context)
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                CHANNEL,
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "mediaDir" -> result.success(plugin.mediaDir())
                    "externalFilesDir" -> result.success(plugin.externalFilesDir())
                    "obbDir" -> result.success(plugin.obbDir())
                    "ensureAppDirs" -> result.success(plugin.ensureAppDirs())
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARG", "path required", null)
                        } else {
                            plugin.scanFile(path)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** `Android/media/<pkg>` — pública, sin permiso. Null si no hay external. */
    private fun mediaDir(): String? =
        context.externalMediaDirs.firstOrNull()?.absolutePath

    /** `Android/data/<pkg>/files`. */
    private fun externalFilesDir(): String? =
        context.getExternalFilesDir(null)?.absolutePath

    /** `Android/obb/<pkg>`. */
    private fun obbDir(): String? = context.obbDir?.absolutePath

    /**
     * Crea (si no existen) las tres carpetas de sistema de la app + una
     * subcarpeta "Vibra Music" dentro de la media dir para las descargas.
     * Devuelve el mapa de rutas para que Dart no tenga que llamar 3 veces.
     */
    private fun ensureAppDirs(): Map<String, String?> {
        val media = context.externalMediaDirs.firstOrNull()
        val files = context.getExternalFilesDir(null)
        val obb = context.obbDir

        // Crear cada una defensivamente — getExternalFilesDir ya la crea,
        // pero media/obb a veces no existen hasta el primer write.
        try { files?.mkdirs() } catch (e: Exception) { Log.w(TAG, "files mkdirs: $e") }
        try { media?.mkdirs() } catch (e: Exception) { Log.w(TAG, "media mkdirs: $e") }
        try { obb?.mkdirs() } catch (e: Exception) { Log.w(TAG, "obb mkdirs: $e") }

        var musicDir: String? = null
        if (media != null) {
            val music = File(media, "Vibra Music")
            try {
                music.mkdirs()
                // .nomedia NO — queremos que MediaStore indexe la música
                // para que aparezca en otras apps de música también.
                musicDir = music.absolutePath
            } catch (e: Exception) {
                Log.w(TAG, "music mkdirs: $e")
            }
        }

        Log.i(TAG, "ensureAppDirs media=${media?.absolutePath} " +
            "files=${files?.absolutePath} obb=${obb?.absolutePath} music=$musicDir")

        return mapOf(
            "media" to media?.absolutePath,
            "files" to files?.absolutePath,
            "obb" to obb?.absolutePath,
            "music" to musicDir,
        )
    }

    /**
     * Notifica a MediaStore que un archivo nuevo existe, para que aparezca
     * de inmediato en exploradores y apps de música sin esperar el scan
     * periódico del sistema.
     */
    private fun scanFile(path: String) {
        try {
            MediaScannerConnection.scanFile(
                context,
                arrayOf(path),
                null,
                null,
            )
        } catch (e: Exception) {
            Log.w(TAG, "scanFile($path) failed: $e")
        }
    }
}
