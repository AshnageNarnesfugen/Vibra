import 'package:flutter/material.dart';

import '../settings/ui_settings.dart';

/// Construye un [PageRoute] aplicando la animación elegida en los ajustes.
///
/// Esta es la única ruta-builder que el resto de la app debe usar al hacer
/// `Navigator.push`. Eso garantiza que el slider de "estilo de transición" en
/// ajustes tenga efecto inmediato sobre toda la navegación.
class CustomPageRoute<T> extends PageRouteBuilder<T> {
  /// El `style` y `duration` que se pasan acá son SOLO el snapshot del
  /// momento del push — la duración real de la animación se fija acá
  /// (el animation controller del PageRoute lee `transitionDuration`
  /// una vez al inicializarse).
  ///
  /// PERO el `style` se vuelve a leer en cada frame del `transitionsBuilder`
  /// desde `UiSettingsScope.maybeOf(context)`. Eso resuelve el bug que el
  /// usuario reportó: cambiabas el estilo en ajustes y al hacer pop de
  /// vuelta a Settings, la animación de salida usaba el viejo estilo
  /// porque era el que se había capturado al push. Ahora cualquier cambio
  /// del setting aplica YA al pop pendiente y a todos los pushes futuros.
  CustomPageRoute({
    required Widget page,
    required PageTransitionStyle style,
    Duration duration = const Duration(milliseconds: 320),
    super.settings,
  }) : super(
          pageBuilder: (_, _, _) => page,
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            // Si la app tiene `UiSettingsScope` en el árbol (siempre debería
            // en runtime — está en el root), leemos el estilo en vivo. Si
            // por algún motivo no hay scope (test, primer frame de un
            // overlay fuera del MaterialApp), caemos al `style` capturado.
            final live = UiSettingsScope.maybeOf(context);
            final effectiveStyle = live?.transitionStyle ?? style;
            return _build(
                effectiveStyle, animation, secondaryAnimation, child);
          },
        );

  /// **Por qué tratamos también la saliente (`sa` = secondaryAnimation)**:
  ///
  /// Antes solo aplicábamos transformación a la pantalla ENTRANTE (`a`).
  /// La pantalla SALIENTE se quedaba 100% visible debajo. Como casi todas
  /// nuestras pantallas tienen `backgroundColor: Colors.transparent` para
  /// que el bg blureado del player se vea consistente entre vistas, ese
  /// "stack" de dos screens transparentes producía el efecto reportado
  /// como "superpuesto": durante la transición se veían dos UIs a la vez.
  ///
  /// Ahora cada estilo aplica simétria: la entrante hace su gesto, la
  /// saliente hace el espejo (slide en dirección opuesta + fade out)
  /// para "ceder el escenario". Solo `none` y `fade` se mantienen
  /// asimétricos a propósito — `none` es por config y `fade` es cross-fade
  /// estándar donde la saliente ya pierde opacidad implícitamente.
  /// Por qué el fade out es AGRESIVO en la primera mitad del intervalo:
  ///
  /// Vibra usa `backgroundColor: Colors.transparent` en casi todas las
  /// pantallas (settings, player, etc.) para mantener consistente el bg
  /// blureado de la carátula. Si las dos pantallas (saliente y entrante)
  /// fade simétricamente con la misma curva, durante todo el rango
  /// 0..1 hay AMBAS visibles a opacidad parcial → se ve como "dos UIs
  /// stackeadas semitransparentes". Eso es lo que un beta tester
  /// reportó como "superpuesto".
  ///
  /// Solución: la saliente fade out en el intervalo `[0, 0.45]` (rápido
  /// al inicio), la entrante fade in en `[0.4, 1.0]`. El solapamiento
  /// ocurre solo en `[0.4, 0.45]` (~5% del tiempo) y en ese punto el bg
  /// blureado consistente se ve mientras ambas están casi invisibles.
  /// Resultado: la entrante "reemplaza" claramente a la saliente sin
  /// momento ambiguo de doble UI.
  static Widget _build(
    PageTransitionStyle style,
    Animation<double> a,
    Animation<double> sa,
    Widget child,
  ) {
    final curvedIn =
        CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
    final curvedOut =
        CurvedAnimation(parent: sa, curve: Curves.easeInCubic);
    // Fades con intervalo: la saliente desaparece RÁPIDO al inicio,
    // la entrante aparece DESPUÉS. Cero solape visual significativo.
    final fadeInLate = CurvedAnimation(
      parent: a,
      curve: const Interval(0.40, 1.0, curve: Curves.easeOut),
    );
    final fadeOutEarly = CurvedAnimation(
      parent: sa,
      curve: const Interval(0.0, 0.45, curve: Curves.easeIn),
    );

    Widget withFades(Widget c) {
      // Aplica el patrón "fade out rápido + fade in tardío" a cualquier
      // child. Centralizado así cualquier ajuste futuro al timing va
      // en un solo lugar.
      return FadeTransition(
        opacity: fadeInLate,
        child: FadeTransition(
          opacity: ReverseAnimation(fadeOutEarly),
          child: c,
        ),
      );
    }

    switch (style) {
      case PageTransitionStyle.none:
        return child;
      case PageTransitionStyle.fade:
        return withFades(child);
      case PageTransitionStyle.slideUp:
        return SlideTransition(
          position: Tween(begin: const Offset(0, 0.10), end: Offset.zero)
              .animate(curvedIn),
          child: SlideTransition(
            // Saliente se va hacia ARRIBA (sale por el "techo" del viewport).
            position: Tween(begin: Offset.zero, end: const Offset(0, -0.10))
                .animate(curvedOut),
            child: withFades(child),
          ),
        );
      case PageTransitionStyle.slideRight:
        return SlideTransition(
          // 30% del ancho en lugar de 18% — más distancia para que el
          // movimiento "tape" el solape de opacidad visualmente.
          position: Tween(begin: const Offset(0.30, 0), end: Offset.zero)
              .animate(curvedIn),
          child: SlideTransition(
            position: Tween(begin: Offset.zero, end: const Offset(-0.30, 0))
                .animate(curvedOut),
            child: withFades(child),
          ),
        );
      case PageTransitionStyle.scale:
        return ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curvedIn),
          child: ScaleTransition(
            // Saliente se reduce levemente y se aleja.
            scale: Tween(begin: 1.0, end: 0.94).animate(curvedOut),
            child: withFades(child),
          ),
        );
      case PageTransitionStyle.fadeThrough:
        // Material 3 fade through clásico — ya tenía este patrón antes
        // del refactor. Aquí simplemente reusamos `withFades`.
        return ScaleTransition(
          scale: Tween(begin: 0.97, end: 1.0).animate(curvedIn),
          child: withFades(child),
        );
      case PageTransitionStyle.sharedAxisHorizontal:
        return SlideTransition(
          position: Tween(begin: const Offset(0.30, 0), end: Offset.zero)
              .animate(curvedIn),
          child: SlideTransition(
            position: Tween(begin: Offset.zero, end: const Offset(-0.30, 0))
                .animate(curvedOut),
            child: withFades(child),
          ),
        );
    }
  }
}

