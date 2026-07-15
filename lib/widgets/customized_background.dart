import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_format.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/palette_signal.dart';
import '../services/adaptive_luminance_service.dart';
import '../services/blurred_background.dart';
import '../services/video_availability_controller.dart';
import 'adjustable_background_image.dart';
import 'music_video_background.dart';
import 'noise_painter.dart';
import 'shader_background.dart';
import '../core/dev_log.dart';

/// Capa visual aplicada DETRÁS de toda la app.
class CustomizedBackground extends StatelessWidget {
  const CustomizedBackground({
    super.key,
    required this.settings,
    required this.tintColor,
    required this.parallaxOffset,
    this.child,
  });

  /// Offset máximo en píxeles que la base puede desplazarse a cada lado.
  /// Público porque las cards (sampler painter) lo necesitan para sincronizar
  /// el muestreo con el desplazamiento real del bg.
  static const double kMaxParallaxPx = 36.0;

  /// Sobre-escala de la base para que el desplazamiento no muestre bordes.
  static const double kParallaxOverscale = 1.15;

  final UiSettings settings;
  final Color tintColor;
  final ValueListenable<Offset> parallaxOffset;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // Selectivo: solo nos rebuildeamos cuando cambian los campos que
    // efectivamente usamos. `context.watch` rebuildaba en cualquier
    // notificación interna del signal (incluyendo updates parciales
    // durante el render del blur), creando rebuilds redundantes.
    final artUrl = context.select<PaletteSignal, String?>(
      (s) => s.artworkUrl,
    );
    final artBytes = context.select<PaletteSignal, Uint8List?>(
      (s) => s.artworkBytes,
    );
    final palette = context.select<PaletteSignal, AlbumPalette?>(
      (s) => s.palette,
    );
    // Toggle del player "ver video en cover" — si está ON, también queremos
    // que el bg muestre el video para coherencia visual (no que el cover
    // tenga video y el fondo de toda la app sea la imagen estática).
    final showVideoCover = context.select<VideoAvailabilityController, bool>(
      (a) => a.showAsCover,
    );

    final hasArt = artBytes != null || artUrl != null;
    // El override de carátula como fondo SOLO aplica en modo `image`. Antes
    // la check era `mode != animatedGradient`, lo que dejaba pasar también
    // a `solidColor` — el usuario activaba el toggle en image, switcheaba
    // a solid color, y la carátula seguía pintándose en lugar del color
    // sólido elegido.
    final useAlbumArt = settings.backgroundMode == BackgroundMode.image &&
        settings.useAlbumArtAsBackground &&
        hasArt;

    // Alimentamos al BlurredBackgroundService cuando el frosted glass de
    // las tarjetas está activo. **Orden de prioridad de la fuente** (de más
    // específico a más genérico — coincide con lo que de hecho pinta el bg):
    //   1. Carátula del álbum si está activa (useAlbumArt + hasArt)
    //   2. Imagen elegida por el usuario (bg mode = image)
    //   3. URL remota de la carátula si tenemos solo url
    //   4. Sólido (color de fondo)
    //
    // Antes solo pasábamos `sourceBytes` cuando era album art — si el
    // usuario usaba su propia imagen, el service caía al solidColor y los
    // samplers de las cards veían un rect uniforme, no la imagen real.
    // Color sólido EFECTIVO del bg. Cuando `useAlbumColorAsSolid` está ON
    // y hay palette, el bg pinta `palette.dominant` en lugar del color del
    // picker. El sampler de las cards DEBE recibir el mismo color, sino
    // queda con el tono anterior aunque el bg ya cambió (las GlassCards
    // se ven moradas sobre un bg amarillo del album).
    final effectiveSolid =
        settings.backgroundMode == BackgroundMode.solidColor &&
                settings.useAlbumColorAsSolid &&
                palette != null
            ? palette.dominant
            : settings.solidBackgroundColor;

