import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';
import '../widgets/adaptive_color.dart';
import '../widgets/mini_player.dart';
import 'library_screen.dart';
import 'settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Registro global de los nested navigators de [HomeScreen]. Permite que
/// rutas fullscreen (como PlayerScreen, en root navigator) puedan pushear
/// en la tab activa sin perder la barra inferior — el patrón "abrir artista
/// desde el reproductor" debe cerrar el player y abrir el artista DENTRO de
/// la tab para que las tabs y mini-player sigan visibles.
class TabNavigation {
  TabNavigation._();

  /// Keys de los navigators anidados (uno por tab que los tiene). Tab 2
  /// (Settings) no tiene navigator anidado → no aparece aquí.
  static final List<GlobalKey<NavigatorState>> tabNavKeys = [
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];

  /// Índice de la tab actualmente visible. HomeScreen lo mantiene al día.
  static int activeIndex = 0;

  /// Callback registrado por [HomeScreen] para forzar un cambio de tab.
  /// Se usa cuando [pushInActiveTab] cae desde una tab sin nested
  /// navigator (Settings) y necesita saltar a una tab con navigator
  /// anidado — sin esto el push quedaría invisible debajo de la tab
  /// actualmente seleccionada y el usuario tendría que cambiar a mano.
  static void Function(int targetIndex)? onSwitchTab;

  /// Pushea `page` en el navigator anidado de la tab activa. Si la tab activa
  /// no tiene nested navigator (caso Settings, índice 2), salta a la tab de
  /// Biblioteca (índice 1) Y dispara el switch visual via [onSwitchTab]
  /// para que el usuario vea inmediatamente la ruta nueva.
  ///
  /// **Para usar desde rutas fullscreen** (root navigator), el caller debe
  /// pop-arse a sí mismo ANTES de llamar, o el push quedará detrás de la
  /// ruta fullscreen y no se verá.
  ///
  /// **Bug histórico:** antes solo hacía `clamp` del índice → si estabas
  /// en Settings (2) clampeaba a 1 y empujaba al Library nav, pero la tab
  /// visible seguía siendo Settings. La ruta quedaba apilada invisible. Al
  /// intentar de nuevo, otro push apilaba más rutas escondidas → 2 backs
  /// para volver al root de Library. Con el `onSwitchTab` el cambio de
  /// tab y el push pasan en el mismo frame, la ruta nueva se ve al toque.
  ///
  /// Usa [CustomPageRoute] (no [MaterialPageRoute]) para que la transición
  /// respete el estilo elegido por el usuario en ajustes Y aplique el
  /// fade out simétrico de la pantalla saliente — sin esto, dos
  /// pantallas con `backgroundColor: transparent` se ven "superpuestas"
  /// durante la animación.
  static Future<T?> pushInActiveTab<T>(
    Widget page, {
    PageTransitionStyle style = PageTransitionStyle.slideRight,
    int durationMs = 320,
  }) {
    var idx = activeIndex;
    if (idx >= tabNavKeys.length) {
      // Tab actual no tiene nested navigator (Settings). Caemos a
      // Biblioteca y pedimos a HomeScreen que cambie la tab visible
      // antes del push.
      idx = 1;
      onSwitchTab?.call(idx);
    }
    final nav = tabNavKeys[idx].currentState;
    if (nav == null) return Future<T?>.value(null);
    return nav.push<T>(CustomPageRoute<T>(
      page: page,
      style: style,
      duration: Duration(milliseconds: durationMs),
    ));
  }
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  // Un Navigator ANIDADO por tab. Al pushear álbumes/artistas/etc. desde
  // dentro de una tab, las nuevas rutas viven en SU navegador local — la
  // barra inferior (que vive FUERA del IndexedStack) se queda visible. Para
  // ir a una pantalla fullscreen (Player, sub-ajustes, Login) hay que usar
  // `Navigator.of(context, rootNavigator: true).push(...)`.
  //
  // Settings NO usa nested navigator: sus sub-pantallas se pushean directo en
  // root para ocupar toda la pantalla.
  final List<GlobalKey<NavigatorState>> _tabNavKeys = TabNavigation.tabNavKeys;

