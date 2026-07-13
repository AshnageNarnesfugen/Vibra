package com.dreadashes.vibra

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.util.Base64
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat

/**
 * Foreground service que mantiene una overlay window encima de todo el
 * sistema (launcher, otras apps) con un mini reproductor compacto al
 * estilo Dynamic Island. El service se inicia desde Flutter via
 * MethodChannel cuando el usuario activa el toggle en ajustes.
 *
 * Estados de la overlay:
 *   - COLLAPSED: pill chico con solo la portada miniatura. Tap → expandido.
 *   - EXPANDED: pill ancho con cover + título + artista + play/pause.
 *     Tap fuera o long-press → vuelve a collapsed.
 *
 * Comunicación:
 *   - Flutter → nativo: track info (título, artista, cover bytes), color
 *     de paleta (ARGB int), estado playing/paused. Vía updateState().
 *   - Nativo → Flutter: solo `togglePlayPause` cuando el usuario tapea
 *     el botón. Vía broadcast a la engine activa (el MethodChannel del
 *     MainActivity lo recibe).
 */
class FloatingControlsService : Service() {

    companion object {
        const val ACTION_START = "vibra.floating.START"
        const val ACTION_STOP = "vibra.floating.STOP"
        const val ACTION_UPDATE = "vibra.floating.UPDATE"

        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_COVER_B64 = "cover_b64"
        const val EXTRA_PALETTE_COLOR = "palette_color"
        const val EXTRA_IS_PLAYING = "is_playing"

        private const val NOTIF_CHANNEL_ID = "vibra_floating_overlay"
        private const val NOTIF_ID = 7424
        private const val TAG = "VibraFloating"

        /** Callback que Flutter setea para recibir tap → togglePlayPause. */
        @Volatile var onTogglePlayPause: (() -> Unit)? = null
    }

    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var coverIv: ImageView? = null
    private var titleTv: TextView? = null
    private var artistTv: TextView? = null
    private var playBtn: ImageView? = null
    private var pill: LinearLayout? = null

    private var expanded = false
    // Color inicial VISIBLE (semi-translúcido violeta) — antes era
    // `argb(180, 24, 24, 30)` casi negro y cuando el widget arrancaba
    // sin paleta (no song aún) el pill se confundía con la status bar
    // y el usuario reportaba "no aparece". Este queda visible sobre
    // cualquier fondo del sistema hasta que llega la paleta real.
    private var lastPaletteColor: Int = Color.argb(230, 90, 70, 140)
    private var lastIsPlaying: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand action=${intent?.action} sdk=${Build.VERSION.SDK_INT}")