    // Actualizar el luminance map del bg: usado por `AdaptiveColor` widgets
    // para decidir tinta clara/oscura por región. Diferido con
    // `addPostFrameCallback` porque los `set*` notifican listeners y
    // hacerlo durante `build()` dispara "setState during build". El
    // dedupe interno del service evita loops infinitos.
    final lumService = context.read<AdaptiveLuminanceService>();
    final bytesForLum = useAlbumArt ? artBytes : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (bytesForLum != null && isDecodableImage(bytesForLum)) {
        lumService.scheduleFromBytes(bytesForLum);
      } else if (settings.backgroundMode == BackgroundMode.animatedGradient) {
        lumService
            .setGradient(_BaseLayer.computeGradientColors(settings, palette));
      } else if (settings.backgroundMode == BackgroundMode.solidColor) {
        final solid = settings.useAlbumColorAsSolid && palette != null
            ? palette.dominant
            : settings.solidBackgroundColor;
        lumService.setUniform(solid);
      } else {
        // image mode sin bytes válidos o cualquier otro caso → usamos el
        // dominante del album si lo hay, sino el solid color de fallback.
        lumService
            .setUniform(palette?.dominant ?? settings.solidBackgroundColor);
      }
    });

    final blurService = context.read<BlurredBackgroundService?>();
    final cardSigma = settings.cardBlurEnabled
        ? settings.cardBlurIntensity.clamp(0.0, 60.0)
        : 0.0;
    if (blurService != null && cardSigma > 0) {
      try {
        Uint8List? feedBytes;
        String? feedPath;
        String? feedUrl;
        List<Color>? feedGradient;
        if (useAlbumArt) {
          feedBytes = artBytes;
          feedUrl = artUrl;
        } else if (settings.backgroundMode == BackgroundMode.image &&
            settings.backgroundImagePath != null) {
          feedPath = settings.backgroundImagePath;
        } else if (settings.backgroundMode == BackgroundMode.animatedGradient) {
          // En modo gradiente animado no hay imagen real que samplear → si
          // pasamos solo solidColor, el sampler muestra un rect uniforme y
          // las cards parecen bloques planos (a veces blancos) sobre el bg
          // colorido. Le damos al service los colores del gradiente para
          // que la pre-imagen TENGA color y el sampler muestre frosted real.
          feedGradient = _BaseLayer.computeGradientColors(settings, palette);
        }
        blurService.schedule(
          sourceBytes: feedBytes,
          sourcePath: feedPath,
          sourceUrl: feedUrl,
          solidColor: effectiveSolid,
          gradientColors: feedGradient,
          sigma: cardSigma.toDouble(),
          targetSize: MediaQuery.sizeOf(context),
        );
      } catch (e) {
        devLog('blurService.schedule skipped: $e');
      }
    }

    // Base del Stack: el color que se ve cuando el bg de arriba es
    // semi-transparente (slider de "Opacidad del fondo" bajo). Respeta
    // el modo elegido por el usuario:
    //   - solidColor: el color del picker del usuario. Antes usábamos
    //     `palette?.dominant ?? fallback` aquí también → en modo sólido
    //     sin canción el bg al bajar opacidad iba al fallbackAccent
    //     (rojo/morado), NO al color sólido que el usuario eligió. Bug.
    //   - image/gradient: dominante del album si hay, sino fallback (el
    //     bg es dinámico, tiene sentido que la base también lo sea).
    final Color baseColor;
    switch (settings.backgroundMode) {
      case BackgroundMode.solidColor:
        baseColor = settings.useAlbumColorAsSolid && palette != null
            ? palette.dominant
            : settings.solidBackgroundColor;
      case BackgroundMode.image:
      case BackgroundMode.animatedGradient:
        baseColor = palette?.dominant ?? settings.fallbackAccentColor;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. BASE — color del tema (revelado cuando backgroundOpacity < 1).
        ColoredBox(color: baseColor),

        // 2. CAPA DE FONDO (Imagen / Gradiente / Solid)
        RepaintBoundary(
          child: _BaseLayer(
            useAlbumArt: useAlbumArt,
            albumArtBytes: artBytes,
            albumArtUrl: artUrl,
            settings: settings,
            palette: palette,
            videoBgActive: settings.useVideoBackgroundIfAvailable ||
                showVideoCover,
            parallaxOffset: parallaxOffset,
            maxPx: kMaxParallaxPx,
            overscale: kParallaxOverscale,
          ),
        ),

        // 3. Tinte de tema — wash de primary sobre el fondo para dar
        // coherencia visual con la portada.
        //
        // **Solo aplica cuando el fondo es DINÁMICO** (imagen/carátula/
        // gradient). En modo solidColor lo apagamos: si el usuario eligió
        // negro #101015 y la canción tiene un rosa fuerte, el tint del 10%
        // hacía parecer que el "fondo cambió a rosa con canción" — lo cual
        // contradice la idea de elegir un color sólido fijo. La paleta del
        // album sigue afectando acentos UI (iconos, textos, slider) pero no
        // sobreescribe el color de fondo elegido.
        if (settings.backgroundMode != BackgroundMode.solidColor)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tintColor
                          .withValues(alpha: 0.10 * settings.backgroundOpacity),
                      tintColor
                          .withValues(alpha: 0.04 * settings.backgroundOpacity),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // 4. Noise
        if (settings.noiseIntensity > 0)
          Positioned.fill(
            child: RepaintBoundary(
              child: Opacity(
                opacity: settings.backgroundOpacity,
                child: NoiseLayer(intensity: settings.noiseIntensity),
              ),
            ),
          ),

        // Contenido
        if (child != null)
          Positioned.fill(
            child: ParallaxScope(
              offset: parallaxOffset,
              overscale: kParallaxOverscale,
              maxPx: kMaxParallaxPx,
              child: child!,
            ),
          ),
      ],
    );
  }
}