  @override
  void initState() {
    super.initState();
    // Registro del switch-tab callback que TabNavigation.pushInActiveTab
    // dispara cuando el push viene desde Settings (sin nested navigator).
    // Esto resuelve el bug en que pusheabas un Artist desde Settings y
    // quedaba apilado invisible en el nav de Library.
    TabNavigation.onSwitchTab = (i) {
      if (!mounted) return;
      if (_index == i) return;
      setState(() {
        _index = i;
        TabNavigation.activeIndex = i;
      });
    };
  }

  @override
  void dispose() {
    TabNavigation.onSwitchTab = null;
    super.dispose();
  }

  /// Intercepta el back de Android: si la tab activa tiene rutas pusheadas
  /// (Album, Artist, etc.), pop esa tab primero en lugar de cerrar la app.
  Future<bool> _handlePop() async {
    if (_index < _tabNavKeys.length) {
      final nav = _tabNavKeys[_index].currentState;
      if (nav != null && nav.canPop()) {
        nav.pop();
        return false; // ya consumimos el back
      }
    }
    return true; // dejar que el root navigator lo maneje
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final allowRootPop = await _handlePop();
        if (allowRootPop && mounted) {
          // Si el nested navigator no tenía nada que popear, dejamos al
          // sistema cerrar la actividad (comportamiento estándar de Android).
          SystemNavigator.pop();
        }
      },
      child: Builder(builder: (context) {
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        // En landscape el bottom NavigationBar se reemplaza por un Drawer
        // lateral con el mismo set de destinations. El MiniPlayer se
        // queda abajo full-width para maximizar el espacio vertical (la
        // barra de tabs tomaba ~80px que no son necesarios cuando ya
        // tenemos un drawer).
        return Scaffold(
          backgroundColor: Colors.transparent,
          drawer: isLandscape
              ? _SideMenuDrawer(
                  index: _index,
                  onSelect: (i) {
                    if (i == _index && i < _tabNavKeys.length) {
                      _tabNavKeys[i]
                          .currentState
                          ?.popUntil((r) => r.isFirst);
                      return;
                    }
                    setState(() {
                      _index = i;
                      TabNavigation.activeIndex = i;
                    });
                  },
                )
              : null,
          body: Stack(
            children: [
              // 1. Cuerpo: IndexedStack con 3 ramas. Las 2 primeras tienen
              // su propio Navigator anidado → álbumes/artistas pusheados
              // dentro se pintan sobre la barra inferior.
              Positioned.fill(
                child: IndexedStack(
                  index: _index,
                  children: [
                    _TabNavigator(
                      navigatorKey: _tabNavKeys[0],
                      initial: const LibraryScreen(showOnlyHome: true),
                    ),
                    _TabNavigator(
                      navigatorKey: _tabNavKeys[1],
                      initial: const LibraryScreen(),
                    ),
                    const SettingsScreen(),
                  ],
                ),
              ),

              // 2. Barra inferior: vive FUERA del IndexedStack para
              // sobrevivir a los push de Album/Artist. En portrait
              // muestra MiniPlayer + NavigationBar. En landscape solo
              // MiniPlayer (los tabs van en el drawer).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: RepaintBoundary(
                  child: _FrostedBottomBar(
                    index: _index,
                    showNavBar: !isLandscape,
                    onChange: (i) {
                      if (i == _index && i < _tabNavKeys.length) {
                        _tabNavKeys[i]
                            .currentState
                            ?.popUntil((r) => r.isFirst);
                        return;
                      }
                      setState(() {
                        _index = i;
                        TabNavigation.activeIndex = i;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// Navigator anidado para una tab. La página raíz es `initial`; los push
/// dentro de esta tab (Album, Artist, etc.) se apilan aquí y por tanto NO
/// tapan la barra inferior — perfecto para el patrón "mini-player y tabs
/// siempre visibles" tipo Spotify/YT Music.
class _TabNavigator extends StatelessWidget {
  const _TabNavigator({required this.navigatorKey, required this.initial});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget initial;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => initial,
      ),
    );
  }
}

/// Tab bar al estilo iOS: translúcida con blur sobre el background, hairline
/// divider arriba, mini-player encima.
///
/// **Por qué BackdropFilter y no FrostedSurface (sampler)**: la barra es
/// estática (no scrollea) → BackdropFilter no sufre del flash/sticky que
/// teníamos con cards. Además permite blurear el contenido REAL que pasa
/// por debajo (no solo el bg), lo que da el feel iOS auténtico — el sampler
/// solo blurea el bg pre-renderado.
class _FrostedBottomBar extends StatelessWidget {
  const _FrostedBottomBar({
    required this.index,
    required this.onChange,
    this.showNavBar = true,
  });

  final int index;
  final ValueChanged<int> onChange;

  /// Si es `false`, solo se muestra el MiniPlayer (los tabs viven en
  /// otro lado — ej. drawer lateral en landscape).
  final bool showNavBar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);

    return ClipRect(
      child: Stack(
        children: [
          // Capa base de oscurecimiento (tinte de marca).
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.18),
              ),
            ),
          ),
          // El filtro de blur real.
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(
                    alpha: (0.65 + settings.effectiveSurfaceOpacity * 0.25)
                        .clamp(0.0, 1.0),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                      width: 0.5,
                    ),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.05),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.03),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Contenido (define el tamaño del Stack).
          SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MiniPlayer(),
                if (showNavBar)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  // El bottom nav también vive sobre el bg dinámico de la
                  // app. Wrap en AdaptiveColor → los iconos/labels eligen
                  // tinta clara/oscura según la franja inferior del bg.
                  child: AdaptiveColor(
                    builder: (context, color) => NavigationBarTheme(
                      data: NavigationBarThemeData(
                        backgroundColor: Colors.transparent,
                        surfaceTintColor: Colors.transparent,
                        indicatorColor: scheme.primary.withValues(alpha: 0.18),
                        iconTheme: WidgetStateProperty.resolveWith((states) {
                          // Seleccionado conserva el primary del tema (es
                          // un acento intencional). No-seleccionado usa el
                          // color adaptativo atenuado.
                          if (states.contains(WidgetState.selected)) {
                            return IconThemeData(color: scheme.primary);
                          }
                          return IconThemeData(
                              color: color.withValues(alpha: 0.75));
                        }),
                        labelTextStyle: WidgetStateProperty.resolveWith(
                          (states) {
                            if (states.contains(WidgetState.selected)) {
                              return TextStyle(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12);
                            }
                            return TextStyle(
                                color: color.withValues(alpha: 0.75),
                                fontSize: 12);
                          },
                        ),
                      ),
                      child: NavigationBar(
                        height: MediaQuery.orientationOf(context) ==
                                Orientation.landscape
                            ? 60
                            : 72,
                        selectedIndex: index,
                        onDestinationSelected: onChange,
                        labelBehavior:
                            NavigationDestinationLabelBehavior.alwaysShow,
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home_outlined),
                            selectedIcon: Icon(Icons.home_rounded),
                            label: 'Inicio',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.library_music_outlined),
                            selectedIcon: Icon(Icons.library_music_rounded),
                            label: 'Biblioteca',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.tune_outlined),
                            selectedIcon: Icon(Icons.tune_rounded),
                            label: 'Ajustes',
                          ),
                        ],
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
}

/// Drawer lateral usado en landscape para reemplazar la `NavigationBar`
/// inferior. Mismo set de destinations, mismo estado seleccionado, y
/// vuelve a la raíz de la tab si tocas la que ya está activa.
class _SideMenuDrawer extends StatelessWidget {
  const _SideMenuDrawer({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);
    return Drawer(
      // Drawer transparente — el blur + tint se aplican dentro vía
      // BackdropFilter para look glass coherente con las GlassCards.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(
                alpha: (0.62 + settings.effectiveSurfaceOpacity * 0.20)
                    .clamp(0.0, 1.0),
              ),
              border: Border(
                right: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.music_note_rounded,
                      color: scheme.primary, size: 28),
                  const SizedBox(width: 10),
                  Text(
                    'Vibra',
                    style:
                        Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                            ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 8),
            _DrawerTile(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: 'Inicio',
              selected: index == 0,
              onTap: () {
                onSelect(0);
                Navigator.of(context).pop();
              },
            ),
            _DrawerTile(
              icon: Icons.library_music_outlined,
              selectedIcon: Icons.library_music_rounded,
              label: 'Biblioteca',
              selected: index == 1,
              onTap: () {
                onSelect(1);
                Navigator.of(context).pop();
              },
            ),
            _DrawerTile(
              icon: Icons.tune_outlined,
              selectedIcon: Icons.tune_rounded,
              label: 'Ajustes',
              selected: index == 2,
              onTap: () {
                onSelect(2);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 22,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.85),
                ),
                const SizedBox(width: 16),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
