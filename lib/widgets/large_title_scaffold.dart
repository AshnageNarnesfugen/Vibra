import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';

/// Scaffold con título grande iOS-style:
///   - Cuando estás arriba del scroll, el título se muestra en grande,
///     bold, alineado a la izquierda, debajo de la barra (estilo Settings/
///     Music app de iOS).
///   - Cuando haces scroll, el título grande se desvanece y aparece centrado
///     y compacto en la barra superior, con un divider hairline translúcido.
///
/// La barra superior queda translúcida con un blur leve (frosted glass) sobre
/// el background custom — eso aporta el "feel" iOS sin pelearse con la
/// personalización del usuario.
class LargeTitleScaffold extends StatelessWidget {
  const LargeTitleScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.bottomReserve = 0,
    this.onRefresh,
  });

  /// Helper para usos donde el contenido es un solo widget plano.
  factory LargeTitleScaffold.body({
    Key? key,
    required String title,
    required Widget body,
    List<Widget>? actions,
    double bottomReserve = 0,
  }) {
    return LargeTitleScaffold(
      key: key,
      title: title,
      actions: actions,
      bottomReserve: bottomReserve,
      slivers: [SliverToBoxAdapter(child: body)],
    );
  }

  final String title;
  final List<Widget> slivers;
  final List<Widget>? actions;

  /// Espacio reservado al final del scroll para que la última fila no quede
  /// pisada por la tab bar / mini-player flotantes.
  final double bottomReserve;

  /// Callback opcional para pull-to-refresh. Si no es null, el scroll view
  /// se envuelve con `RefreshIndicator` y el usuario puede arrastrar
  /// hacia abajo para recargar contenido. La función debe ser async y
  /// completarse cuando termine la recarga (el spinner se mantiene
  /// hasta que el Future se resuelve).
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    // El bottomReserve es para que la última fila no quede pisada por la tab
    // bar / mini-player flotantes. Sumamos los insets reales del sistema (en
    // landscape el home indicator desaparece, así que evitamos hueco extra).
    final viewBottom = MediaQuery.viewPaddingOf(context).bottom;

    final scroll = CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _LargeTitleDelegate(
            title: title,
            actions: actions,
            tokens: tokens,
            scheme: scheme,
            topPadding: MediaQuery.paddingOf(context).top,
          ),
        ),
        ...slivers,
        SliverToBoxAdapter(
          child: SizedBox(height: bottomReserve + viewBottom),
        ),
      ],
    );

    if (onRefresh == null) return scroll;
    // RefreshIndicator se monta SOLO si el caller pasa onRefresh. Así el
    // gesto pull-to-refresh queda opt-in (no todas las pantallas tienen
    // contenido refrescable) y no agregamos overhead innecesario.
    return RefreshIndicator(
      onRefresh: onRefresh!,
      color: scheme.primary,
      backgroundColor: scheme.surface,
      // Offset del spinner respecto al edge superior: el LargeTitle
      // header ocupa la franja de arriba, así que empujamos el spinner
      // un poco más abajo para que NO quede tapado por el title cuando
      // aparece.
      displacement: MediaQuery.paddingOf(context).top + 24,
      child: scroll,
    );
  }
}

class _LargeTitleDelegate extends SliverPersistentHeaderDelegate {
  _LargeTitleDelegate({
    required this.title,
    required this.actions,
    required this.tokens,
    required this.scheme,
    required this.topPadding,
  });

  final String title;
  final List<Widget>? actions;
  final LayoutTokens tokens;
  final ColorScheme scheme;
  final double topPadding;

  static const double _compactBarHeight = 44.0;
  static const double _largeTitleHeight = 56.0;

