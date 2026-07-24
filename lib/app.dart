import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/animations/parallax_controller.dart';
import 'core/settings/settings_controller.dart';
import 'core/settings/ui_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/layout_tokens.dart';
import 'core/theme/palette_signal.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'widgets/customized_background.dart';

/// Composición raíz.
///
/// **Importante para el bg**: `CustomizedBackground` vive en un `Stack`
/// COMO HERMANO (no como child) del `MaterialApp`. Antes lo teníamos dentro
/// del `MaterialApp.builder`, lo cual hacía que el Navigator lo recreara
/// EN CADA RUTA (push de sub-pantalla = nueva instancia del bg = nuevo
/// schedule del blur pre-render + nuevo subscriber a PaletteSignal). Eso
/// causaba el "sticky": durante la transición de navegación se veía la
/// cache vieja porque la nueva instancia tardaba ~80ms en debouncear y
/// otros ms en pre-rendear.
///
/// Ahora el bg es UNA sola instancia detrás del Navigator. Todas las rutas
/// (incluidas sub-pantallas de ajustes con sus Scaffolds transparentes)
/// comparten el mismo bg que se actualiza una sola vez cuando cambia la
/// canción o los settings.
class VibraApp extends StatelessWidget {
  const VibraApp({super.key, this.showOnboarding = false});

  /// Primer arranque → la ruta inicial es el onboarding (3 páginas).
  /// El flag lo lee main() de prefs antes de runApp; al terminar el
  /// onboarding se persiste y navega a HomeScreen con pushReplacement.
  final bool showOnboarding;

  /// Último brightness empujado al SO. Evita spam del platform channel
  /// `setSystemUIOverlayStyle` en rebuilds donde el brightness no cambió.
  static Brightness? _lastOverlayBrightness;

  @override
  Widget build(BuildContext context) {
    final settings =
        context.select<SettingsController, UiSettings>((c) => c.value);
    final palette =
        context.select<PaletteSignal, AlbumPalette?>((s) => s.palette);

    final parallax = context.read<ParallaxController>();
    parallax.setEnabled(settings.parallaxEnabled);

    // Resuelve la Brightness efectiva — themeMode puede ser auto/system, así
    // que necesitamos la platformBrightness y la luminancia del bg actual.
    // El theme builder ya hace su propia resolución, pero la pasamos al
    // status bar también para que el ícono color sea consistente.
    final systemBrightness = MediaQuery.platformBrightnessOf(context);
    final effectiveBrightness = settings.themeMode.resolve(
      systemBrightness: systemBrightness,
      bgLuminance: palette?.dominant.computeLuminance(),
    );

    final theme = AppThemeBuilder.build(
      settings: settings,
      palette: palette,
      systemBrightness: systemBrightness,
    );

    // Solo empujamos el overlay style al SO cuando el brightness EFECTIVO
    // cambia. Antes se llamaba en cada build → durante el ambient video
    // (rebuild 4×/seg) era spam al platform channel sin que el valor
    // cambiara. El brightness solo cambia al alternar tema o cuando el bg
    // cruza el umbral claro/oscuro, no por cada tick de color.
    if (effectiveBrightness != _lastOverlayBrightness) {
      _lastOverlayBrightness = effectiveBrightness;
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: effectiveBrightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: effectiveBrightness,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness:
              effectiveBrightness == Brightness.dark
                  ? Brightness.light
                  : Brightness.dark,
        ),
      );
    }

    // BG sibling del MaterialApp: única instancia compartida por TODAS las
    // rutas. El `Directionality` envolvente es necesario porque el bg pinta
    // texto/iconos eventualmente y MaterialApp no nos lo está pasando aquí.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // Capa 1: BG full-screen, ÚNICA INSTANCIA.
          Positioned.fill(
            child: LayoutTokensScope(
              tokens: LayoutTokens.fromSettings(settings),
              child: UiSettingsScope(
                settings: settings,
                child: Theme(
                  data: theme,
                  child: CustomizedBackground(
                    settings: settings,
                    tintColor: theme.colorScheme.primary,
                    parallaxOffset: parallax.offset,
                    child: const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
          // Capa 2: MaterialApp + Navigator + rutas. Los scaffolds son
          // transparentes así el bg de abajo se ve.
          Positioned.fill(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'Vibra',
              theme: theme,
              darkTheme: theme,
              themeMode: effectiveBrightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              builder: (context, child) {
                // Los Scopes se replican aquí porque las rutas dentro del
                // MaterialApp viven en su propio sub-árbol — no heredan los
                // del Stack sibling. Es cheap (StatelessWidgets que solo
                // propagan una referencia inmutable).
                return AnnotatedRegion<SystemUiOverlayStyle>(
                  value: SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: Colors.transparent,
                    statusBarIconBrightness:
                        effectiveBrightness == Brightness.dark
                            ? Brightness.light
                            : Brightness.dark,
                  ),
                  child: LayoutTokensScope(
                    tokens: LayoutTokens.fromSettings(settings),
                    child: UiSettingsScope(
                      settings: settings,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
              },
              home: showOnboarding
                  ? const OnboardingScreen()
                  : const HomeScreen(),
            ),
          ),
        ],
      ),
    );
  }
}
