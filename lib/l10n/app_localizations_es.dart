// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get homeTab => 'Inicio';

  @override
  String get libraryTab => 'Biblioteca';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get cancel => 'Cancelar';

  @override
  String get settingsAccountTitle => 'Cuenta de YouTube Music';

  @override
  String get settingsAccountActive =>
      'Sesión activa — biblioteca personal habilitada';

  @override
  String get settingsAccountOauthLimited =>
      'OAuth guardado pero limitado por Google — usá cookie';

  @override
  String get settingsAccountNone => 'Sin sesión — solo búsqueda pública';

  @override
  String get settingsBackgroundTitle => 'Fondo';

  @override
  String get settingsBackgroundSubtitle =>
      'Color sólido o imagen ajustable, opacidad';

  @override
  String get settingsEffectsTitle => 'Efectos';

  @override
  String get settingsEffectsSubtitle =>
      'Blur, ruido y parallax al inclinar el dispositivo';

  @override
  String get settingsThemeTitle => 'Tema y color';

  @override
  String get settingsThemeSubtitle =>
      'Color dinámico desde la portada o acento por defecto';

  @override
  String get settingsSpacingTitle => 'Espaciado y bordes';

  @override
  String get settingsSpacingSubtitle => 'Densidad y radio uniforme';

  @override
  String get settingsAnimationsTitle => 'Animaciones';

  @override
  String get settingsAnimationsSubtitle =>
      'Estilo y duración de las transiciones';

  @override
  String get settingsQualityTitle => 'Calidad de audio y video';

  @override
  String get settingsQualitySubtitle =>
      'Bitrate diferente en WiFi vs datos móviles; calidad de descargas';

  @override
  String get settingsStorageTitle => 'Almacenamiento';

  @override
  String get settingsStorageSubtitle =>
      'Dónde vive la música descargada y las carpetas de la app';

  @override
  String get settingsEqTitle => 'Ecualizador';

  @override
  String get settingsEqSubtitle =>
      'Bandas + preamp + presets (Rock, Bass Boost, V-Shape…) y mezclas propias';

  @override
  String get settingsHifiTitle => 'Modo Hi-Fi (bit-perfect)';

  @override
  String get settingsHifiSubtitle =>
      'Desactiva EQ, fades y procesado; monitor de output device y capability AAudio';

  @override
  String get settingsFloatingTitle => 'Mini flotante';

  @override
  String get settingsFloatingSubtitle =>
      'Widget pill sobre el sistema con cover + controles (experimental, solo Android)';

  @override
  String get settingsLanguageTitle => 'Idioma';

  @override
  String get settingsLanguageSubtitle =>
      'Sigue al sistema o elígelo manualmente';

  @override
  String get settingsReset => 'Restablecer ajustes';

  @override
  String get languageSystem => 'Sistema';

  @override
  String get languageScreenHint =>
      'Por defecto Vibra usa el idioma configurado en tu dispositivo. Elige uno aquí para forzarlo solo en la app.';

  @override
  String get qualityAudioWifi => 'Audio en WiFi';

  @override
  String get qualityAudioCellular => 'Audio en datos móviles';

  @override
  String get qualityAudioCellularSubtitle =>
      'Por defecto media para no quemar el plan. Sube a alta si tienes datos ilimitados.';

  @override
  String get qualityVideoWifi => 'Video en WiFi';

  @override
  String get qualityVideoWifiSubtitle =>
      'Resolución de imagen del music video. El cambio aplica al siguiente video que cargue.';

  @override
  String get qualityVideoCellular => 'Video en datos móviles';

  @override
  String get qualityVideoCellularSubtitle =>
      'Default baja — 5 minutos de music video en 720p+ consumen ~100MB.';

  @override
  String get qualityDownloads => 'Calidad de descargas';

  @override
  String get qualityDownloadsSubtitle =>
      'Se aplica a las canciones descargadas para reproducir offline. Los archivos quedan en el dispositivo.';

  @override
  String get qualityAudioLow => 'Baja (~96 kbps)';

  @override
  String get qualityAudioMedium => 'Media (~160 kbps)';

  @override
  String get qualityAudioHigh => 'Alta';

  @override
  String get qualityVideoLow => 'Baja (360p)';

  @override
  String get qualityVideoMedium => 'Media (720p)';

  @override
  String get qualityVideoHigh => 'Alta (máxima disponible)';

  @override
  String get autoplayTitle => 'Autoplay al acabar la cola';

  @override
  String get autoplaySubtitle =>
      'Cuando la cola de streaming termina (sin repetir), sigue con canciones relacionadas a la última — como YT Music. Apágalo si prefieres que la música pare al terminar.';

  @override
  String get downloadAsMp3Title => 'Descargar como MP3';

  @override
  String get downloadAsMp3Subtitle =>
      'Convierte la descarga a MP3 256 kbps con metadata incrustada (título, artista, álbum y carátula) — máxima compatibilidad con otras apps y dispositivos. La conversión tarda ~1-2 min por canción. Desactivado: se guarda el stream original (m4a/opus), más rápido y sin re-compresión.';

  @override
  String get downloadsTitle => 'Descargas';

  @override
  String get downloadsCancelAll => 'Cancelar todo';

  @override
  String downloadsQueuedHeader(int count) {
    return 'En cola · $count';
  }

  @override
  String downloadsDoneHeader(int count) {
    return 'Descargadas · $count';
  }

  @override
  String get downloadsEmptyQueue => 'No hay descargas en cola.';

  @override
  String get downloadsEmptyDone =>
      'Todavía no descargaste ninguna canción. Usa \"Descargar\" en el menú de una canción de streaming.';

  @override
  String get downloadsConverting => 'Convirtiendo…';

  @override
  String downloadsWaiting(String position) {
    return 'En espera · #$position';
  }

  @override
  String get downloadsUnavailable =>
      'El servicio de descargas no está disponible.';

  @override
  String get downloadsDeleteTooltip => 'Borrar descarga';

  @override
  String get actionPlay => 'Reproducir';

  @override
  String get actionShuffle => 'Reproducir aleatorio';

  @override
  String get actionPlayNext => 'Reproducir a continuación';

  @override
  String get actionAddToQueue => 'Añadir a la cola actual';

  @override
  String get actionSaveToPlaylist => 'Guardar en playlist';

  @override
  String get actionDownload => 'Descargar para offline';

  @override
  String get actionDownloadAll => 'Descargar todas';

  @override
  String get actionRemoveDownload => 'Quitar descarga';

  @override
  String get actionRemoveDownloads => 'Quitar descargas';

  @override
  String get actionInQueue => 'En cola…';

  @override
  String get actionDownloadsUnavailable => 'Descargas no disponibles';

  @override
  String get actionGoToArtist => 'Ir al artista';

  @override
  String get actionGoToAlbum => 'Ir al álbum';

  @override
  String snackDownloading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Descargando $count canciones…',
      one: 'Descargando 1 canción…',
    );
    return '$_temp0';
  }

  @override
  String snackDeletedDownloads(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count descargas eliminadas.',
      one: '1 descarga eliminada.',
    );
    return '$_temp0';
  }

  @override
  String snackAddedToQueue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Añadidas $count canciones al final de la cola.',
      one: 'Añadida 1 canción al final de la cola.',
    );
    return '$_temp0';
  }

  @override
  String get speedPitchTitle => 'Velocidad y tono';

  @override
  String get speedLabel => 'Velocidad';

  @override
  String get pitchLabel => 'Tono (semitonos)';

  @override
  String get pitchLockedHint =>
      'Pitch bloqueado a velocidad — el slider de tono queda desactivado.';

  @override
  String get chipmunkTitle => 'Tono sigue a velocidad (chipmunk)';

  @override
  String get chipmunkSubtitle =>
      'Subir velocidad sube el tono y viceversa, como una cinta vieja. Default: tono independiente.';

  @override
  String get sleepTimerTitle => 'Temporizador de apagado';

  @override
  String get sleepAtTrackEnd => 'Fin de canción';

  @override
  String sleepMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get sleepStatusTrackEnd => 'Se pausará al terminar esta canción.';

  @override
  String sleepStatusAt(String time) {
    return 'Se pausará a las $time.';
  }

  @override
  String get nowPlaying => 'Reproduciendo';

  @override
  String get nothingPlaying => 'Nada en reproducción.';

  @override
  String get tooltipShowQueue => 'Ver cola';

  @override
  String get tooltipHideQueue => 'Ocultar cola';

  @override
  String get tooltipShowCover => 'Ver carátula';

  @override
  String get tooltipShowVideo => 'Ver video';

  @override
  String get tooltipChangeColor => 'Cambiar color';

  @override
  String get tooltipShowLyrics => 'Ver letra';

  @override
  String get tooltipHideLyrics => 'Ocultar letra';

  @override
  String get tooltipMoreOptions => 'Más opciones';

  @override
  String get onboardSkip => 'Saltar';

  @override
  String get onboardNext => 'Siguiente';

  @override
  String get onboardWelcomeTitle => 'Bienvenido a Vibra';

  @override
  String get onboardWelcomeBody =>
      'Tu música local y el catálogo de YouTube Music en un solo reproductor, con una interfaz que se tiñe con los colores de cada portada. Fondos, formas y animaciones: todo se puede personalizar en Ajustes.';

  @override
  String get onboardLibraryTitle => 'Biblioteca y descargas';

  @override
  String get onboardLibraryBody =>
      'Vibra escanea la música de tu dispositivo y la agrupa por álbumes y artistas. Las canciones de streaming se pueden descargar (menú ⋮ → Descargar) y quedan como MP3 con carátula en una carpeta pública — visibles desde el explorador de archivos y otras apps.';

  @override
  String get onboardAccountTitle => 'Tu cuenta (opcional)';

  @override
  String get onboardAccountBody =>
      'Sin cuenta puedes buscar y reproducir todo el catálogo. Iniciando sesión con Google además tienes tu biblioteca personal: tus playlists, gustadas, historial y recomendaciones a tu medida.';

  @override
  String get onboardSignIn => 'Iniciar sesión con Google';

  @override
  String get onboardExplore => 'Explorar sin cuenta';
}
