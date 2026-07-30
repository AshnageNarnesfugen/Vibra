import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// No description provided for @homeTab.
  ///
  /// In es, this message translates to:
  /// **'Inicio'**
  String get homeTab;

  /// No description provided for @libraryTab.
  ///
  /// In es, this message translates to:
  /// **'Biblioteca'**
  String get libraryTab;

  /// No description provided for @settingsTitle.
  ///
  /// In es, this message translates to:
  /// **'Ajustes'**
  String get settingsTitle;

  /// No description provided for @cancel.
  ///
  /// In es, this message translates to:
  /// **'Cancelar'**
  String get cancel;

  /// No description provided for @settingsAccountTitle.
  ///
  /// In es, this message translates to:
  /// **'Cuenta de YouTube Music'**
  String get settingsAccountTitle;

  /// No description provided for @settingsAccountActive.
  ///
  /// In es, this message translates to:
  /// **'Sesión activa — biblioteca personal habilitada'**
  String get settingsAccountActive;

  /// No description provided for @settingsAccountOauthLimited.
  ///
  /// In es, this message translates to:
  /// **'OAuth guardado pero limitado por Google — usá cookie'**
  String get settingsAccountOauthLimited;

  /// No description provided for @settingsAccountNone.
  ///
  /// In es, this message translates to:
  /// **'Sin sesión — solo búsqueda pública'**
  String get settingsAccountNone;

  /// No description provided for @settingsBackgroundTitle.
  ///
  /// In es, this message translates to:
  /// **'Fondo'**
  String get settingsBackgroundTitle;

  /// No description provided for @settingsBackgroundSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Color sólido o imagen ajustable, opacidad'**
  String get settingsBackgroundSubtitle;

  /// No description provided for @settingsEffectsTitle.
  ///
  /// In es, this message translates to:
  /// **'Efectos'**
  String get settingsEffectsTitle;

  /// No description provided for @settingsEffectsSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Blur, ruido y parallax al inclinar el dispositivo'**
  String get settingsEffectsSubtitle;

  /// No description provided for @settingsThemeTitle.
  ///
  /// In es, this message translates to:
  /// **'Tema y color'**
  String get settingsThemeTitle;

  /// No description provided for @settingsThemeSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Color dinámico desde la portada o acento por defecto'**
  String get settingsThemeSubtitle;

  /// No description provided for @settingsSpacingTitle.
  ///
  /// In es, this message translates to:
  /// **'Espaciado y bordes'**
  String get settingsSpacingTitle;

  /// No description provided for @settingsSpacingSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Densidad y radio uniforme'**
  String get settingsSpacingSubtitle;

  /// No description provided for @settingsAnimationsTitle.
  ///
  /// In es, this message translates to:
  /// **'Animaciones'**
  String get settingsAnimationsTitle;

  /// No description provided for @settingsAnimationsSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Estilo y duración de las transiciones'**
  String get settingsAnimationsSubtitle;

  /// No description provided for @settingsQualityTitle.
  ///
  /// In es, this message translates to:
  /// **'Calidad de audio y video'**
  String get settingsQualityTitle;

  /// No description provided for @settingsQualitySubtitle.
  ///
  /// In es, this message translates to:
  /// **'Bitrate diferente en WiFi vs datos móviles; calidad de descargas'**
  String get settingsQualitySubtitle;

  /// No description provided for @settingsStorageTitle.
  ///
  /// In es, this message translates to:
  /// **'Almacenamiento'**
  String get settingsStorageTitle;

  /// No description provided for @settingsStorageSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Dónde vive la música descargada y las carpetas de la app'**
  String get settingsStorageSubtitle;

  /// No description provided for @settingsEqTitle.
  ///
  /// In es, this message translates to:
  /// **'Ecualizador'**
  String get settingsEqTitle;

  /// No description provided for @settingsEqSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Bandas + preamp + presets (Rock, Bass Boost, V-Shape…) y mezclas propias'**
  String get settingsEqSubtitle;

  /// No description provided for @settingsHifiTitle.
  ///
  /// In es, this message translates to:
  /// **'Modo Hi-Fi (bit-perfect)'**
  String get settingsHifiTitle;

  /// No description provided for @settingsHifiSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Desactiva EQ, fades y procesado; monitor de output device y capability AAudio'**
  String get settingsHifiSubtitle;

  /// No description provided for @settingsFloatingTitle.
  ///
  /// In es, this message translates to:
  /// **'Mini flotante'**
  String get settingsFloatingTitle;

  /// No description provided for @settingsFloatingSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Widget pill sobre el sistema con cover + controles (experimental, solo Android)'**
  String get settingsFloatingSubtitle;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In es, this message translates to:
  /// **'Idioma'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Sigue al sistema o elígelo manualmente'**
  String get settingsLanguageSubtitle;

  /// No description provided for @settingsReset.
  ///
  /// In es, this message translates to:
  /// **'Restablecer ajustes'**
  String get settingsReset;

  /// No description provided for @languageSystem.
  ///
  /// In es, this message translates to:
  /// **'Sistema'**
  String get languageSystem;

  /// No description provided for @languageScreenHint.
  ///
  /// In es, this message translates to:
  /// **'Por defecto Vibra usa el idioma configurado en tu dispositivo. Elige uno aquí para forzarlo solo en la app.'**
  String get languageScreenHint;

  /// No description provided for @qualityAudioWifi.
  ///
  /// In es, this message translates to:
  /// **'Audio en WiFi'**
  String get qualityAudioWifi;

  /// No description provided for @qualityAudioCellular.
  ///
  /// In es, this message translates to:
  /// **'Audio en datos móviles'**
  String get qualityAudioCellular;

  /// No description provided for @qualityAudioCellularSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Por defecto media para no quemar el plan. Sube a alta si tienes datos ilimitados.'**
  String get qualityAudioCellularSubtitle;

  /// No description provided for @qualityVideoWifi.
  ///
  /// In es, this message translates to:
  /// **'Video en WiFi'**
  String get qualityVideoWifi;

  /// No description provided for @qualityVideoWifiSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Resolución de imagen del music video. El cambio aplica al siguiente video que cargue.'**
  String get qualityVideoWifiSubtitle;

  /// No description provided for @qualityVideoCellular.
  ///
  /// In es, this message translates to:
  /// **'Video en datos móviles'**
  String get qualityVideoCellular;

  /// No description provided for @qualityVideoCellularSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Default baja — 5 minutos de music video en 720p+ consumen ~100MB.'**
  String get qualityVideoCellularSubtitle;

  /// No description provided for @qualityDownloads.
  ///
  /// In es, this message translates to:
  /// **'Calidad de descargas'**
  String get qualityDownloads;

  /// No description provided for @qualityDownloadsSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Se aplica a las canciones descargadas para reproducir offline. Los archivos quedan en el dispositivo.'**
  String get qualityDownloadsSubtitle;

  /// No description provided for @qualityAudioLow.
  ///
  /// In es, this message translates to:
  /// **'Baja (~96 kbps)'**
  String get qualityAudioLow;

  /// No description provided for @qualityAudioMedium.
  ///
  /// In es, this message translates to:
  /// **'Media (~160 kbps)'**
  String get qualityAudioMedium;

  /// No description provided for @qualityAudioHigh.
  ///
  /// In es, this message translates to:
  /// **'Alta'**
  String get qualityAudioHigh;

  /// No description provided for @qualityVideoLow.
  ///
  /// In es, this message translates to:
  /// **'Baja (360p)'**
  String get qualityVideoLow;

  /// No description provided for @qualityVideoMedium.
  ///
  /// In es, this message translates to:
  /// **'Media (720p)'**
  String get qualityVideoMedium;

  /// No description provided for @qualityVideoHigh.
  ///
  /// In es, this message translates to:
  /// **'Alta (máxima disponible)'**
  String get qualityVideoHigh;

  /// No description provided for @autoplayTitle.
  ///
  /// In es, this message translates to:
  /// **'Autoplay al acabar la cola'**
  String get autoplayTitle;

  /// No description provided for @autoplaySubtitle.
  ///
  /// In es, this message translates to:
  /// **'Cuando la cola de streaming termina (sin repetir), sigue con canciones relacionadas a la última — como YT Music. Apágalo si prefieres que la música pare al terminar.'**
  String get autoplaySubtitle;

  /// No description provided for @downloadAsMp3Title.
  ///
  /// In es, this message translates to:
  /// **'Descargar como MP3'**
  String get downloadAsMp3Title;

  /// No description provided for @downloadAsMp3Subtitle.
  ///
  /// In es, this message translates to:
  /// **'Convierte la descarga a MP3 256 kbps con metadata incrustada (título, artista, álbum y carátula) — máxima compatibilidad con otras apps y dispositivos. La conversión tarda ~1-2 min por canción. Desactivado: se guarda el stream original (m4a/opus), más rápido y sin re-compresión.'**
  String get downloadAsMp3Subtitle;

  /// No description provided for @downloadsTitle.
  ///
  /// In es, this message translates to:
  /// **'Descargas'**
  String get downloadsTitle;

  /// No description provided for @downloadsCancelAll.
  ///
  /// In es, this message translates to:
  /// **'Cancelar todo'**
  String get downloadsCancelAll;

  /// No description provided for @downloadsQueuedHeader.
  ///
  /// In es, this message translates to:
  /// **'En cola · {count}'**
  String downloadsQueuedHeader(int count);

  /// No description provided for @downloadsDoneHeader.
  ///
  /// In es, this message translates to:
  /// **'Descargadas · {count}'**
  String downloadsDoneHeader(int count);

  /// No description provided for @downloadsEmptyQueue.
  ///
  /// In es, this message translates to:
  /// **'No hay descargas en cola.'**
  String get downloadsEmptyQueue;

  /// No description provided for @downloadsEmptyDone.
  ///
  /// In es, this message translates to:
  /// **'Todavía no descargaste ninguna canción. Usa \"Descargar\" en el menú de una canción de streaming.'**
  String get downloadsEmptyDone;

  /// No description provided for @downloadsConverting.
  ///
  /// In es, this message translates to:
  /// **'Convirtiendo…'**
  String get downloadsConverting;

  /// No description provided for @downloadsWaiting.
  ///
  /// In es, this message translates to:
  /// **'En espera · #{position}'**
  String downloadsWaiting(String position);

  /// No description provided for @downloadsUnavailable.
  ///
  /// In es, this message translates to:
  /// **'El servicio de descargas no está disponible.'**
  String get downloadsUnavailable;

  /// No description provided for @downloadsDeleteTooltip.
  ///
  /// In es, this message translates to:
  /// **'Borrar descarga'**
  String get downloadsDeleteTooltip;

  /// No description provided for @actionPlay.
  ///
  /// In es, this message translates to:
  /// **'Reproducir'**
  String get actionPlay;

  /// No description provided for @actionShuffle.
  ///
  /// In es, this message translates to:
  /// **'Reproducir aleatorio'**
  String get actionShuffle;

  /// No description provided for @actionPlayNext.
  ///
  /// In es, this message translates to:
  /// **'Reproducir a continuación'**
  String get actionPlayNext;

  /// No description provided for @actionAddToQueue.
  ///
  /// In es, this message translates to:
  /// **'Añadir a la cola actual'**
  String get actionAddToQueue;

  /// No description provided for @actionSaveToPlaylist.
  ///
  /// In es, this message translates to:
  /// **'Guardar en playlist'**
  String get actionSaveToPlaylist;

  /// No description provided for @actionDownload.
  ///
  /// In es, this message translates to:
  /// **'Descargar para offline'**
  String get actionDownload;

  /// No description provided for @actionDownloadAll.
  ///
  /// In es, this message translates to:
  /// **'Descargar todas'**
  String get actionDownloadAll;

  /// No description provided for @actionRemoveDownload.
  ///
  /// In es, this message translates to:
  /// **'Quitar descarga'**
  String get actionRemoveDownload;

  /// No description provided for @actionRemoveDownloads.
  ///
  /// In es, this message translates to:
  /// **'Quitar descargas'**
  String get actionRemoveDownloads;

  /// No description provided for @actionInQueue.
  ///
  /// In es, this message translates to:
  /// **'En cola…'**
  String get actionInQueue;

  /// No description provided for @actionDownloadsUnavailable.
  ///
  /// In es, this message translates to:
  /// **'Descargas no disponibles'**
  String get actionDownloadsUnavailable;

  /// No description provided for @actionGoToArtist.
  ///
  /// In es, this message translates to:
  /// **'Ir al artista'**
  String get actionGoToArtist;

  /// No description provided for @actionGoToAlbum.
  ///
  /// In es, this message translates to:
  /// **'Ir al álbum'**
  String get actionGoToAlbum;

  /// No description provided for @snackDownloading.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{Descargando 1 canción…} other{Descargando {count} canciones…}}'**
  String snackDownloading(int count);

  /// No description provided for @snackDeletedDownloads.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{1 descarga eliminada.} other{{count} descargas eliminadas.}}'**
  String snackDeletedDownloads(int count);

  /// No description provided for @snackAddedToQueue.
  ///
  /// In es, this message translates to:
  /// **'{count, plural, =1{Añadida 1 canción al final de la cola.} other{Añadidas {count} canciones al final de la cola.}}'**
  String snackAddedToQueue(int count);

  /// No description provided for @speedPitchTitle.
  ///
  /// In es, this message translates to:
  /// **'Velocidad y tono'**
  String get speedPitchTitle;

  /// No description provided for @speedLabel.
  ///
  /// In es, this message translates to:
  /// **'Velocidad'**
  String get speedLabel;

  /// No description provided for @pitchLabel.
  ///
  /// In es, this message translates to:
  /// **'Tono (semitonos)'**
  String get pitchLabel;

  /// No description provided for @pitchLockedHint.
  ///
  /// In es, this message translates to:
  /// **'Pitch bloqueado a velocidad — el slider de tono queda desactivado.'**
  String get pitchLockedHint;

  /// No description provided for @chipmunkTitle.
  ///
  /// In es, this message translates to:
  /// **'Tono sigue a velocidad (chipmunk)'**
  String get chipmunkTitle;

  /// No description provided for @chipmunkSubtitle.
  ///
  /// In es, this message translates to:
  /// **'Subir velocidad sube el tono y viceversa, como una cinta vieja. Default: tono independiente.'**
  String get chipmunkSubtitle;

  /// No description provided for @sleepTimerTitle.
  ///
  /// In es, this message translates to:
  /// **'Temporizador de apagado'**
  String get sleepTimerTitle;

  /// No description provided for @sleepAtTrackEnd.
  ///
  /// In es, this message translates to:
  /// **'Fin de canción'**
  String get sleepAtTrackEnd;

  /// No description provided for @sleepMinutes.
  ///
  /// In es, this message translates to:
  /// **'{minutes} min'**
  String sleepMinutes(int minutes);

  /// No description provided for @sleepStatusTrackEnd.
  ///
  /// In es, this message translates to:
  /// **'Se pausará al terminar esta canción.'**
  String get sleepStatusTrackEnd;

  /// No description provided for @sleepStatusAt.
  ///
  /// In es, this message translates to:
  /// **'Se pausará a las {time}.'**
  String sleepStatusAt(String time);

  /// No description provided for @nowPlaying.
  ///
  /// In es, this message translates to:
  /// **'Reproduciendo'**
  String get nowPlaying;

  /// No description provided for @nothingPlaying.
  ///
  /// In es, this message translates to:
  /// **'Nada en reproducción.'**
  String get nothingPlaying;

  /// No description provided for @tooltipShowQueue.
  ///
  /// In es, this message translates to:
  /// **'Ver cola'**
  String get tooltipShowQueue;

  /// No description provided for @tooltipHideQueue.
  ///
  /// In es, this message translates to:
  /// **'Ocultar cola'**
  String get tooltipHideQueue;

  /// No description provided for @tooltipShowCover.
  ///
  /// In es, this message translates to:
  /// **'Ver carátula'**
  String get tooltipShowCover;

  /// No description provided for @tooltipShowVideo.
  ///
  /// In es, this message translates to:
  /// **'Ver video'**
  String get tooltipShowVideo;

  /// No description provided for @tooltipChangeColor.
  ///
  /// In es, this message translates to:
  /// **'Cambiar color'**
  String get tooltipChangeColor;

  /// No description provided for @tooltipShowLyrics.
  ///
  /// In es, this message translates to:
  /// **'Ver letra'**
  String get tooltipShowLyrics;

  /// No description provided for @tooltipHideLyrics.
  ///
  /// In es, this message translates to:
  /// **'Ocultar letra'**
  String get tooltipHideLyrics;

  /// No description provided for @tooltipMoreOptions.
  ///
  /// In es, this message translates to:
  /// **'Más opciones'**
  String get tooltipMoreOptions;

  /// No description provided for @onboardSkip.
  ///
  /// In es, this message translates to:
  /// **'Saltar'**
  String get onboardSkip;

  /// No description provided for @onboardNext.
  ///
  /// In es, this message translates to:
  /// **'Siguiente'**
  String get onboardNext;

  /// No description provided for @onboardWelcomeTitle.
  ///
  /// In es, this message translates to:
  /// **'Bienvenido a Vibra'**
  String get onboardWelcomeTitle;

  /// No description provided for @onboardWelcomeBody.
  ///
  /// In es, this message translates to:
  /// **'Tu música local y el catálogo de YouTube Music en un solo reproductor, con una interfaz que se tiñe con los colores de cada portada. Fondos, formas y animaciones: todo se puede personalizar en Ajustes.'**
  String get onboardWelcomeBody;

  /// No description provided for @onboardLibraryTitle.
  ///
  /// In es, this message translates to:
  /// **'Biblioteca y descargas'**
  String get onboardLibraryTitle;

  /// No description provided for @onboardLibraryBody.
  ///
  /// In es, this message translates to:
  /// **'Vibra escanea la música de tu dispositivo y la agrupa por álbumes y artistas. Las canciones de streaming se pueden descargar (menú ⋮ → Descargar) y quedan como MP3 con carátula en una carpeta pública — visibles desde el explorador de archivos y otras apps.'**
  String get onboardLibraryBody;

  /// No description provided for @onboardAccountTitle.
  ///
  /// In es, this message translates to:
  /// **'Tu cuenta (opcional)'**
  String get onboardAccountTitle;

  /// No description provided for @onboardAccountBody.
  ///
  /// In es, this message translates to:
  /// **'Sin cuenta puedes buscar y reproducir todo el catálogo. Iniciando sesión con Google además tienes tu biblioteca personal: tus playlists, gustadas, historial y recomendaciones a tu medida.'**
  String get onboardAccountBody;

  /// No description provided for @onboardSignIn.
  ///
  /// In es, this message translates to:
  /// **'Iniciar sesión con Google'**
  String get onboardSignIn;

  /// No description provided for @onboardExplore.
  ///
  /// In es, this message translates to:
  /// **'Explorar sin cuenta'**
  String get onboardExplore;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
