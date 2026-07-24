import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../animations/background_shader.dart';

export '../animations/background_shader.dart';

/// Tipo de fondo que el usuario puede seleccionar.
enum BackgroundMode { solidColor, image, animatedGradient }

/// Forma de renderizado de la carátula en el PlayerScreen.
///   - `square`: cuadrado con esquinas redondeadas (estándar).
///   - `cd`: forma de disco con orificio central, gira lento mientras
///     reproduce (estilo iPod nano / vinilo digital).
///   - `holographic`: cuadrado clásico con overlay holográfico que
///     reacciona al giroscopio — efecto "papel holo" de carta
///     coleccionable + tilt 3D sutil del cover entero.
enum CoverShape { square, cd, holographic }

/// Nivel de calidad/bitrate aplicado al stream y a la descarga local.
///   - `low`: bitrate más bajo disponible (~48-96kbps). Útil para datos
///     móviles limitados.
///   - `medium`: bitrate medio (~128kbps). Balance estándar.
///   - `high`: el bitrate más alto que YT Music ofrezca para el track
///     (~256kbps AAC / Opus 160). Wifi fija o descargas para offline.
enum MediaQuality { low, medium, high }

/// Modo de tema con 4 opciones:
///   - `light` / `dark`: forzados por el usuario.
///   - `auto`: derivado de la luminancia del background actual (bg oscuro =
///     dark, bg claro = light). Útil cuando el usuario usa carátulas
///     dinámicas y quiere que el tema se adapte solo.
///   - `system`: sigue el ajuste del sistema operativo
///     (`MediaQuery.platformBrightness`).
enum AppThemeMode { light, dark, auto, system }

extension AppThemeModeX on AppThemeMode {
  String get label => switch (this) {
        AppThemeMode.light => 'Claro',
        AppThemeMode.dark => 'Oscuro',
        AppThemeMode.auto => 'Auto',
        AppThemeMode.system => 'Sistema',
      };

  /// Resuelve la `Brightness` efectiva. `bgLuminance` se usa sólo en `auto`
  /// (luminancia del color predominante del fondo computada por el theme
  /// builder). `systemBrightness` debe venir de
  /// `MediaQuery.platformBrightnessOf(context)`.
  Brightness resolve({
    required Brightness systemBrightness,
    double? bgLuminance,
  }) =>
      switch (this) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        AppThemeMode.system => systemBrightness,
        AppThemeMode.auto =>
          (bgLuminance ?? 0) > 0.45 ? Brightness.light : Brightness.dark,
      };
}

/// De dónde sale la lista de canciones de la biblioteca.
///   - auto: API del SO (Android: on_audio_query). En Linux/desktop está
///     vacío y el usuario debe pasar a [manualFolder].
///   - manualFolder: el usuario elige una carpeta y nosotros la escaneamos
///     buscando archivos de audio. Funciona en cualquier plataforma.
///   - streaming: la "biblioteca" se vuelve un buscador en vivo contra
///     YouTube Music (cliente InnerTube). Requiere conexión.
enum LibrarySource { auto, manualFolder, streaming }

extension LibrarySourceX on LibrarySource {
  String get label => switch (this) {
        LibrarySource.auto => 'Automático del sistema',
        LibrarySource.manualFolder => 'Carpeta manual',
        LibrarySource.streaming => 'Streaming (YouTube Music)',
      };
}

/// Cómo se mapean los colores extraídos de la portada al gradiente animado.
///
/// El problema clásico de palette_generator: el `dominantColor` es el color
/// con MÁS pixels — suele ser el fondo ambiental (gris, beige) y NO la
/// "vibra" del album. Antes la única opción era usar dominant + accent, y
/// el shader se veía gris incluso con álbumes vibrantes.
///
///   - [vibrant]: usa los tonos más saturados (vibrant/lightVibrant/
///     darkVibrant). Mejor para reflejar la energía del album. **Default**.
///   - [twoColor]: solo dos colores — dominant + accent + derivado oscuro
///     del primero. Look más sobrio.
///   - [full]: mezcla los 3 colores más distintos disponibles para máxima
///     variedad visual.
///   - [dominant]: comportamiento legacy — usa dominant como base. Más
///     "ambiental" / muted.
enum BackgroundPaletteMode { vibrant, twoColor, full, dominant }

extension BackgroundPaletteModeX on BackgroundPaletteMode {
  String get label => switch (this) {
        BackgroundPaletteMode.vibrant => 'Vibrante',
        BackgroundPaletteMode.twoColor => '2 colores',
        BackgroundPaletteMode.full => 'Paleta completa',
        BackgroundPaletteMode.dominant => 'Dominante',
      };

  String get description => switch (this) {
        BackgroundPaletteMode.vibrant =>
          'Toma los tonos más saturados de la portada. Refleja mejor la "vibra" del álbum.',
        BackgroundPaletteMode.twoColor =>
          'Solo dos colores: el dominante y el acento. Look más sobrio.',
        BackgroundPaletteMode.full =>
          'Mezcla los 3 swatches más distintos. Más variedad pero puede sentirse caótico.',
        BackgroundPaletteMode.dominant =>
          'Usa el color que más aparece en la portada como base. Tiende a verse "ambiental" o gris.',
      };
}

/// Animaciones disponibles para transiciones entre vistas.
enum PageTransitionStyle {
  fade,
  slideUp,
  slideRight,
  scale,
  fadeThrough,
  sharedAxisHorizontal,
  none,
}

