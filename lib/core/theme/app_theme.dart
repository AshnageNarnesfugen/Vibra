import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../settings/ui_settings.dart';
import 'contrast.dart';
import 'palette_signal.dart';

/// Construye un [ThemeData] que **garantiza legibilidad** combinando:
///   1. Las preferencias del usuario ([UiSettings]) — modo, opacidades,
///      fuente del color, etc.
///   2. La paleta extraída de la portada actual ([AlbumPalette]) si la hay.
///   3. Un cálculo del color "efectivo" del fondo: el color que predomina
///      detrás del texto en lo que el usuario realmente está viendo.
///      Sobre ESE color computamos `onSurface`/`onAccent` con `ensureReadable`
///      hasta alcanzar contraste WCAG ≥ 7:1 — independientemente de que el
///      usuario haya elegido modo claro u oscuro.
class AppThemeBuilder {
  const AppThemeBuilder._();

  // ─────────── Memoización del ThemeData ───────────
  //
  // `_buildImpl` construye un ThemeData completo con ~30 sub-temas +
  // varios `ensureReadable` (loops de hasta 20 iteraciones). Es ~0.5-2ms
  // en hardware mid-range. El problema: durante el "ambient video" la
  // paleta cambia cada 250ms (4×/seg) → reconstruir todo el tema 4×/seg
  // come presupuesto de frame y produce jank en hardware débil.
  //
  // Cache LRU pequeño (4 entradas) con clave QUANTIZADA: las componentes
  // de color de la paleta se redondean a múltiplos de 6 (≈2.3% por canal,
  // imperceptible en el accent que pinta iconos/sliders). Durante el
  // tween del ambient, ticks consecutivos con deltas sub-quantum
  // reúsan el tema cacheado. El FONDO sigue tweeneando suave porque no
  // pasa por el tema — solo el accent "escalona" en pasos invisibles.
  static final _cache = <String, ThemeData>{};
  static const _cacheMax = 4;

  static int _q(double channel01) {
    // channel01 está en 0..1 (Color.r/g/b en Flutter moderno). A 0..255
    // quantizado a múltiplos de 6.
    final v = (channel01 * 255).round();
    return (v ~/ 6) * 6;
  }

  static String _key(UiSettings s, AlbumPalette? p, Brightness sb) {
    final pk = p == null
        ? 'none'
        : '${_q(p.dominant.r)},${_q(p.dominant.g)},${_q(p.dominant.b)}'
            '|${_q(p.accent.r)},${_q(p.accent.g)},${_q(p.accent.b)}'
            '|${p.isUserPick}';
    // `s.hashCode` por identidad: UiSettings es inmutable y solo se
    // recrea via copyWith cuando un setting cambia de verdad. No tiene
    // override de == así que identityHashCode lo distingue por instancia,
    // que es exactamente lo que queremos (mismo objeto = misma config).
    return '${identityHashCode(s)}|$pk|${sb.index}|$usePaletteFlag(s, p)';
  }

  static String usePaletteFlag(UiSettings s, AlbumPalette? p) =>
      (s.useDynamicColorFromAlbumArt && p != null) ? '1' : '0';

  static ThemeData build({
    required UiSettings settings,
    AlbumPalette? palette,
    required Brightness systemBrightness,
  }) {
    final key = _key(settings, palette, systemBrightness);
    final cached = _cache[key];
    if (cached != null) {
      // Touch: re-inserta para mantener orden de recencia (LRU simple).
      _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }
    final built = _buildImpl(
      settings: settings,
      palette: palette,
      systemBrightness: systemBrightness,
    );
    _cache[key] = built;
    if (_cache.length > _cacheMax) {
      // Evict el más viejo (primero insertado).
      _cache.remove(_cache.keys.first);
    }
    return built;
  }