        // SIEMPRE honrar la promesa de foreground service ANTES de
        // cualquier otra cosa. Cada `startForegroundService()` desde
        // MainActivity nos da 5 segundos para llamar `startForeground()`,
        // si no el sistema crashea el proceso con
        // ForegroundServiceDidNotStartInTimeException.
        //
        // Antes este bloque estaba DENTRO del when(action) → si la lógica
        // de ACTION_START fallaba ANTES de llegar al startForeground
        // (ej: ensureNotificationChannel throw por algún OEM raro), el
        // try-catch exterior lo tragaba, no se honraba la promesa, y
        // 5s después el watchdog mataba la app.
        //
        // Llamar startForeground en TODOS los actions también es OK —
        // es idempotente cuando ya estamos foreground (solo actualiza
        // la notif). Y nos cubre si ACTION_UPDATE llega via
        // startForegroundService por accidente (el flow normal usa
        // startService para updates, pero defensa en profundidad).
        try {
            ensureNotificationChannel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIF_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIF_ID, buildNotification())
            }
        } catch (e: Throwable) {
            // Si startForeground falla (FGS-from-background restringido,
            // permiso revocado, etc.), liberamos el servicio antes del
            // watchdog. Sin esto el proceso entero crashea.
            Log.e(TAG, "startForeground FAILED, stopping service to release promise", e)
            stopSelf()
            return START_NOT_STICKY
        }

        // Lógica de acción en try/catch separado — si esto falla, el
        // servicio queda en foreground state pero sin overlay (seguro;
        // el usuario puede tirar el toggle off para limpiarlo).
        try {
            when (intent?.action) {
                ACTION_START -> {
                    ensureOverlayCreated()
                    applyState(intent)
                    expanded = true
                    renderShape()
                    Log.i(TAG, "overlay setup complete, expanded=$expanded")
                }
                ACTION_UPDATE -> {
                    applyState(intent)
                }
                ACTION_STOP -> {
                    Log.i(TAG, "ACTION_STOP")
                    removeOverlay()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                else -> Log.w(TAG, "unknown action: ${intent?.action}")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "onStartCommand action handler FAILED", e)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        removeOverlay()
        super.onDestroy()
    }

    // ────────────── Overlay UI ──────────────

    private fun ensureOverlayCreated() {
        if (rootView != null) return
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = wm

        val density = resources.displayMetrics.density
        val pillHeight = (60 * density).toInt()

        val root = FrameLayout(this)
        rootView = root

        // Pill horizontal: cover + texto + botón play. El fondo y la
        // forma se actualizan en applyState() según el palette color.
        val pillView = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(
                (8 * density).toInt(),
                (6 * density).toInt(),
                (14 * density).toInt(),
                (6 * density).toInt(),
            )
        }
        pill = pillView

        val coverSize = (48 * density).toInt()
        coverIv = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(coverSize, coverSize)
            scaleType = ImageView.ScaleType.CENTER_CROP
            // Rounded corners vía ViewOutlineProvider (la forma oficial de
            // Android). Antes usábamos un Canvas con PorterDuff SRC_IN
            // que tenía issues con HW acceleration en algunos GPUs — el
            // resultado salía transparente y el placeholder/cover no se
            // veía. clipToOutline + outlineProvider es declarativo y
            // garantizado por el framework.
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setRoundRect(
                        0, 0, view.width, view.height,
                        (8f * density),
                    )
                }
            }
            // Placeholder por si no hay cover bytes todavía — sino el
            // ImageView queda transparente y el pill colapsado se ve
            // como un punto sin marca.
            setImageBitmap(placeholderCoverBitmap(coverSize))
        }
        pillView.addView(coverIv)

        val textCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setPadding((10 * density).toInt(), 0, (10 * density).toInt(), 0)
        }
        titleTv = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(Color.WHITE)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }
        artistTv = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(Color.argb(200, 255, 255, 255))
        }
        textCol.addView(titleTv)
        textCol.addView(artistTv)
        pillView.addView(textCol)

        // Botón play/pause grande (44dp = guideline mínimo de touch target
        // de Material). Antes era 32dp y sus bordes coincidían con la fila
        // de íconos del launcher detrás → el usuario reportaba "se cruzan
        // las zonas de tap". Ahora ocupa toda la altura del pill y tiene
        // padding interno para que el dedo NO toque el launcher.
        val btnSize = (44 * density).toInt()
        val btnPadding = (8 * density).toInt()
        playBtn = ImageView(this).apply {
            layoutParams = LinearLayout.LayoutParams(btnSize, btnSize)
            setImageResource(android.R.drawable.ic_media_play)
            setColorFilter(Color.WHITE)
            setPadding(btnPadding, btnPadding, btnPadding, btnPadding)
            // Background circular para feedback visual y para que el área
            // tappeable se identifique con el botón mismo (no con el
            // pill entero) — así el usuario distingue "botón" vs "fondo".
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(60, 255, 255, 255))
            }
            setOnClickListener { onTogglePlayPause?.invoke() }
        }
        pillView.addView(playBtn)

        root.addView(pillView)

        // Tap en el pill expande/colapsa. El play button intercepta su
        // propio click → no llega aquí.
        pillView.setOnClickListener {
            expanded = !expanded
            renderShape()
        }

        // Margen TOP generoso (110dp) para esquivar status bar + notch
        // + la primera fila de íconos del launcher (que típicamente
        // arranca alrededor de 80-100dp del top). Si el pill cae justo
        // sobre esa fila, el usuario taps el botón del launcher por
        // accidente al intentar usar el pill.
        val topMargin = (110 * density).toInt()
        // Quitamos FLAG_LAYOUT_NO_LIMITS — antes permitía dibujar sobre
        // áreas reservadas, PERO también podía meter el pill OFF-screen
        // si las coords eran mal calculadas en algunos OEMs (Samsung,
        // Xiaomi). Sin el flag, Android constraina al area visible →
        // el pill siempre cae sobre pantalla.
        // NOT_TOUCH_MODAL deja pasar touches por fuera del overlay al
        // app de abajo (sino bloquearía el launcher al moverse encima).
        val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }

        // Ancho INICIAL EXPLÍCITO 260dp (en vez de WRAP_CONTENT): si
        // los TextViews están vacíos al primer measure y el cover aún
        // no llegó, WRAP_CONTENT puede colapsar el pill a ~40dp y se
        // vuelve casi invisible. 260dp = ancho expanded, garantiza
        // primer frame visible incluso sin contenido completo.
        val initialWidth = (260 * density).toInt()
        val lp = WindowManager.LayoutParams(
            initialWidth,
            pillHeight,
            type,
            flags,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = topMargin
            // Blur del fondo detrás del overlay (API 31+, Android 12+).
            // No es RenderEffect — eso blurea el contenido del pill mismo,
            // que es lo opuesto a lo que queremos. blurBehindRadius es el
            // API correcto para "frosted glass" sobre apps de abajo.
            // Requiere que el usuario tenga "Window blur" habilitado en
            // ajustes (default ON desde A12). Si está OFF cae al alpha
            // del GradientDrawable y se ve sólido pero respetable.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // `this.flags` para desambiguar del `val flags` exterior
                // — sin `this.` Kotlin resuelve a la val capturada y
                // revienta con "val cannot be reassigned".
                @Suppress("DEPRECATION")
                this.flags = this.flags or WindowManager.LayoutParams.FLAG_BLUR_BEHIND
                try {
                    blurBehindRadius = (32 * density).toInt()
                    Log.i(TAG, "blur: requested radius=$blurBehindRadius, " +
                        "systemSupports=${wm.isCrossWindowBlurEnabled}. " +
                        "Si systemSupports=false, el blur NO se va a ver " +
                        "(activar en ajustes → Sistema → Para desarrolladores → " +
                        "'Permitir desenfoque a nivel de ventana')")
                } catch (e: Throwable) {
                    Log.w(TAG, "blur setup failed: $e")
                }
            } else {
                Log.i(TAG, "blur: sdk=${Build.VERSION.SDK_INT} <31, no soportado")
            }
        }

        var addOk = false
        try {
            wm.addView(root, lp)
            Log.i(TAG, "overlay addView OK: type=$type w=${lp.width} h=${lp.height} y=${lp.y} grav=${lp.gravity}")
            addOk = true
        } catch (e: Throwable) {
            Log.e(TAG, "addView FAILED with type=$type", e)
        }
        // Fallback: si TYPE_APPLICATION_OVERLAY falla en este device/OS
        // (algunos OEMs custom-rom o Android 13+ con strict mode lo
        // bloquean), intentamos TYPE_PHONE deprecado que algunos roms
        // siguen aceptando con SYSTEM_ALERT_WINDOW.
        if (!addOk && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                @Suppress("DEPRECATION")
                lp.type = WindowManager.LayoutParams.TYPE_PHONE
                wm.addView(root, lp)
                Log.w(TAG, "overlay added via TYPE_PHONE fallback")
                addOk = true
            } catch (e: Throwable) {
                Log.e(TAG, "TYPE_PHONE fallback also failed", e)
            }
        }
        if (!addOk) {
            Log.e(TAG, "ALL addView attempts failed — el flotante NO va a aparecer. " +
                "Verifica el permiso 'Mostrar sobre otras apps' en ajustes del sistema.")
        }
        renderShape()
    }

    private fun removeOverlay() {
        rootView?.let { v ->
            try { windowManager?.removeView(v) } catch (_: Exception) {}
        }
        rootView = null
        coverIv = null
        titleTv = null
        artistTv = null
        playBtn = null
        pill = null
    }

    private fun applyState(intent: Intent) {
        val rawTitle = intent.getStringExtra(EXTRA_TITLE) ?: ""
        val rawArtist = intent.getStringExtra(EXTRA_ARTIST) ?: ""
        val coverB64 = intent.getStringExtra(EXTRA_COVER_B64)
        val color = intent.getIntExtra(EXTRA_PALETTE_COLOR, lastPaletteColor)
        val playing = intent.getBooleanExtra(EXTRA_IS_PLAYING, lastIsPlaying)

        lastPaletteColor = color
        lastIsPlaying = playing

        // Fallbacks legibles cuando el widget arranca sin canción activa
        // (toggle ON en cold start, app cerrada). Sin esto, el pill
        // expandido muestra textos vacíos y se siente "roto".
        titleTv?.text = rawTitle.ifBlank { "Vibra" }
        artistTv?.text = rawArtist.ifBlank { "Toca para abrir" }

        if (!coverB64.isNullOrEmpty()) {
            try {
                val bytes = Base64.decode(coverB64, Base64.DEFAULT)
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bmp != null) {
                    Log.i(TAG, "cover decoded ${bmp.width}x${bmp.height}, applying")
                    coverIv?.setImageBitmap(bmp)
                } else {
                    Log.w(TAG, "cover decode returned null bitmap")
                }
            } catch (e: Exception) {
                Log.w(TAG, "cover decode failed: $e")
            }
        }

        playBtn?.setImageResource(
            if (playing) android.R.drawable.ic_media_pause
            else android.R.drawable.ic_media_play
        )
        renderShape()
    }

    /** Aplica el fondo + corners + ancho del pill según expanded y palette. */
    private fun renderShape() {
        val density = resources.displayMetrics.density
        val pillView = pill ?: return
        // Alpha del fondo del pill:
        //   - Si el blur de window está soportado y activo, queremos un
        //     pill MUY translúcido (alpha ~130) para que la imagen
        //     blurreada detrás se vea como frosted glass.
        //   - Si NO está soportado, el blur no funciona — caemos a alpha
        //     alto (215) para que el pill sea legible sobre cualquier
        //     fondo del launcher (sin blur el contraste depende solo del
        //     color del fondo).
        val blurOk = isCrossWindowBlurSupported()
        val bgAlpha = if (blurOk) 130 else 215
        val shape = GradientDrawable().apply {
            setColor(applyAlpha(lastPaletteColor, bgAlpha))
            cornerRadius = (26 * density)
        }
        pillView.background = shape

        // Ocultar texto + play en collapsed → solo se ve la cover.
        val showText = expanded
        textVisibility(showText)

        // Width fijos (no WRAP_CONTENT) → garantía de visibilidad. WRAP
        // colapsaba a 0px si los TextViews aún no tenían contenido y
        // el cover bitmap no estaba seteado.
        //   collapsed = 64dp (solo cover 48 + padding).
        //   expanded = 260dp (cover 48 + texto + botón play 44).
        val lp = rootView?.layoutParams as? WindowManager.LayoutParams ?: return
        lp.width = if (expanded) (260 * density).toInt()
                   else (64 * density).toInt()
        try {
            windowManager?.updateViewLayout(rootView, lp)
        } catch (_: Exception) {}
    }

    private fun textVisibility(show: Boolean) {
        val v = if (show) View.VISIBLE else View.GONE
        titleTv?.visibility = v
        artistTv?.visibility = v
        playBtn?.visibility = v
    }

    // ────────────── Helpers ──────────────

    /**
     * Reporta si el sistema actualmente soporta + tiene activado el blur
     * entre ventanas. API 31+ tiene `isCrossWindowBlurEnabled()` que el
     * sistema apaga en battery-saver, en devices low-end y cuando el
     * usuario lo deshabilita en Developer Options. Si retorna false, el
     * `blurBehindRadius` que seteamos en LayoutParams se ignora silenciosamente.
     */
    private fun isCrossWindowBlurSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            val wm = windowManager ?: getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.isCrossWindowBlurEnabled
        } catch (_: Throwable) {
            false
        }
    }

    private fun applyAlpha(color: Int, alpha: Int): Int {
        return Color.argb(
            alpha,
            Color.red(color),
            Color.green(color),
            Color.blue(color),
        )
    }

    /** Placeholder cuando no hay cover todavía — círculo del color
     *  primario con la "V" de Vibra dentro. */
    private fun placeholderCoverBitmap(sizePx: Int): Bitmap {
        val out = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = applyAlpha(lastPaletteColor, 230)
        }
        c.drawRoundRect(
            RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat()),
            sizePx * 0.18f,
            sizePx * 0.18f,
            bgPaint,
        )
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = sizePx * 0.60f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        val baseline = sizePx / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
        c.drawText("V", sizePx / 2f, baseline, textPaint)
        return out
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(NOTIF_CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    NOTIF_CHANNEL_ID,
                    "Mini reproductor flotante",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Mantiene el widget flotante activo"
                    setShowBadge(false)
                }
                mgr.createNotificationChannel(ch)
            }
        }
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Vibra mini")
            .setContentText("Mini reproductor flotante activo")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