extension PageTransitionStyleX on PageTransitionStyle {
  String get label => switch (this) {
        PageTransitionStyle.fade => 'Fundido',
        PageTransitionStyle.slideUp => 'Deslizar hacia arriba',
        PageTransitionStyle.slideRight => 'Deslizar lateral',
        PageTransitionStyle.scale => 'Escala',
        PageTransitionStyle.fadeThrough => 'Atravesar',
        PageTransitionStyle.sharedAxisHorizontal => 'Eje compartido',
        PageTransitionStyle.none => 'Sin animación',
      };
}

extension BackgroundModeX on BackgroundMode {
  String get label => switch (this) {
        BackgroundMode.solidColor => 'Color sólido',
        BackgroundMode.image => 'Imagen',
        BackgroundMode.animatedGradient => 'Gradiente',
      };
}

/// Posicionamiento normalizado del background image:
///  - [scale] >= 1 controla el zoom de la imagen.
///  - [offsetX] y [offsetY] son desplazamientos relativos al tamaño del lienzo
///    (-1..1) para que sean independientes del dispositivo.
@immutable
class BackgroundImageTransform {
  const BackgroundImageTransform({
    this.scale = 1.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
  });

  final double scale;
  final double offsetX;
  final double offsetY;

  BackgroundImageTransform copyWith({
    double? scale,
    double? offsetX,
    double? offsetY,
  }) {
    return BackgroundImageTransform(
      scale: scale ?? this.scale,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
    );
  }

  Map<String, dynamic> toMap() => {
        'scale': scale,
        'offsetX': offsetX,
        'offsetY': offsetY,
      };

