package com.dreadashes.vibra

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Heredamos de AudioServiceActivity (no FlutterActivity) para que el plugin
// audio_service pueda re-vincularse al MediaSession cuando el usuario abre la
// app desde la notificación / lockscreen sin que se re-cree la engine.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Plugin AAudio (modo bit-perfect / Hi-Fi). Registra el channel
        // `vibra/aaudio` con `isAvailable` y `queryCapability`. La parte
        // de stream EXCLUSIVE en JNI sigue pendiente — esto es el
        // scaffolding que ya reporta info real del SO al UI.
        AAudioPlugin.register(flutterEngine, applicationContext)

        // Plugin de almacenamiento: expone Android/media, Android/data y
        // Android/obb de la app a Dart, para que las descargas vivan en
        // una carpeta pública visible en el explorador de archivos.
        StoragePlugin.register(flutterEngine, applicationContext)

        // Transcoder a MP3 con metadata ID3 (canal `vibra/mp3`). Las
        // descargas de YT Music pasan por aquí cuando el usuario tiene
        // activado "Descargar como MP3".
        Mp3TranscoderPlugin.register(flutterEngine)

        // Platform channel para que Dart pueda leer cookies del WebView
        // INCLUYENDO las HttpOnly. `document.cookie` desde JS NO ve las
        // HttpOnly, pero CookieManager nativo sí — y las HttpOnly son
        // exactamente las que necesita Google para reconocer una sesión
        // autenticada (SID, __Secure-3PSID, etc.). Sin esto, login via
        // WebView siempre dejaba una cookie incompleta = 401 perpetuo.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vibra/cookies")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCookies" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("ARG", "url required", null)
                            return@setMethodCallHandler
                        }
                        val cookies = CookieManager.getInstance().getCookie(url)
                        result.success(cookies)
                    }
                    else -> result.notImplemented()
                }
            }

        // Channel para el mini widget flotante (Dynamic Island estilo).
        // Métodos:
        //   - hasOverlayPermission(): bool
        //   - requestOverlayPermission(): abre system settings
        //   - start({title, artist, coverB64, paletteColor, isPlaying})
        //   - update({...mismos campos...})
        //   - stop()
        // Eventos nativo → Dart:
        //   - onTogglePlayPause: callback que llega via channel.invokeMethod.
        val floatingChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "vibra/floating",
        )
        // Registramos el callback nativo que reenvía taps del play button
        // al Dart side via el mismo channel.
        FloatingControlsService.onTogglePlayPause = {
            runOnUiThread {
                floatingChannel.invokeMethod("onTogglePlayPause", null)
            }
        }
        floatingChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasOverlayPermission" -> {
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    } else true
                    result.success(ok)
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val i = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        )
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                    }
                    result.success(null)
                }
                "start", "update" -> {
                    val isStart = call.method == "start"
                    val action = if (isStart)
                        FloatingControlsService.ACTION_START
                    else FloatingControlsService.ACTION_UPDATE
                    val i = Intent(this, FloatingControlsService::class.java).apply {
                        this.action = action
                        putExtra(FloatingControlsService.EXTRA_TITLE,
                            call.argument<String>("title") ?: "")
                        putExtra(FloatingControlsService.EXTRA_ARTIST,
                            call.argument<String>("artist") ?: "")
                        putExtra(FloatingControlsService.EXTRA_COVER_B64,
                            call.argument<String>("coverB64"))
                        // Dart `int` cruza el MethodChannel como `Long`
                        // en Java/Kotlin (porque Dart ints son 64-bit por
                        // contrato). `call.argument<Int>` revienta con
                        // ClassCastException Long→Integer. Leemos como
                        // Number — que acepta tanto Long como Integer —
                        // y convertimos a Int (que es lo que Intent.putExtra
                        // espera para EXTRA_PALETTE_COLOR).
                        putExtra(FloatingControlsService.EXTRA_PALETTE_COLOR,
                            (call.argument<Number>("paletteColor"))?.toInt() ?: 0)
                        putExtra(FloatingControlsService.EXTRA_IS_PLAYING,
                            call.argument<Boolean>("isPlaying") ?: false)
                    }
                    // Solo el ARRANQUE inicial usa startForegroundService —
                    // cada llamada a ese API crea una promesa de 5s para
                    // que el service llame startForeground. Si la app
                    // mandara updates via startForegroundService cada vez
                    // que cambia la paleta o el estado de play, cada update
                    // crearía una nueva promesa que el sistema vigila — y
                    // bajo carga (transition de lifecycle, decode de cover,
                    // etc.) algún update no la honraba a tiempo →
                    // ForegroundServiceDidNotStartInTimeException que mata
                    // el proceso entero.
                    //
                    // UPDATE usa startService porque el service YA está
                    // foreground — solo necesita la nueva info via Intent
                    // extras, sin crear otra promesa. Si el service murió
                    // (system pressure), startService falla silencioso y
                    // el próximo backgrounding mandará un START nuevo.
                    try {
                        if (isStart &&
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(i)
                        } else {
                            startService(i)
                        }
                    } catch (e: Throwable) {
                        // IllegalStateException si el sistema bloqueó FGS
                        // desde background, o ServiceStartNotAllowed en
                        // Android 12+. Logueamos sin propagar — el Dart
                        // side ya logea "completed OK" pero al menos el
                        // crash de "did not start in time" no ocurre.
                        android.util.Log.e("VibraFloating",
                            "startService(${call.method}) failed: $e")
                    }
                    result.success(null)
                }
                "stop" -> {
                    val i = Intent(this, FloatingControlsService::class.java)
                        .setAction(FloatingControlsService.ACTION_STOP)
                    startService(i)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