class ParallaxScope extends InheritedWidget {
  const ParallaxScope({
    super.key,
    required this.offset,
    required this.overscale,
    required this.maxPx,
    required super.child,
  });

  final ValueListenable<Offset> offset;
  final double overscale;
  final double maxPx;

  static ParallaxScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ParallaxScope>();
  }

  @override
  bool updateShouldNotify(ParallaxScope oldWidget) =>
      oldWidget.offset != offset ||
      oldWidget.overscale != overscale ||
      oldWidget.maxPx != maxPx;
}

class _BaseLayer extends StatelessWidget {
  const _BaseLayer({
    required this.useAlbumArt,
    required this.albumArtBytes,
    this.albumArtUrl,
    required this.settings,
    this.palette,
    required this.videoBgActive,
    required this.parallaxOffset,
    required this.maxPx,
    required this.overscale,
  });

  final bool useAlbumArt;
  final Uint8List? albumArtBytes;
  final String? albumArtUrl;
  final UiSettings settings;
  final AlbumPalette? palette;
  /// `true` si el video debe verse de fondo: ya sea por el setting
  /// `useVideoBackgroundIfAvailable` o porque el usuario activó el toggle
  /// "video en cover" del player (en ese caso queremos coherencia visual).
  final bool videoBgActive;
  final ValueListenable<Offset> parallaxOffset;
  final double maxPx;
  final double overscale;