  factory BackgroundImageTransform.fromMap(Map<String, dynamic> m) {
    return BackgroundImageTransform(
      scale: (m['scale'] as num?)?.toDouble() ?? 1.0,
      offsetX: (m['offsetX'] as num?)?.toDouble() ?? 0.0,
      offsetY: (m['offsetY'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Estado completo de personalización de la UI. Inmutable + serializable.
@immutable
class UiSettings {
  const UiSettings({
    this.coverShape = CoverShape.square,
    this.holoTiltIntensity = 1.0,
    this.holoParallaxIntensity = 1.0,
    this.playbackSpeed = 1.0,
    this.playbackPitchSemitones = 0.0,
    this.lockPitchToSpeed = false,
    this.bitPerfectModeEnabled = false,
    this.audioQualityWifi = MediaQuality.high,
    this.audioQualityCellular = MediaQuality.medium,
    this.videoQualityWifi = MediaQuality.high,
    this.videoQualityCellular = MediaQuality.low,
    this.downloadQuality = MediaQuality.high,
    this.downloadAsMp3 = true,
    this.autoplayRelated = true,
    this.floatingMiniEnabled = false,
    this.fadeOnPlayPauseEnabled = false,
    this.fadeDurationMs = 350,
    this.backgroundMode = BackgroundMode.solidColor,
    this.solidBackgroundColor = const Color(0xFF101015),
    this.backgroundImagePath,
    this.backgroundImageTransform = const BackgroundImageTransform(),
    this.backgroundOpacity = 1.0,
    this.surfaceOpacity = 0.78,
    this.useAlbumArtAsBackground = true,
    this.useAlbumColorAsSolid = false,
    this.useAmbientVideoPalette = true,
    this.useVideoBackgroundIfAvailable = false,
    this.blurEnabled = false,
    this.blurIntensity = 18.0,
    this.noiseIntensity = 0.0,
    this.useDynamicColorFromAlbumArt = true,
    this.fallbackAccentColor = const Color(0xFF7C5CFF),
    this.fallbackOnAccentColor = const Color(0xFFFFFFFF),
    this.fallbackSecondaryColor,
    this.backgroundImageAccentColor,
    this.spacingScale = 1.0,
    this.cornerRadius = 16.0,
    this.songTileMinWidth = 360.0,
    this.transitionStyle = PageTransitionStyle.slideRight,
    this.transitionDurationMs = 350,
    this.themeMode = AppThemeMode.dark,
    // Default OFF: en cold start arrancar la suscripción al acelerómetro
    // puede tardar / fallar en algunos devices. El usuario lo activa en
    // Efectos > Movimiento cuando quiere.
    this.parallaxEnabled = false,
    this.parallaxIntensity = 0.5,
    this.gradientSpeed = 0.4,
    this.backgroundShader = BackgroundShader.aurora,
    this.backgroundPaletteMode = BackgroundPaletteMode.vibrant,
    // Default OFF para que un primer arranque no dispare el pre-render de
    // blur (es relativamente caro en GPU). El usuario lo activa en Efectos.
    this.cardBlurEnabled = false,
    this.cardBlurIntensity = 14.0,
    this.cardNoiseIntensity = 0.0,
    this.librarySource = LibrarySource.auto,
    this.manualFolderPath,
    this.ytMusicCookie,
    this.ytMusicVisitorData,
    this.ytMusicDataSyncId,
    this.ytMusicAccessToken,
    this.ytMusicRefreshToken,
    this.ytMusicAccessTokenExpiryEpochMs,
  });

  final BackgroundMode backgroundMode;

  /// Forma de la carátula en PlayerScreen (cuadrado / CD girando /
  /// holográfico con tilt giroscópico).
  final CoverShape coverShape;

  /// Intensidad del tilt 3D del cover holográfico (0.0 = sin tilt, solo
  /// la animación iridiscente del shader; 1.0 = inclinación máxima al
  /// mover el device). Solo aplica con [CoverShape.holographic].
  final double holoTiltIntensity;

  /// Intensidad del parallax holográfico — cuánto se desplazan las bandas
  /// iridiscentes del shader en respuesta al giroscopio (0.0 = bandas fijas
  /// solo animadas por tiempo; 1.0 = shift máximo con viewing angle).
  /// Independiente de [holoTiltIntensity]: el usuario puede tener cover
  /// plano con bandas que se mueven, o cover tilteado con bandas estáticas.
  final double holoParallaxIntensity;

  /// Velocidad de reproducción (rango 0.5–2.0; 1.0 = normal). Se aplica via
  /// `AudioPlayer.setSpeed`, que en ExoPlayer usa Sonic time-stretch — el
  /// pitch se preserva por default. Para chipmunk effect, activar
  /// [lockPitchToSpeed].
  final double playbackSpeed;

  /// Pitch shift en semitonos (rango -12.0 a +12.0; 0 = sin shift). Se
  /// convierte a multiplicador con `2^(s/12)` y se pasa a
  /// `AudioPlayer.setPitch`. Independiente de [playbackSpeed] cuando
  /// [lockPitchToSpeed] es false. Solo Android — en iOS just_audio liga
  /// pitch al speed.
  final double playbackPitchSemitones;

  /// Cuando true, cambiar la velocidad también cambia el pitch proporcionalmente
  /// (chipmunk / slow-low effect). Default false → speed y pitch independientes,
  /// que es lo que el usuario espera de una app de música.
  final bool lockPitchToSpeed;

  /// Modo "Hi-Fi / Bit-perfect": cuando ON, todos los procesos que tocan la
  /// señal de audio quedan neutralizados — EQ desactivado, preamp a 0, fades
  /// de play/pause off, lock pitch off. La intención es entregar el archivo
  /// fuente lo más fiel posible al output, replicando lo que hacen los DAPs
  /// audiophile. NO incluye AAudio EXCLUSIVE (eso requiere plugin nativo).
  ///
  /// `BitPerfectController` se encarga de FORZAR los otros settings a sus
  /// valores neutrales cuando este toggle está ON — el usuario no puede
  /// activar EQ mientras bit-perfect está prendido.
  final bool bitPerfectModeEnabled;

  /// Calidad de stream cuando hay conexión WiFi. Default high.
  final MediaQuality audioQualityWifi;

  /// Calidad de stream cuando hay conexión por datos móviles. Default
  /// medium — la mayoría de usuarios tiene planes limitados.
  final MediaQuality audioQualityCellular;

  /// Calidad de video (music videos) en WiFi. Default high.
  final MediaQuality videoQualityWifi;

  /// Calidad de video en datos móviles. Default low — los videos a
  /// 720p+ queman ~100MB en 5min.
  final MediaQuality videoQualityCellular;

  /// Calidad usada para DESCARGAR a local (offline). Default high
  /// porque el archivo se queda en el device y vale la pena el size.
  final MediaQuality downloadQuality;

  /// Cuando true (default), las descargas de streaming se transcodifican
  /// a MP3 256kbps CBR con metadata ID3 incrustada (título, artista,
  /// álbum, carátula) — máxima compatibilidad con otras apps/dispositivos.
  /// Cuando false, se guarda el stream original de YT (m4a/opus): mejor
  /// calidad técnica (sin re-encode lossy→lossy) y más rápido, pero menos
  /// portable. Solo Android (el transcoder usa MediaCodec nativo).
  final bool downloadAsMp3;

  /// Autoplay al acabar la cola (solo streaming, repeat off): en vez de
  /// parar en silencio, sigue con recomendaciones relacionadas a la
  /// última canción — como hace YT Music. Default ON.
  final bool autoplayRelated;

  /// Mini reproductor flotante (Dynamic Island estilo) sobre el sistema.
  /// Solo Android. Requiere permiso `SYSTEM_ALERT_WINDOW` que el usuario
  /// debe conceder manualmente desde ajustes del sistema cuando activa
  /// este toggle por primera vez.
  final bool floatingMiniEnabled;

  /// Activa fade-in al reproducir y fade-out al pausar (ramp de volumen
  /// del player) — evita el "click" digital al cortar audio en seco.
  final bool fadeOnPlayPauseEnabled;

  /// Duración del ramp en ms. Rango razonable 100-1500. 350 default —
  /// se siente "suave" sin sentirse lag al tocar pausa.
  final int fadeDurationMs;
  final Color solidBackgroundColor;
  final String? backgroundImagePath;
  final BackgroundImageTransform backgroundImageTransform;

  /// 0..1 — opacidad de la imagen/color de fondo (no del contenido).
  final double backgroundOpacity;

  /// 0..1 — opacidad de superficies (cards, sheets) sobre el fondo.
  /// **Solo el valor crudo del slider**. Para el alpha REAL que se aplica
  /// a las cards, usar [effectiveSurfaceOpacity] que también escala con
  /// [backgroundOpacity] — sino al bajar el fondo las cards quedaban
  /// "flotando" opacas sobre un bg ya translúcido, rompiendo coherencia.
  final double surfaceOpacity;

  /// Alpha efectivo de cards/sheets: `surfaceOpacity × backgroundOpacity`.
  /// Cuando el slider de fondo va a 50%, las cards también ven su alpha
  /// reducido a la mitad — quedan sincronizadas con la "densidad" general
  /// del UI. Cuando ambos sliders están al 100%, sale 1.0 (sin cambio).
  double get effectiveSurfaceOpacity =>
      (surfaceOpacity * backgroundOpacity).clamp(0.0, 1.0);

  /// Cuando hay canción reproduciéndose con carátula, esa imagen se usa como
  /// fondo (con todos los efectos aplicados encima). Si no hay carátula, no
  /// hay canción activa, o esto está apagado, vuelve al fondo definido por
  /// el usuario ([backgroundMode] + [solidBackgroundColor]/[backgroundImagePath]).
  final bool useAlbumArtAsBackground;

  /// Cuando [backgroundMode] es [BackgroundMode.solidColor] y hay canción
  /// con portada, el fondo toma el color DOMINANTE de la carátula en lugar
  /// del color sólido elegido por el usuario. Sigue siendo un color plano
  /// (no la imagen) — solo la tonalidad se adapta a la canción.
  final bool useAlbumColorAsSolid;

  /// "Ambient mode" estilo YouTube: cuando hay un music video activo (en
  /// cover o como bg), el sistema muestrea las esquinas del video cada ~2s
  /// y aplica esos colores a TODA la UI (theme, shader, iconos adaptivos)
  /// con interpolación suave. Da el efecto de iluminación cinematográfica
  /// que sigue el ritmo visual del video.
  ///
  /// Coste: ~10ms por sample en hardware mid-range. Default ON.
  final bool useAmbientVideoPalette;

  /// Si está activo (y el modo es `image`), cuando la canción actual tenga
  /// un video musical disponible, lo reproducimos muteado como fondo
  /// reemplazando la imagen estática. Si no hay video, cae al
  /// comportamiento normal de imagen / carátula.
  final bool useVideoBackgroundIfAvailable;

  final bool blurEnabled;

  /// Sigma del [ImageFilter.blur] aplicado al fondo (0..40).
  final double blurIntensity;

  /// 0..1 — intensidad del overlay de ruido/grano.
  final double noiseIntensity;

  /// Si es true, intentamos pintar el tema con paleta extraída de la portada.
  final bool useDynamicColorFromAlbumArt;
  final Color fallbackAccentColor;
  final Color fallbackOnAccentColor;

  /// Segundo color del fondo "de color" cuando NO hay canción activa.
  /// `null` = automático: se deriva oscureciendo [fallbackAccentColor]
  /// (comportamiento histórico — el "moradito" que se veía por defecto
  /// era esta derivación del acento morado default). Si el usuario lo
  /// setea, el gradiente sin canción usa acento + este color.
  final Color? fallbackSecondaryColor;

  /// Color acento extraído de la imagen de fondo custom (se calcula al
  /// elegir la imagen y se cachea aquí). Cuando el fondo es una imagen
  /// custom, este color OVERRIDE al [fallbackAccentColor] — la UI se
  /// tiñe acorde al wallpaper elegido, no al acento genérico. Se limpia
  /// junto con `clearBackgroundImagePath`.
  final Color? backgroundImageAccentColor;

  /// Acento efectivo cuando NO hay paleta de canción activa: si el
  /// usuario eligió imagen de fondo custom y ya extrajimos su color,
  /// manda ese; en cualquier otro caso el acento elegido en ajustes.
  Color get effectiveFallbackAccent {
    if (backgroundMode == BackgroundMode.image &&
        backgroundImagePath != null &&
        backgroundImageAccentColor != null) {
      return backgroundImageAccentColor!;
    }
    return fallbackAccentColor;
  }

  /// Multiplicador global de espaciado (0.6..1.6).
  final double spacingScale;

  /// Radio uniforme aplicado a tarjetas y botones (0..32).
  final double cornerRadius;

  /// Ancho máximo (px) que un tile de canción puede ocupar en la grilla.
  /// El número de columnas en biblioteca/cola se calcula como
  /// `floor(anchoDisponible / songTileMinWidth)`. A más bajo, más columnas;
  /// a más alto, layout vertical clásico de una columna.
  final double songTileMinWidth;

  final PageTransitionStyle transitionStyle;
  final int transitionDurationMs;

  /// Modo de tema: `light`/`dark`/`auto`/`system`. El resolver computa la
  /// `Brightness` efectiva a partir de este valor + luminancia del bg
  /// actual (para `auto`) o brightness del SO (para `system`).
  final AppThemeMode themeMode;

  /// Parallax: el fondo se desplaza en respuesta a la inclinación del
  /// dispositivo (acelerómetro), como el wallpaper de la lock screen iOS.
  final bool parallaxEnabled;

  /// 0..1 — multiplica el desplazamiento máximo del parallax.
  final double parallaxIntensity;

  /// 0..1 — qué tan rápido se anima el shader del fondo (uniform `u_speed`).
  final double gradientSpeed;

  /// Shader GLSL elegido para el fondo animado. Solo aplica cuando
  /// [backgroundMode] es [BackgroundMode.animatedGradient]. Los shaders
  /// `paletteAware` (aurora/plasma/mesh) reciben los 3 colores del
  /// album/tema; el shader `liquid` tiene paleta fija propia y los ignora.
  final BackgroundShader backgroundShader;

  /// Cómo se eligen los 3 colores que se mandan al shader desde la paleta
  /// del album. Ver [BackgroundPaletteMode] para detalles.
  final BackgroundPaletteMode backgroundPaletteMode;

  /// Blur PROPIO de las tarjetas / sheets (frosted glass), independiente del
  /// blur global del fondo. Si está activo, las cartas difuminan lo que esté
  /// debajo de ellas (no el fondo entero).
  final bool cardBlurEnabled;
  final double cardBlurIntensity;

  /// Ruido PROPIO de las tarjetas, independiente del global.
  final double cardNoiseIntensity;

  /// De dónde sale la lista de canciones (auto del sistema o carpeta
  /// manual elegida por el usuario).
  final LibrarySource librarySource;

  /// Ruta de la carpeta manual cuando [librarySource] es manualFolder.
  /// `null` significa "no elegida todavía".
  final String? manualFolderPath;

  /// Cookie completa de YouTube Music tras login. Formato:
  /// `name=value; name2=value2; ...`. `null` = sin sesión (modo invitado).
  final String? ytMusicCookie;
  /// `DATASYNC_ID` extraído del HTML de music.youtube.com — identifica al
  /// usuario logueado. Se envía como `context.user.onBehalfOfUser` en cada
  /// request. Sin esto, YT Music devuelve contenido genérico de visitante
  /// aunque la cookie sea válida.
  final String? ytMusicDataSyncId;

  /// `visitorData` extraído de la página de YouTube Music. Identifica al
  /// visitante para personalización; complementa la cookie.
  final String? ytMusicVisitorData;

  /// OAuth access token (Bearer) — alternativa robusta al login por
  /// cookies. Obtenido via Device Code Flow contra el client_id del
  /// YouTube TV. Cuando está presente y no expirado, el cliente HTTP lo
  /// prefiere sobre el SAPISIDHASH derivado de cookies.
  final String? ytMusicAccessToken;

  /// Refresh token OAuth — permite renovar [ytMusicAccessToken] sin
  /// re-login del usuario. Persiste mientras el usuario no quite el
  /// permiso desde su cuenta Google.
  final String? ytMusicRefreshToken;

  /// Epoch ms de expiración del access_token. Si el `now` está a menos
  /// de 60s del expiry, el cliente refresca via `YtOauthService.refresh`
  /// antes de hacer la request.
  final int? ytMusicAccessTokenExpiryEpochMs;

  UiSettings copyWith({
    CoverShape? coverShape,
    double? holoTiltIntensity,
    double? holoParallaxIntensity,
    double? playbackSpeed,
    double? playbackPitchSemitones,
    bool? lockPitchToSpeed,
    bool? bitPerfectModeEnabled,
    MediaQuality? audioQualityWifi,
    MediaQuality? audioQualityCellular,
    MediaQuality? videoQualityWifi,
    MediaQuality? videoQualityCellular,
    MediaQuality? downloadQuality,
    bool? downloadAsMp3,
    bool? autoplayRelated,
    bool? floatingMiniEnabled,
    bool? fadeOnPlayPauseEnabled,
    int? fadeDurationMs,
    BackgroundMode? backgroundMode,
    Color? solidBackgroundColor,
    String? backgroundImagePath,
    bool clearBackgroundImagePath = false,
    BackgroundImageTransform? backgroundImageTransform,
    double? backgroundOpacity,
    double? surfaceOpacity,
    bool? useAlbumArtAsBackground,
    bool? useAlbumColorAsSolid,
    bool? useAmbientVideoPalette,
    bool? useVideoBackgroundIfAvailable,
    bool? blurEnabled,
    double? blurIntensity,
    double? noiseIntensity,
    bool? useDynamicColorFromAlbumArt,
    Color? fallbackAccentColor,
    Color? fallbackOnAccentColor,
    Color? fallbackSecondaryColor,
    bool clearFallbackSecondaryColor = false,
    Color? backgroundImageAccentColor,
    double? spacingScale,
    double? cornerRadius,
    double? songTileMinWidth,
    PageTransitionStyle? transitionStyle,
    int? transitionDurationMs,
    AppThemeMode? themeMode,
    bool? parallaxEnabled,
    double? parallaxIntensity,
    double? gradientSpeed,
    BackgroundShader? backgroundShader,
    BackgroundPaletteMode? backgroundPaletteMode,
    bool? cardBlurEnabled,
    double? cardBlurIntensity,
    double? cardNoiseIntensity,
    LibrarySource? librarySource,
    String? manualFolderPath,
    bool clearManualFolderPath = false,
    String? ytMusicCookie,
    String? ytMusicVisitorData,
    String? ytMusicDataSyncId,
    String? ytMusicAccessToken,
    String? ytMusicRefreshToken,
    int? ytMusicAccessTokenExpiryEpochMs,
    bool clearYtMusicAuth = false,
  }) {
    return UiSettings(
      backgroundMode: backgroundMode ?? this.backgroundMode,
      coverShape: coverShape ?? this.coverShape,
      holoTiltIntensity: holoTiltIntensity ?? this.holoTiltIntensity,
      holoParallaxIntensity:
          holoParallaxIntensity ?? this.holoParallaxIntensity,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      playbackPitchSemitones:
          playbackPitchSemitones ?? this.playbackPitchSemitones,
      lockPitchToSpeed: lockPitchToSpeed ?? this.lockPitchToSpeed,
      bitPerfectModeEnabled:
          bitPerfectModeEnabled ?? this.bitPerfectModeEnabled,
      audioQualityWifi: audioQualityWifi ?? this.audioQualityWifi,
      audioQualityCellular:
          audioQualityCellular ?? this.audioQualityCellular,
      videoQualityWifi: videoQualityWifi ?? this.videoQualityWifi,
      videoQualityCellular:
          videoQualityCellular ?? this.videoQualityCellular,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      downloadAsMp3: downloadAsMp3 ?? this.downloadAsMp3,
      autoplayRelated: autoplayRelated ?? this.autoplayRelated,
      floatingMiniEnabled: floatingMiniEnabled ?? this.floatingMiniEnabled,
      fadeOnPlayPauseEnabled:
          fadeOnPlayPauseEnabled ?? this.fadeOnPlayPauseEnabled,
      fadeDurationMs: fadeDurationMs ?? this.fadeDurationMs,
      solidBackgroundColor: solidBackgroundColor ?? this.solidBackgroundColor,
      backgroundImagePath: clearBackgroundImagePath
          ? null
          : (backgroundImagePath ?? this.backgroundImagePath),
      backgroundImageTransform:
          backgroundImageTransform ?? this.backgroundImageTransform,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      surfaceOpacity: surfaceOpacity ?? this.surfaceOpacity,
      useAlbumArtAsBackground:
          useAlbumArtAsBackground ?? this.useAlbumArtAsBackground,
      useAlbumColorAsSolid:
          useAlbumColorAsSolid ?? this.useAlbumColorAsSolid,
      useAmbientVideoPalette:
          useAmbientVideoPalette ?? this.useAmbientVideoPalette,
      useVideoBackgroundIfAvailable: useVideoBackgroundIfAvailable ??
          this.useVideoBackgroundIfAvailable,
      blurEnabled: blurEnabled ?? this.blurEnabled,
      blurIntensity: blurIntensity ?? this.blurIntensity,
      noiseIntensity: noiseIntensity ?? this.noiseIntensity,
      useDynamicColorFromAlbumArt:
          useDynamicColorFromAlbumArt ?? this.useDynamicColorFromAlbumArt,
      fallbackAccentColor: fallbackAccentColor ?? this.fallbackAccentColor,
      fallbackOnAccentColor:
          fallbackOnAccentColor ?? this.fallbackOnAccentColor,
      fallbackSecondaryColor: clearFallbackSecondaryColor
          ? null
          : (fallbackSecondaryColor ?? this.fallbackSecondaryColor),
      // El acento extraído viaja atado a la imagen: quitar la imagen
      // también lo limpia (sino un fondo nuevo heredaría el tinte viejo).
      backgroundImageAccentColor: clearBackgroundImagePath
          ? null
          : (backgroundImageAccentColor ?? this.backgroundImageAccentColor),
      spacingScale: spacingScale ?? this.spacingScale,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      songTileMinWidth: songTileMinWidth ?? this.songTileMinWidth,
      transitionStyle: transitionStyle ?? this.transitionStyle,
      transitionDurationMs: transitionDurationMs ?? this.transitionDurationMs,
      themeMode: themeMode ?? this.themeMode,
      parallaxEnabled: parallaxEnabled ?? this.parallaxEnabled,
      parallaxIntensity: parallaxIntensity ?? this.parallaxIntensity,
      gradientSpeed: gradientSpeed ?? this.gradientSpeed,
      backgroundShader: backgroundShader ?? this.backgroundShader,
      backgroundPaletteMode:
          backgroundPaletteMode ?? this.backgroundPaletteMode,
      cardBlurEnabled: cardBlurEnabled ?? this.cardBlurEnabled,
      cardBlurIntensity: cardBlurIntensity ?? this.cardBlurIntensity,
      cardNoiseIntensity: cardNoiseIntensity ?? this.cardNoiseIntensity,
      librarySource: librarySource ?? this.librarySource,
      manualFolderPath: clearManualFolderPath
          ? null
          : (manualFolderPath ?? this.manualFolderPath),
      ytMusicCookie: clearYtMusicAuth
          ? null
          : (ytMusicCookie ?? this.ytMusicCookie),
      ytMusicVisitorData: clearYtMusicAuth
          ? null
          : (ytMusicVisitorData ?? this.ytMusicVisitorData),
      ytMusicDataSyncId: clearYtMusicAuth
          ? null
          : (ytMusicDataSyncId ?? this.ytMusicDataSyncId),
      ytMusicAccessToken: clearYtMusicAuth
          ? null
          : (ytMusicAccessToken ?? this.ytMusicAccessToken),
      ytMusicRefreshToken: clearYtMusicAuth
          ? null
          : (ytMusicRefreshToken ?? this.ytMusicRefreshToken),
      ytMusicAccessTokenExpiryEpochMs: clearYtMusicAuth
          ? null
          : (ytMusicAccessTokenExpiryEpochMs ??
              this.ytMusicAccessTokenExpiryEpochMs),
    );
  }

  String toJson() => jsonEncode({
        'coverShape': coverShape.name,
        'holoTiltIntensity': holoTiltIntensity,
        'holoParallaxIntensity': holoParallaxIntensity,
        'playbackSpeed': playbackSpeed,
        'playbackPitchSemitones': playbackPitchSemitones,
        'lockPitchToSpeed': lockPitchToSpeed,
        'bitPerfectModeEnabled': bitPerfectModeEnabled,
        'audioQualityWifi': audioQualityWifi.name,
        'audioQualityCellular': audioQualityCellular.name,
        'videoQualityWifi': videoQualityWifi.name,
        'videoQualityCellular': videoQualityCellular.name,
        'downloadQuality': downloadQuality.name,
        'downloadAsMp3': downloadAsMp3,
        'autoplayRelated': autoplayRelated,
        'floatingMiniEnabled': floatingMiniEnabled,
        'fadeOnPlayPauseEnabled': fadeOnPlayPauseEnabled,
        'fadeDurationMs': fadeDurationMs,
        'backgroundMode': backgroundMode.name,
        'solidBackgroundColor': solidBackgroundColor.toARGB32(),
        'backgroundImagePath': backgroundImagePath,
        'backgroundImageTransform': backgroundImageTransform.toMap(),
        'backgroundOpacity': backgroundOpacity,
        'surfaceOpacity': surfaceOpacity,
        'useAlbumArtAsBackground': useAlbumArtAsBackground,
        'useAlbumColorAsSolid': useAlbumColorAsSolid,
        'useAmbientVideoPalette': useAmbientVideoPalette,
        'useVideoBackgroundIfAvailable': useVideoBackgroundIfAvailable,
        'blurEnabled': blurEnabled,
        'blurIntensity': blurIntensity,
        'noiseIntensity': noiseIntensity,
        'useDynamicColorFromAlbumArt': useDynamicColorFromAlbumArt,
        'fallbackAccentColor': fallbackAccentColor.toARGB32(),
        'fallbackOnAccentColor': fallbackOnAccentColor.toARGB32(),
        'fallbackSecondaryColor': fallbackSecondaryColor?.toARGB32(),
        'backgroundImageAccentColor': backgroundImageAccentColor?.toARGB32(),
        'spacingScale': spacingScale,
        'cornerRadius': cornerRadius,
        'songTileMinWidth': songTileMinWidth,
        'transitionStyle': transitionStyle.name,
        'transitionDurationMs': transitionDurationMs,
        'themeMode': themeMode.name,
        'parallaxEnabled': parallaxEnabled,
        'parallaxIntensity': parallaxIntensity,
        'gradientSpeed': gradientSpeed,
        'backgroundShader': backgroundShader.name,
        'backgroundPaletteMode': backgroundPaletteMode.name,
        'cardBlurEnabled': cardBlurEnabled,
        'cardBlurIntensity': cardBlurIntensity,
        'cardNoiseIntensity': cardNoiseIntensity,
        'librarySource': librarySource.name,
        'manualFolderPath': manualFolderPath,
        'ytMusicCookie': ytMusicCookie,
        'ytMusicVisitorData': ytMusicVisitorData,
        'ytMusicDataSyncId': ytMusicDataSyncId,
        'ytMusicAccessToken': ytMusicAccessToken,
        'ytMusicRefreshToken': ytMusicRefreshToken,
        'ytMusicAccessTokenExpiryEpochMs':
            ytMusicAccessTokenExpiryEpochMs,
      });

  factory UiSettings.fromJson(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return UiSettings(
      coverShape: CoverShape.values.firstWhere(
        (e) => e.name == m['coverShape'],
        orElse: () => CoverShape.square,
      ),
      holoTiltIntensity:
          ((m['holoTiltIntensity'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
      holoParallaxIntensity:
          ((m['holoParallaxIntensity'] as num?)?.toDouble() ?? 1.0)
              .clamp(0.0, 1.0),
      playbackSpeed:
          ((m['playbackSpeed'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0),
      playbackPitchSemitones:
          ((m['playbackPitchSemitones'] as num?)?.toDouble() ?? 0.0)
              .clamp(-12.0, 12.0),
      lockPitchToSpeed: m['lockPitchToSpeed'] as bool? ?? false,
      bitPerfectModeEnabled: m['bitPerfectModeEnabled'] as bool? ?? false,
      audioQualityWifi: MediaQuality.values.firstWhere(
        (e) => e.name == m['audioQualityWifi'],
        orElse: () => MediaQuality.high,
      ),
      audioQualityCellular: MediaQuality.values.firstWhere(
        (e) => e.name == m['audioQualityCellular'],
        orElse: () => MediaQuality.medium,
      ),
      videoQualityWifi: MediaQuality.values.firstWhere(
        (e) => e.name == m['videoQualityWifi'],
        orElse: () => MediaQuality.high,
      ),
      videoQualityCellular: MediaQuality.values.firstWhere(
        (e) => e.name == m['videoQualityCellular'],
        orElse: () => MediaQuality.low,
      ),
      downloadQuality: MediaQuality.values.firstWhere(
        (e) => e.name == m['downloadQuality'],
        orElse: () => MediaQuality.high,
      ),
      downloadAsMp3: m['downloadAsMp3'] as bool? ?? true,
      autoplayRelated: m['autoplayRelated'] as bool? ?? true,
      floatingMiniEnabled: m['floatingMiniEnabled'] as bool? ?? false,
      fadeOnPlayPauseEnabled:
          m['fadeOnPlayPauseEnabled'] as bool? ?? false,
      fadeDurationMs: (m['fadeDurationMs'] as num?)?.toInt() ?? 350,
      backgroundMode: BackgroundMode.values.firstWhere(
        (e) => e.name == m['backgroundMode'],
        orElse: () => BackgroundMode.solidColor,
      ),
      solidBackgroundColor:
          Color((m['solidBackgroundColor'] as num?)?.toInt() ?? 0xFF101015),
      backgroundImagePath: m['backgroundImagePath'] as String?,
      backgroundImageTransform: BackgroundImageTransform.fromMap(
        (m['backgroundImageTransform'] as Map?)?.cast<String, dynamic>() ?? {},
      ),
      backgroundOpacity:
          (m['backgroundOpacity'] as num?)?.toDouble() ?? 1.0,
      surfaceOpacity: (m['surfaceOpacity'] as num?)?.toDouble() ?? 0.85,
      useAlbumArtAsBackground: m['useAlbumArtAsBackground'] as bool? ?? true,
      useAlbumColorAsSolid: m['useAlbumColorAsSolid'] as bool? ?? false,
      useAmbientVideoPalette: m['useAmbientVideoPalette'] as bool? ?? true,
      useVideoBackgroundIfAvailable:
          m['useVideoBackgroundIfAvailable'] as bool? ?? false,
      blurEnabled: m['blurEnabled'] as bool? ?? false,
      blurIntensity: (m['blurIntensity'] as num?)?.toDouble() ?? 18.0,
      noiseIntensity: (m['noiseIntensity'] as num?)?.toDouble() ?? 0.0,
      useDynamicColorFromAlbumArt:
          m['useDynamicColorFromAlbumArt'] as bool? ?? true,
      fallbackAccentColor:
          Color((m['fallbackAccentColor'] as num?)?.toInt() ?? 0xFF7C5CFF),
      fallbackOnAccentColor:
          Color((m['fallbackOnAccentColor'] as num?)?.toInt() ?? 0xFFFFFFFF),
      fallbackSecondaryColor: (m['fallbackSecondaryColor'] as num?) == null
          ? null
          : Color((m['fallbackSecondaryColor'] as num).toInt()),
      backgroundImageAccentColor:
          (m['backgroundImageAccentColor'] as num?) == null
              ? null
              : Color((m['backgroundImageAccentColor'] as num).toInt()),
      spacingScale: (m['spacingScale'] as num?)?.toDouble() ?? 1.0,
      cornerRadius: (m['cornerRadius'] as num?)?.toDouble() ?? 18.0,
      songTileMinWidth:
          (m['songTileMinWidth'] as num?)?.toDouble() ?? 360.0,
      transitionStyle: PageTransitionStyle.values.firstWhere(
        (e) => e.name == m['transitionStyle'],
        orElse: () => PageTransitionStyle.fadeThrough,
      ),
      transitionDurationMs: (m['transitionDurationMs'] as num?)?.toInt() ?? 320,
      themeMode: _parseThemeMode(m['themeMode'] as String?,
          legacyBrightness: m['brightness'] as String?),
      parallaxEnabled: m['parallaxEnabled'] as bool? ?? true,
      parallaxIntensity: (m['parallaxIntensity'] as num?)?.toDouble() ?? 0.5,
      gradientSpeed: (m['gradientSpeed'] as num?)?.toDouble() ?? 0.4,
      backgroundPaletteMode: BackgroundPaletteMode.values.firstWhere(
        (e) => e.name == m['backgroundPaletteMode'],
        orElse: () => BackgroundPaletteMode.vibrant,
      ),
      backgroundShader: BackgroundShader.values.firstWhere(
        (e) => e.name == m['backgroundShader'],
        orElse: () => BackgroundShader.aurora,
      ),
      cardBlurEnabled: m['cardBlurEnabled'] as bool? ?? true,
      cardBlurIntensity:
          (m['cardBlurIntensity'] as num?)?.toDouble() ?? 14.0,
      cardNoiseIntensity:
          (m['cardNoiseIntensity'] as num?)?.toDouble() ?? 0.0,
      librarySource: LibrarySource.values.firstWhere(
        (e) => e.name == m['librarySource'],
        orElse: () => LibrarySource.auto,
      ),
      manualFolderPath: m['manualFolderPath'] as String?,
      ytMusicCookie: m['ytMusicCookie'] as String?,
      ytMusicVisitorData: m['ytMusicVisitorData'] as String?,
      ytMusicDataSyncId: m['ytMusicDataSyncId'] as String?,
      ytMusicAccessToken: m['ytMusicAccessToken'] as String?,
      ytMusicRefreshToken: m['ytMusicRefreshToken'] as String?,
      ytMusicAccessTokenExpiryEpochMs:
          (m['ytMusicAccessTokenExpiryEpochMs'] as num?)?.toInt(),
    );
  }

  /// Parser tolerante de `themeMode`. Acepta:
  ///   - El nombre nuevo (`'light'`/`'dark'`/`'auto'`/`'system'`).
  ///   - El campo viejo `brightness` (`'light'`/`'dark'`) para migrar
  ///     instalaciones existentes sin perder la preferencia.
  static AppThemeMode _parseThemeMode(
    String? raw, {
    String? legacyBrightness,
  }) {
    if (raw != null) {
      for (final m in AppThemeMode.values) {
        if (m.name == raw) return m;
      }
    }
    if (legacyBrightness == 'light') return AppThemeMode.light;
    if (legacyBrightness == 'dark') return AppThemeMode.dark;
    return AppThemeMode.dark; // default
  }
}

class UiSettingsScope extends InheritedWidget {
  const UiSettingsScope({
    super.key,
    required this.settings,
    required super.child,
  });

  final UiSettings settings;

  static UiSettings of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<UiSettingsScope>()!.settings;
  }

  /// Variante null-safe — útil cuando el caller no garantiza que haya un
  /// ancestor `UiSettingsScope` en el árbol (ej: dentro del
  /// `transitionsBuilder` de un `PageRoute` que corre en el contexto
  /// del Overlay, no del scaffold).
  static UiSettings? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<UiSettingsScope>()
        ?.settings;
  }

  @override
  bool updateShouldNotify(UiSettingsScope oldWidget) =>
      oldWidget.settings != settings;
}