  @override
  double get minExtent => topPadding + _compactBarHeight;
  @override
  double get maxExtent => topPadding + _compactBarHeight + _largeTitleHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final settings = UiSettingsScope.of(context);
    // 0 = expandido (título grande), 1 = colapsado (solo barra compacta).
    final t = (shrinkOffset / _largeTitleHeight).clamp(0.0, 1.0);
    final largeOpacity = (1 - t * 1.2).clamp(0.0, 1.0);
    final smallOpacity = ((t - 0.4) * 2).clamp(0.0, 1.0);

    return ClipRect(
      child: Stack(
        children: [
          // Capa base de "material": oscurece el bg antes del blur para dar
          // cuerpo al cristal en fondos claros u oscuros.
          //
          // **Por qué BackdropFilter y no FrostedSurface (sampler)**: la barra
          // pinned blurea el CONTENIDO scrolleando bajo ella (el feel iOS
          // auténtico). El sampler solo blurea el bg pre-renderado y no ve
          // los items scrolleando.
          Positioned.fill(
            child: Opacity(
              opacity: t,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
            ),
          ),
          // Frosted glass: blur del fondo Y de los elementos bajo la barra.
          Positioned.fill(
            child: Opacity(
              opacity: t,
              child: BackdropFilter(
                // Sigma 32 → difuminado ultra-suave tipo Apple.
                filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(
                      // Opacidad base alta para que el cristal se vea denso.
                      alpha: (0.65 + settings.effectiveSurfaceOpacity * 0.25)
                          .clamp(0.0, 1.0),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.06),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.03),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Hairline divider iOS.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Opacity(
              opacity: t,
              child: Container(
                height: 0.5,
                color: scheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
          ),
          // Layout interno.
          Padding(
            padding: EdgeInsets.only(top: topPadding),
            child: Column(
              children: [
                SizedBox(
                  height: _compactBarHeight,
                  child: Builder(builder: (context) {
                    // En landscape mostramos el hamburger SI el Scaffold
                    // padre tiene drawer. Antes usábamos solo
                    // `Scaffold.hasDrawer` pero ese flag a veces seguía
                    // verdadero durante una rotación → el hamburger
                    // asomaba en portrait también. Combinarlo con la
                    // orientación elimina ese falso positivo.
                    final isLandscape =
                        MediaQuery.orientationOf(context) ==
                            Orientation.landscape;
                    final hasDrawer =
                        Scaffold.maybeOf(context)?.hasDrawer ?? false;
                    final showMenuButton = isLandscape && hasDrawer;
                    return Stack(
                      children: [
                        if (showMenuButton)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: IconButton(
                                icon: const Icon(Icons.menu_rounded),
                                tooltip: 'Abrir menú',
                                onPressed: () =>
                                    Scaffold.of(context).openDrawer(),
                              ),
                            ),
                          ),
                        // Título compacto: Alineado a la IZQUIERDA para
                        // consistencia con el título grande y evitar
                        // colisión con el menú de la derecha.
                        Positioned(
                          left: showMenuButton ? 56 : tokens.space(20),
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: Opacity(
                              opacity: smallOpacity,
                              child: Text(
                                title,
                                style: Theme.of(context)
                                    .appBarTheme
                                    .titleTextStyle,
                              ),
                            ),
                          ),
                        ),
                        // ACCIONES: Ancladas a la derecha
                        if (actions != null && actions!.isNotEmpty)
                          Positioned(
                            right: 8,
                            top: 0,
                            bottom: 0,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: actions!,
                            ),
                          ),
                      ],
                    );
                  }),
                ),
                SizedBox(
                  height: _largeTitleHeight * (1 - t),
                  child: ClipRect(
                    child: OverflowBox(
                      maxHeight: _largeTitleHeight,
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: tokens.space(20),
                          right: tokens.space(20),
                          bottom: 8,
                        ),
                        child: Opacity(
                          opacity: largeOpacity,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              title,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineLarge
                                  ?.copyWith(fontSize: 34),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _LargeTitleDelegate old) =>
      old.title != title ||
      old.topPadding != topPadding ||
      old.scheme != scheme;
}