  /// Calcula los 3 colores que se pasan a los shaders palette-aware (aurora,
  /// plasma, mesh). El orden conceptual es [highlight, midtone, shadow] —
  /// los shaders los mezclan según su propia lógica.
  ///
  /// **Modos** ([BackgroundPaletteMode]):
  ///   - `vibrant` (default): prioriza los swatches saturados (la "vibra").
  ///     Resuelve el caso clásico donde un album con tonos cálidos vibrantes
  ///     se ve gris porque el `dominantColor` extraía el fondo ambiental.
  ///   - `twoColor`: dominant + accent + derivado. Look sobrio.
  ///   - `full`: 3 swatches MUY distintos para máxima variedad.
  ///   - `dominant`: legacy — dominante + accent + derivado oscuro.
  ///
  /// Público (estático) porque también lo necesita el `BlurredBackgroundService`
  /// para pre-renderizar un gradiente que el sampler de las cards muestre.
  static List<Color> computeGradientColors(UiSettings s, AlbumPalette? p) {
    if (p == null) {
      // Sin canción: acento del usuario + su secundario elegido. Si no
      // configuró secundario (null = automático), derivamos del acento
      // oscureciéndolo — el comportamiento histórico.
      final secondary = s.fallbackSecondaryColor;
      if (secondary != null) {
        final hslSec = HSLColor.fromColor(secondary);
        return [
          s.fallbackAccentColor,
          secondary,
          hslSec
              .withLightness((hslSec.lightness * 0.45).clamp(0.0, 1.0))
              .toColor(),
        ];
      }
      final hsl = HSLColor.fromColor(s.fallbackAccentColor);
      return [
        s.fallbackAccentColor,
        hsl.withLightness((hsl.lightness * 0.65).clamp(0.0, 1.0)).toColor(),
        hsl.withLightness((hsl.lightness * 0.30).clamp(0.0, 1.0)).toColor(),
      ];
    }
    Color darken(Color c, [double f = 0.4]) {
      final hsl = HSLColor.fromColor(c);
      return hsl.withLightness((hsl.lightness * f).clamp(0.0, 1.0)).toColor();
    }
    Color lighten(Color c, [double f = 1.4]) {
      final hsl = HSLColor.fromColor(c);
      return hsl.withLightness((hsl.lightness * f).clamp(0.0, 1.0)).toColor();
    }

    switch (s.backgroundPaletteMode) {
      case BackgroundPaletteMode.vibrant:
        // Prioriza saturado: vibrant > lightVibrant > darkVibrant. Solo cae
        // a accent/dominant cuando el album es completamente muted.
        final v = p.vibrant ?? p.accent;
        final lv = p.lightVibrant ?? lighten(v);
        final dv = p.darkVibrant ?? darken(v);
        return [lv, v, dv];
      case BackgroundPaletteMode.twoColor:
        return [p.accent, p.dominant, darken(p.dominant)];
      case BackgroundPaletteMode.full:
        // Tres swatches lo más diferentes posible entre sí — light, mid y
        // dark de familias distintas para máxima variedad cromática.
        final light = p.lightVibrant ?? p.lightMuted ?? lighten(p.accent);
        final mid = p.vibrant ?? p.accent;
        final dark = p.darkMuted ?? p.darkVibrant ?? darken(p.dominant);
        return [light, mid, dark];
      case BackgroundPaletteMode.dominant:
        // Legacy — dominante como base.
        return [p.accent, p.dominant, darken(p.dominant)];
    }
  }

  @override
  Widget build(BuildContext context) {
    // REVERSIÓN: No usamos pre-blur service. Pintamos directo.
    final Widget inner = _buildInner();

    return ValueListenableBuilder<Offset>(
      valueListenable: parallaxOffset,
      builder: (context, offset, innerChild) {
        final intensity = settings.parallaxIntensity.clamp(0.0, 1.0);
        final dx = offset.dx * maxPx * intensity;
        final dy = offset.dy * maxPx * intensity;
        return Transform.scale(
          scale: overscale,
          child: Transform.translate(
            offset: Offset(dx, dy),
            child: innerChild,
          ),
        );
      },
      child: SizedBox.expand(child: inner),
    );
  }