extension NavigatorXCustom on NavigatorState {
  Future<T?> pushAnimated<T>(
    Widget page, {
    required PageTransitionStyle style,
    int durationMs = 320,
    String? routeName,
  }) {
    return push(
      CustomPageRoute<T>(
        page: page,
        style: style,
        duration: Duration(milliseconds: durationMs),
        settings: routeName != null ? RouteSettings(name: routeName) : null,
      ),
    );
  }

  /// Abre `page` con [routeName]; si ya existe una ruta con ese nombre en
  /// el stack, hace `popUntil` hasta ella en lugar de stackear otra copia.
  /// Sin esto, tap rápido en varias canciones apila múltiples PlayerScreens
  /// → "duplicación" del play now (necesitas back varias veces para salir).
  Future<T?> pushOrFocusNamed<T>(
    Widget page, {
    required String routeName,
    required PageTransitionStyle style,
    int durationMs = 320,
  }) {
    // Si la ruta con ese nombre ya está en el stack, pop hasta ella.
    var found = false;
    popUntil((route) {
      if (route.settings.name == routeName) {
        found = true;
        return true;
      }
      return route.isFirst;
    });
    if (found) return Future<T?>.value(null);
    return pushAnimated<T>(
      page,
      style: style,
      durationMs: durationMs,
      routeName: routeName,
    );
  }
}

/// Nombre canónico de la ruta del PlayerScreen — único punto de verdad para
/// el sistema de dedup. Usado por todos los call sites que abren el player.
const String kPlayerRouteName = '/player';