  static ThemeData _buildImpl({
    required UiSettings settings,
    AlbumPalette? palette,
    required Brightness systemBrightness,
  }) {
    final usePalette =
        settings.useDynamicColorFromAlbumArt && palette != null;

    // Lógica de asignación de colores según brightness:
    // - Light Mode: primary = el MÁS BRILLANTE de la paleta; texto/secundario
    //   = el MÁS OSCURO. La idea: contra un fondo claro el texto oscuro lee
    //   bien y el accent vibrante destaca.
    // - Dark Mode: primary = el MÁS OSCURO; texto/secundario = el MÁS
    //   BRILLANTE. Invertido.
    //
    // El código viejo asumía que `palette.accent` es siempre el "vibrante"
    // y `palette.dominant` el "oscuro" — pero palette_generator no garantiza
    // ese orden, así que el theme salía inconsistente. Aquí lo computamos
    // explícito por luminancia.
    Color brightColor;
    Color darkColor;
    if (usePalette) {
      final domLum = palette.dominant.computeLuminance();
      final accLum = palette.accent.computeLuminance();
      if (domLum >= accLum) {
        brightColor = palette.dominant;
        darkColor = palette.accent;
      } else {
        brightColor = palette.accent;
        darkColor = palette.dominant;
      }
    } else {
      brightColor = settings.fallbackAccentColor;
      darkColor = settings.fallbackAccentColor;
    }

    // Color de fondo efectivo + su luminancia. Necesario para resolver
    // themeMode = auto (bg oscuro → dark, bg claro → light).
    final effectiveBg = _effectiveBackgroundColor(settings, palette);
    final effectiveLum = effectiveBg.computeLuminance();

    // Resolución del themeMode → Brightness:
    //   - light/dark: directo.
    //   - auto: desde la luminancia del bg efectivo.
    //   - system: desde MediaQuery.platformBrightness (pasado por app.dart).
    final userBrightness = settings.themeMode.resolve(
      systemBrightness: systemBrightness,
      bgLuminance: effectiveLum,
    );
    final isLight = userBrightness == Brightness.light;
    // Asignación del accent del scheme:
    //   - Paleta AUTOMÁTICA: heurística por luminancia (el más brillante
    //     en light mode, el más oscuro en dark mode) — palette_generator
    //     no garantiza roles consistentes y esto evita themes invertidos.
    //   - PICK MANUAL del usuario (isUserPick): los roles se respetan TAL
    //     CUAL. El usuario eligió "Acento" en el picker esperando que ESE
    //     color pinte iconos/sliders/highlights; la heurística lo anulaba
    //     según le conviniera al brightness y el slot parecía no hacer
    //     nada. Los guards de contraste (appBarIcon/onAccent vía
    //     ensureReadable) siguen aplicando, así que un pick de bajo
    //     contraste se corrige donde importa sin pisar la elección.
    final userPick = usePalette && palette.isUserPick;
    final Color accent =
        userPick ? palette.accent : (isLight ? brightColor : darkColor);
    // Hint para el color de texto — el opuesto de primary. ensureReadable
    // ajusta después para garantizar 7:1 si el contraste no alcanza.
    final Color textHint =
        userPick ? palette.dominant : (isLight ? darkColor : brightColor);

    // El brightness para SURFACES sale del FONDO REAL: cards de Material
    // necesitan saber si están sobre bg oscuro o claro para que
    // surfaceBase contraste. Esto es independiente de userBrightness — la
    // composición visual responde al bg real.
    final effectiveBrightness =
        effectiveLum > 0.45 ? Brightness.light : Brightness.dark;

    // Surface base: ligeramente diferente del fondo para que las cards se
    // distingan visualmente. Si el bg es oscuro, surface es un poco más
    // claro; si el bg es claro, surface es un poco más oscuro.
    final surfaceBase = effectiveBrightness == Brightness.dark
        ? Color.lerp(effectiveBg, Colors.white, 0.10)!
        : Color.lerp(effectiveBg, Colors.black, 0.06)!;

    // Composite que ve el usuario sobre las cards: surfaceBase con alpha
    // sobre el bg efectivo. Es el color real detrás del texto en cards.
    // Usamos `effectiveSurfaceOpacity` (surface × background) para que el
    // contraste del texto se calcule contra la opacidad REAL que ven las
    // cards, no solo el slider de surface aislado.
    final cardComposite = Color.alphaBlend(
      surfaceBase.withValues(alpha: settings.effectiveSurfaceOpacity),
      effectiveBg,
    );

    // Color de texto/iconos: SEMILLA = el textHint que sale de la paleta
    // (color opuesto al accent — oscuro en light mode, brillante en dark
    // mode). Si el contraste contra el composite no llega a 7:1,
    // `ensureReadable` lo empuja hacia blanco o negro según corresponda.
    // Sin esto el texto era siempre puro blanco o negro y se perdía el
    // tono de la paleta.
    final onSurface = ContrastUtils.ensureReadable(
      textHint,
      cardComposite,
      target: 7.0,
    );

    final onAccent = ContrastUtils.ensureReadable(
      ContrastUtils.onColorFor(accent),
      accent,
    );

    // Color seguro para iconos sobre el AppBar/scaffold. El AppBar es
    // transparente y va sobre el bg dinámico, así que `accent` directo
    // puede tener bajo contraste (album palette + bg = colores cercanos).
    // Usamos accent pero garantizamos 4.5:1 contra el bg efectivo, sino
    // empujamos hacia blanco/negro.
    final appBarIcon = ContrastUtils.ensureReadable(
      accent,
      effectiveBg,
      target: 4.5,
    );

    final scheme = ColorScheme(
      brightness: effectiveBrightness,
      primary: accent,
      onPrimary: onAccent,
      secondary: ContrastUtils.mix(accent, onSurface, 0.25),
      onSecondary: onAccent,
      tertiary: usePalette ? palette.dominant : settings.fallbackAccentColor,
      onTertiary: onAccent,
      error: const Color(0xFFFF5670),
      onError: const Color(0xFFFFFFFF),
      surface: surfaceBase,
      onSurface: onSurface,
      surfaceContainerHighest:
          ContrastUtils.mix(surfaceBase, onSurface, 0.08),
      outline: ContrastUtils.mix(surfaceBase, onSurface, 0.30),
      outlineVariant: ContrastUtils.mix(surfaceBase, onSurface, 0.18),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: onSurface,
      onInverseSurface: surfaceBase,
      inversePrimary:
          ContrastUtils.ensureReadable(accent, onSurface, target: 4.5),
    );

    final base = effectiveBrightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    final radius = settings.cornerRadius;
    final scaffoldBg = Colors.transparent;

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBg,
      canvasColor: Colors.transparent, // Transparencia global
      cardColor: Colors.transparent,   // Transparencia global
      // AppBar al estilo iOS: transparente, centrada, con título compacto.
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: appBarIcon, size: 22),
        actionsIconTheme: IconThemeData(color: appBarIcon, size: 22),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        },
      ),
      cardTheme: CardThemeData(
        // GlassCard ya gestiona alpha + blur — esto es el fallback de
        // Cards estándar de Material por si las usamos en algún sitio.
        color: surfaceBase
            .withValues(alpha: settings.effectiveSurfaceOpacity),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.2),
        trackHeight: 3,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(accent),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? accent.withValues(alpha: 0.45)
              : scheme.outlineVariant,
        ),
      ),
      iconTheme: IconThemeData(color: onSurface),
      listTileTheme: ListTileThemeData(
        iconColor: onSurface,
        textColor: onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.5,
        space: 1,
      ),
      // Look glass para los menús contextuales (PopupMenuButton de 3 puntos):
      // surface translúcida del tema, borde sutil del outlineVariant, esquinas
      // redondeadas y elevación moderada. Sin esto se veían como un Material
      // sólido genérico sin coherencia con el resto de la UI (glass cards).
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface.withValues(alpha: 0.92),
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
            width: 0.5,
          ),
        ),
        textStyle: TextStyle(
          color: onSurface,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        iconColor: onSurface,
      ),
      // Mismo tratamiento para Menu (M3 MenuAnchor / DropdownMenu).
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor:
              WidgetStatePropertyAll(scheme.surface.withValues(alpha: 0.92)),
          surfaceTintColor:
              const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(6),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.45),
                width: 0.5,
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: accent,
        unselectedItemColor: scheme.outline,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: 0.18),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(color: onSurface, fontWeight: FontWeight.w500),
        ),
        iconTheme: WidgetStatePropertyAll(IconThemeData(color: onSurface)),
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      // Tipografía SF-feeling con métricas afinadas.
      textTheme: base.textTheme
          .apply(bodyColor: onSurface, displayColor: onSurface)
          .copyWith(
            displayLarge: base.textTheme.displayLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.8,
            ),
            displayMedium: base.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
            displaySmall: base.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            headlineLarge: base.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
            headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
            titleSmall: base.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.05,
            ),
            bodyLarge: base.textTheme.bodyLarge?.copyWith(letterSpacing: 0),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(letterSpacing: 0),
            bodySmall: base.textTheme.bodySmall?.copyWith(letterSpacing: 0),
            labelLarge: base.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
      splashFactory: NoSplash.splashFactory,
      splashColor: accent.withValues(alpha: 0.08),
      highlightColor: accent.withValues(alpha: 0.04),
    );
  }

  /// Color "efectivo" del fondo: aquel contra el cual el texto debe contrastar.
  /// Cubre todos los modos:
  ///   - solid → el color elegido por el usuario.
  ///   - image → la dominante de la paleta de la portada (mejor estimación
  ///     que tenemos sin leer la imagen del usuario), o el color sólido de
  ///     fallback si no hay paleta.
  ///   - animatedGradient → la dominante de la portada. Los shaders palette-
  ///     aware mezclan acento/dominante/oscuro, así que la dominante es la
  ///     mejor estimación del color contra el que va el texto. Los shaders
  ///     con paleta fija (liquid) tienen tonos muy oscuros de base → mismo
  ///     comportamiento sirve.
  static Color _effectiveBackgroundColor(
    UiSettings settings,
    AlbumPalette? palette,
  ) {
    if (settings.backgroundMode == BackgroundMode.animatedGradient) {
      return palette?.dominant ?? settings.fallbackAccentColor;
    }
    if (settings.backgroundMode == BackgroundMode.image) {
      return palette?.dominant ?? settings.solidBackgroundColor;
    }
    // solidColor: si el usuario activó "permitir que la carátula se ponga
    // de fondo" Y hay palette, el bg real es el dominante del album → el
    // contraste de texto debe calcularse contra ese color, no contra el
    // solidBackgroundColor estático del setting.
    if (settings.useAlbumColorAsSolid && palette != null) {
      return palette.dominant;
    }
    return settings.solidBackgroundColor;
  }
}