  Widget _buildInner() {
    Widget layer;
    Key key;

    if (settings.backgroundMode == BackgroundMode.animatedGradient) {
      key = ValueKey('shader-${settings.backgroundShader.name}');
      final colors = computeGradientColors(settings, palette);
      layer = ShaderBackground(
        shader: settings.backgroundShader,
        palette1: colors[0],
        palette2: colors[1],
        palette3: colors[2],
        speed: settings.gradientSpeed,
      );
    } else if (settings.backgroundMode == BackgroundMode.image &&
        videoBgActive) {
      // Video musical como fondo. Aplica si el modo es image Y:
      //   - el setting de video-en-bg está activo, O
      //   - el usuario activó el toggle "ver video" en el cover del player.
      // En el segundo caso es importante que el bg también muestre el video
      // — si no, queda raro que el cover tenga video pero el fondo siga
      // siendo la imagen estática.
      // El widget gestiona internamente la carga del video URL y cae a
      // SizedBox.shrink cuando no hay video → entonces este Stack también
      // muestra la imagen estática como fallback.
      key = const ValueKey('video-bg');
      layer = Stack(
        fit: StackFit.expand,
        children: [
          // Fallback que se ve si el video no carga o aún no inicializó.
          if (useAlbumArt)
            _AlbumArtLayer(bytes: albumArtBytes, url: albumArtUrl)
          else if (settings.backgroundImagePath != null)
            BackgroundImageView(
              path: settings.backgroundImagePath!,
              transform: settings.backgroundImageTransform,
              opacity: 1.0,
            )
          else
            ColoredBox(color: settings.solidBackgroundColor),
          const Positioned.fill(child: MusicVideoBackgroundLayer()),
        ],
      );
    } else if (useAlbumArt) {
      key = ValueKey('art-${albumArtBytes.hashCode}-${albumArtUrl.hashCode}');
      layer = _AlbumArtLayer(
        bytes: albumArtBytes,
        url: albumArtUrl,
      );
    } else if (settings.backgroundMode == BackgroundMode.image &&
        settings.backgroundImagePath != null) {
      key = ValueKey('user-${settings.backgroundImagePath}-'
          '${settings.backgroundImageTransform.scale}-'
          '${settings.backgroundImageTransform.offsetX}-'
          '${settings.backgroundImageTransform.offsetY}');
      layer = BackgroundImageView(
        path: settings.backgroundImagePath!,
        transform: settings.backgroundImageTransform,
        opacity: 1.0,
      );
    } else {
      // El usuario eligió color sólido. Si activó "permitir que la carátula
      // se ponga de fondo" Y hay palette → usamos el dominante del album
      // (sigue siendo un color plano, NO la imagen). Sin canción cae al
      // color elegido en el picker.
      final solidColor =
          settings.useAlbumColorAsSolid && palette != null
              ? palette!.dominant
              : settings.solidBackgroundColor;
      key = ValueKey('solid-${solidColor.toARGB32()}');
      layer = ColoredBox(color: solidColor);
    }

    // RepaintBoundary cachea el layer como textura propia → la
    // AnimatedSwitcher hace fade entre dos texturas pre-renderizadas
    // (cheap GPU composite), no entre dos árboles de widgets vivos.
    // Antes en cada cambio de modo bg el layer entrante tenía que
    // renderizarse de cero EN CADA FRAME del fade (decodificar la
    // imagen, recompilar el shader, etc.) → stutter visible.
    final boundedLayer = RepaintBoundary(child: layer);

    final switcher = AnimatedSwitcher(
      // Duración corta: el switch entre modos es discreto (el usuario
      // ya hizo tap), no necesita un crossfade largo. 200ms se siente
      // instantáneo pero suaviza el corte. Menos ms = menos tiempo
      // ejecutando 2 capas en paralelo = menos chance de frame drop.
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            ...previousChildren,
            ?currentChild,
          ],
        );
      },
      child: KeyedSubtree(key: key, child: boundedLayer),
    );

    // Blur APLICADO DESPUÉS del switcher: durante una transición ANTES,
    // ambas capas tenían su propio BackdropFilter → 2 blurs corriendo
    // en paralelo. Ahora se aplica una sola vez sobre el resultado
    // compuesto del fade → 1 blur. Cost reducido a la mitad durante
    // los cambios de modo bg (que es exactamente cuando se quejaba
    // el stuttering).
    Widget output = switcher;
    if (settings.blurEnabled && settings.blurIntensity > 0) {
      output = Stack(
        fit: StackFit.expand,
        children: [
          output,
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: settings.blurIntensity,
                sigmaY: settings.blurIntensity,
              ),
              child: const SizedBox.shrink(),
            ),
          ),
        ],
      );
    }

    final op = settings.backgroundOpacity.clamp(0.0, 1.0);
    if (op >= 0.999) return output;
    return Opacity(opacity: op, child: output);
  }
}

class _AlbumArtLayer extends StatelessWidget {
  const _AlbumArtLayer({this.bytes, this.url});
  final Uint8List? bytes;
  final String? url;

  @override
  Widget build(BuildContext context) {
    // Skip artwork inline en formato no decodificable (HEIC/AVIF). Si hay
    // url disponible, cae al Image.network; sino, placeholder negro.
    if (bytes != null && isDecodableImage(bytes!)) {
      return Image.memory(
        bytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12),
      );
    } else if (url != null) {
      // Background pasa por blur fuerte: 512px de resolución es de sobra y
      // recorta dramáticamente la RAM de decodificación de imágenes ≥1080p.
      return Image.network(
        url!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: 512,
        cacheHeight: 512,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12),
      );
    }
    return const ColoredBox(color: Colors.black12);
  }
}

// Eliminado _PreBlurredBgView ya que no usamos el pre-render service.
