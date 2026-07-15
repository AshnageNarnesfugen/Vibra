import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' as media_session
    show AudioService, AudioServiceConfig;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/animations/parallax_controller.dart';
import 'core/settings/settings_controller.dart';
import 'core/theme/palette_signal.dart';
import 'providers/bit_perfect_controller.dart';
import 'providers/equalizer_controller.dart';
import 'providers/library_controller.dart';
import 'providers/lyrics_controller.dart';
import 'providers/playback_controller.dart';
import 'services/adaptive_luminance_service.dart';
import 'services/ambient_video_palette_service.dart';
import 'services/app_storage.dart';
import 'services/audio_service.dart';
import 'services/blurred_background.dart';
import 'services/wakelock_controller.dart';
import 'services/download_service.dart';
import 'services/floating_controls_service.dart';
import 'services/music_video_player.dart';
import 'services/network_quality_resolver.dart';
import 'services/video_availability_controller.dart';
import 'services/library_service.dart';
import 'services/lyrics_service.dart';
import 'services/media_session_handler.dart';
import 'services/playlist_service.dart';
import 'services/streaming/streaming_service.dart';
import 'services/streaming/yt_auth.dart';
import 'services/streaming/yt_oauth_service.dart';
import 'core/dev_log.dart';

/// DSN de Sentry inyectado en build vía `--dart-define=SENTRY_DSN=https://...`.
/// Sin esto, Sentry queda no-op (no enviamos nada). También se salta en
/// debug builds (kDebugMode) para no contaminar el dashboard con errores
/// de dev.
const String _sentryDsn = String.fromEnvironment('SENTRY_DSN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Captura cualquier excepción de Flutter framework + zonas asincronas: en
  // vez de cerrar la app, deja log. Útil para diagnosticar crashes en
  // device real.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    devLog('FlutterError: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    devLog('PlatformDispatcher error: $error\n$stack');
    return true;
  };

  try {
    // En Linux/Windows/macOS, just_audio no tiene implementación nativa. Lo
    // enchufamos a libmpv vía just_audio_media_kit.
    if (!kIsWeb &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      JustAudioMediaKit.ensureInitialized(
        linux: true,
        windows: true,
        macOS: true,
      );
    }
  } catch (e) {
    devLog('JustAudioMediaKit init failed: $e');
  }

  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}

  // ---- Servicios ----
  // Cualquier fallo en este bloque NO debe tumbar la app: cae a defaults.
  SettingsController settings;
  try {
    settings = await SettingsController.load().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Settings load timed out'),
    );
  } catch (e) {
    devLog('Settings load failed: $e');
    // Fallback: settings vacíos si falla la persistencia.
    settings = await SettingsController.loadFallback();
  }

  final palette = PaletteSignal();
  final parallax = ParallaxController();
  // Activar sensor es idempotente; lo hacemos solo si el usuario lo pidió.
  try {
    parallax.setEnabled(settings.value.parallaxEnabled);
  } catch (e) {
    devLog('Parallax start skipped: $e');
  }

  final audio = AudioService.instance;
  try {
    await audio.ensureInitialized().timeout(
      const Duration(seconds: 3),
      onTimeout: () => devLog('AudioService init timed out'),
    );
  } catch (e) {
    devLog('AudioService init failed: $e');
  }

  final library = LibraryService();
  final streaming = StreamingService();
  final blurredBg = BlurredBackgroundService();

  // Playlists locales — persistencia ligera vía SharedPreferences. Si la
  // carga falla por algún motivo, el constructor devuelve un servicio vacío
  // y la app sigue funcionando (las playlists se podrán crear pero no
  // persistirán hasta que prefs vuelva a estar disponible).
  PlaylistService playlists;
  try {
    playlists = await PlaylistService.load()
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    devLog('PlaylistService load failed: $e');
    playlists = await PlaylistService.load();
  }

  // Almacenamiento: resuelve + crea las carpetas de sistema de la app
  // (Android/media, Android/data, Android/obb) ANTES de las descargas,
  // que dependen de la carpeta pública de música. Idempotente y con
  // fallback interno si el channel falla — nunca bloquea el arranque.
  try {
    await AppStorage.init().timeout(const Duration(seconds: 3));
  } catch (e) {
    devLog('AppStorage.init failed/timed out: $e');
  }

  // Descargas offline — carga el índice de canciones ya descargadas. Si
  // alguno de los archivos físicos no existe (storage limpiado), el service
  // los descarta del índice automáticamente al cargar.
  DownloadService? downloads;
  try {
    downloads = await DownloadService.create(streaming, settings: settings)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    devLog('DownloadService load failed: $e');
  }

  // libraryCtrl se inicializa DESPUÉS de downloads para poder pasarle el
  // servicio: así la biblioteca ya nace conociendo las canciones
  // descargadas y las agrupa en albums/artists junto con los archivos
  // locales. Si downloads falló (null), el agrupamiento sigue funcionando
  // solo con la música del disco.
  final libraryCtrl =
      LibraryController(library, settings, downloads: downloads);

  // Registra el callback de refresh ANTES de cargar cualquier auth — así
  // si la primera request encuentra el token expirado, ya tiene cómo
  // refrescarlo sin romper la llamada.
  streaming.onAuthRefresh = () async {
    final refreshTok = settings.value.ytMusicRefreshToken;
    if (refreshTok == null || refreshTok.isEmpty) return null;
    try {
      final svc = YtOauthService();
      try {
        final fresh = await svc.refresh(refreshTok);
        // Persistir el nuevo access_token + (posible) nuevo refresh_token.
        settings.update((s) => s.copyWith(
              ytMusicAccessToken: fresh.accessToken,
              ytMusicRefreshToken: fresh.refreshToken,
              ytMusicAccessTokenExpiryEpochMs:
                  fresh.accessTokenExpiryEpochMs,
            ));
        devLog('[YTM] OAuth token refreshed transparently');
        return YtMusicAuth(
          cookie: settings.value.ytMusicCookie ?? '',
          visitorData: settings.value.ytMusicVisitorData,
          dataSyncId: settings.value.ytMusicDataSyncId,
          accessToken: fresh.accessToken,
          refreshToken: fresh.refreshToken,
          tokenExpiryEpochMs: fresh.accessTokenExpiryEpochMs,
        );
      } finally {
        svc.close();
      }
    } catch (e) {
      devLog('[YTM] OAuth refresh failed: $e');
      // Si Google rechazó el refresh (invalid_grant = revocado), limpiamos
      // los tokens para que la UI sepa que hay que re-login. Cualquier
      // otro error de red lo dejamos pasar — puede ser transitorio.
      if (e is YtOauthException && e.statusCode == 400) {
        settings.update((s) => s.copyWith(clearYtMusicAuth: true));
      }
      return null;
    }
  };

  // ─── Path 1: Tokens OAuth persistidos → prioridad sobre cookies ───
  final savedAccessToken = settings.value.ytMusicAccessToken;
  final savedRefreshToken = settings.value.ytMusicRefreshToken;
  if (savedAccessToken != null || savedRefreshToken != null) {
    streaming.setAuth(YtMusicAuth(
      cookie: settings.value.ytMusicCookie ?? '',
      visitorData: settings.value.ytMusicVisitorData,
      dataSyncId: settings.value.ytMusicDataSyncId,
      accessToken: savedAccessToken,
      refreshToken: savedRefreshToken,
      tokenExpiryEpochMs:
          settings.value.ytMusicAccessTokenExpiryEpochMs,
    ));
    // El cliente refrescará el token automáticamente en la próxima request
    // si está expirado (gracias al onAuthRefresh registrado arriba).
  }

  // ─── Path 2: Solo cookies legacy (sin OAuth) ───
  final savedCookie = settings.value.ytMusicCookie;
  if (savedCookie != null &&
      savedAccessToken == null &&
      savedRefreshToken == null) {
    streaming.setAuth(YtMusicAuth(
      cookie: savedCookie,
      visitorData: settings.value.ytMusicVisitorData,
      dataSyncId: settings.value.ytMusicDataSyncId,
    ));
    // Si la cookie guardada está incompleta (le falta __Secure-3PSID/SID),
    // toda request va a tirar 401. Mejor limpiarla ya y forzar al usuario a
    // re-loguearse — así no ve "no aparece nada" sin explicación. Log con
    // qué cookies faltan para diagnóstico.
    if (!streaming.hasCompleteAuth) {
      final missing = streaming.missingCookies.join(', ');
      devLog('[YTM] saved cookie is incomplete (missing: $missing) — '
          'clearing. User needs to re-login with the FULL Cookie header.');
      streaming.clearAuth();
      settings.update((s) => s.copyWith(clearYtMusicAuth: true));
    } else {
      // Solo refrescamos session ids si la cookie es completa. Si era
      // incompleta ya la limpiamos arriba — re-setearla aquí la traería
      // de vuelta inútilmente.
      try {
        final ids = await streaming
            .fetchSessionIds()
            .timeout(const Duration(seconds: 4));
        final freshVd = ids.visitorData;
        final freshDsi = ids.dataSyncId;
        final vdChanged =
            freshVd != null && freshVd != settings.value.ytMusicVisitorData;
        final dsiChanged =
            freshDsi != null && freshDsi != settings.value.ytMusicDataSyncId;
        if (vdChanged || dsiChanged) {
          streaming.setAuth(YtMusicAuth(
            cookie: savedCookie,
            visitorData: freshVd ?? settings.value.ytMusicVisitorData,
            dataSyncId: freshDsi ?? settings.value.ytMusicDataSyncId,
          ));
          settings.update((s) => s.copyWith(
                ytMusicVisitorData: freshVd ?? s.ytMusicVisitorData,
                ytMusicDataSyncId: freshDsi ?? s.ytMusicDataSyncId,
              ));
          devLog('[YTM] session ids refreshed on startup '
              '(vd=$vdChanged, dsi=$dsiChanged)');
        }
      } catch (e) {
        devLog('[YTM] session refresh skipped: $e');
      }
    }
  }
  // Resolver de calidad por tipo de red. Connectivity es opcional — si
  // el platform-channel falla (desktop sin permisos, emulador, etc.), el
  // resolver cae a defaults razonables.
  final network = NetworkQualityResolver(settings);

  final playback = PlaybackController(
    audio: audio,
    library: library,
    palette: palette,
    streaming: streaming,
    settings: settings,
    network: network,
    downloads: downloads,
  );

  // Mini reproductor flotante (Dynamic Island estilo). Construido eager
  // para poder arrancarlo automáticamente si el setting venía activado
  // de una sesión anterior — sin esto el usuario tendría que volver al
  // toggle de settings en cada cold start. setEnabled() es no-op en
  // plataformas no-Android, así que llamarlo siempre es seguro.
  final floating = FloatingControlsService(
    playback: playback,
    palette: palette,
  );
  if (settings.value.floatingMiniEnabled) {
    // ignore: discarded_futures
    floating.setEnabled(true);
  }

  // Equalizer controller: wrappea los AndroidAudioEffects construidos en
  // AudioService (singleton). Eager para que el cold-start aplique los
  // gains/preamp guardados ANTES de que el usuario pueda oír un segundo
  // de música con un EQ desactivado por error. En plataformas non-Android
  // el controller queda inerte (`available` retorna false).
  final equalizer = EqualizerController(audio: audio);

  // Bit-perfect / Hi-Fi controller: depende del settings + equalizer. Al
  // activarse fuerza neutral en EQ/fade/preamp y monitorea el output
  // device via audio_session. También probea el plugin AAudio nativo
  // para reportar capability del SO.
  final bitPerfect = BitPerfectController(
    settings: settings,
    equalizer: equalizer,
  );

  // Mantiene la pantalla encendida mientras `playback.isPlaying`. Cuando
  // pausas, libera el wakelock → vuelve al timeout normal del sistema.
  // Sin necesidad de exponerlo via Provider: vive todo el ciclo de la
  // app y se autoadministra escuchando al playback.
  // ignore: unused_local_variable
  final wakelock = WakelockController(playback: playback);

  // Notificación del sistema + lockscreen + media buttons. Solo Android/iOS
  // tienen implementación nativa; en desktop la init es no-op pero el
  // handler sigue funcionando (solo sin notificación visible). Si la init
  // falla por configuración pendiente del usuario (manifest/MainActivity),
  // logueamos y seguimos — la app funciona sin notificación.
  try {
    await media_session.AudioService.init(
      builder: () => MediaSessionHandler(playback, audio.player),
      config: const media_session.AudioServiceConfig(
        androidNotificationChannelId: 'com.dreadashes.vibra.audio',
        androidNotificationChannelName: 'Reproducción de música',
        androidNotificationIcon: 'mipmap/ic_launcher',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidShowNotificationBadge: true,
      ),
    ).timeout(const Duration(seconds: 4));
  } catch (e) {
    devLog('AudioService (media session) init failed: $e');
  }

  // POST_NOTIFICATIONS en Android 13+. Sin esto, la notificación con
  // controles de media NO aparece y el foreground service queda "ciego"
  // (suena pero el usuario no ve el track ni puede controlarlo desde
  // lockscreen / sombra). Lo pedimos en init para que el primer play
  // ya muestre la notif. Si el usuario deniega lo dejamos pasar — la
  // música igual reproduce, solo sin notif de sistema.
  if (!kIsWeb && Platform.isAndroid) {
    try {
      await Permission.notification
          .request()
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      devLog('Notification permission request failed: $e');
    }
  }

  // ignore: deprecated_member_use
  Provider.debugCheckInvalidValueType = null;

  // Empaquetamos el árbol en una variable para poder pasarlo a
  // `SentryFlutter.init` como `appRunner` sin duplicar el MultiProvider.
  final appRoot = MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: palette),
        ChangeNotifierProvider.value(value: parallax),
        ChangeNotifierProvider.value(value: libraryCtrl),
        ChangeNotifierProvider.value(value: playback),
        Provider<StreamingService>.value(value: streaming),
        ChangeNotifierProvider<PlaylistService>.value(value: playlists),
        ChangeNotifierProvider<VideoAvailabilityController>(
          create: (_) =>
              VideoAvailabilityController(streaming, network: network),
        ),
        // MusicVideoPlayer mantiene UN solo VideoPlayerController compartido
        // entre cover y bg, y sincroniza play/pause/seek con el audio. Antes
        // cada widget creaba su propio controller → desincronización y "pause
        // no para el video del otro sitio". Reusa el VideoAvailabilityController
        // declarado arriba (no crear uno nuevo aquí — el cache de URLs debe
        // ser el MISMO que consulta el toggle del PlayerScreen).
        ChangeNotifierProvider<MusicVideoPlayer>(
          create: (ctx) => MusicVideoPlayer(
            playback: playback,
            availability: ctx.read<VideoAvailabilityController>(),
          ),
        ),
        // Ambient mode: cuando hay un music video activo, sus colores se
        // filtran a toda la UI (theme, shader, iconos adaptivos) via
        // `PaletteSignal.setAmbientOverride`. Por defecto activo — el
        // usuario puede apagarlo en Ajustes → Fondo.
        ChangeNotifierProvider<AmbientVideoPaletteService>(
          create: (ctx) {
            final svc = AmbientVideoPaletteService(
              videoPlayer: ctx.read<MusicVideoPlayer>(),
              paletteSignal: ctx.read<PaletteSignal>(),
            )..setEnabled(settings.value.useAmbientVideoPalette);
            // Re-evalúa el toggle cada vez que settings cambia. El listener
            // vive durante todo el ciclo de la app — settings es singleton
            // global, no hay leak.
            settings.addListener(() {
              svc.setEnabled(settings.value.useAmbientVideoPalette);
            });
            return svc;
          },
        ),
        // Letra de la canción. Singleton del servicio HTTP a lrclib + el
        // controller que escucha cambio de canción y dispara fetch + cache
        // en memoria. activeIndex se actualiza en cada tick de position.
        Provider<LyricsService>(create: (_) => LyricsService()),
        ChangeNotifierProvider<LyricsController>(
          create: (ctx) => LyricsController(
            service: ctx.read<LyricsService>(),
            playback: playback,
          ),
        ),
        if (downloads != null)
          ChangeNotifierProvider<DownloadService>.value(value: downloads),
        Provider<DownloadService?>.value(value: downloads),
        // Solo necesitamos la variante nullable: los consumidores usan
        // `Provider.of<BlurredBackgroundService?>()` y reciben el valor
        // real cuando el provider está montado. La doble registración
        // anterior era redundante y costaba un InheritedWidget extra.
        ChangeNotifierProvider<BlurredBackgroundService?>.value(value: blurredBg),
        // Luminance map del bg actual — alimenta a los widgets
        // `AdaptiveColor` para que cada uno decida tinta clara/oscura
        // según la región que TIENE detrás (no según un promedio global).
        ChangeNotifierProvider<AdaptiveLuminanceService>(
          create: (_) => AdaptiveLuminanceService(),
        ),
        // Mini reproductor flotante (Dynamic Island estilo) sobre el
        // sistema. Se crea EAGER en el bootstrap (no via Provider create)
        // para que pueda arrancarse automáticamente si el setting
        // `floatingMiniEnabled` estaba activado en la sesión anterior.
        // Solo Android — en otras plataformas el service queda inerte.
        ChangeNotifierProvider<FloatingControlsService>.value(value: floating),
        ChangeNotifierProvider<EqualizerController>.value(value: equalizer),
        ChangeNotifierProvider<BitPerfectController>.value(value: bitPerfect),
      ],
      child: const VibraApp(),
    );

  // Sentry SOLO en release builds y SOLO si hay DSN inyectado en compile.
  // `kDebugMode` evita ruido durante desarrollo (los crashes de dev no
  // valen métricas). Sin DSN → corremos la app tal cual; Sentry queda
  // como no-op total (sin overhead, sin red).
  if (_sentryDsn.isEmpty || kDebugMode) {
    runApp(appRoot);
    return;
  }
  await SentryFlutter.init(
    (options) {
      options.dsn = _sentryDsn;
      // 10% de traces — para alpha es suficiente sin quemar la free tier.
      options.tracesSampleRate = 0.1;
      // No reportamos PII por defecto. Si el usuario opt-in en ajustes,
      // se podría activar dinámicamente.
      options.sendDefaultPii = false;
      // Chain con FlutterError.onError + PlatformDispatcher.onError ya
      // configurados arriba — Sentry los wrappea automáticamente.
      options.attachStacktrace = true;
    },
    appRunner: () => runApp(appRoot),
  );
}
