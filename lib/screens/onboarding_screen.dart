import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/layout_tokens.dart';
import '../widgets/glass_card.dart';
import 'home_screen.dart';
import 'login_screen.dart';

/// Onboarding de primer arranque: 3 páginas que explican lo esencial
/// (qué es Vibra, biblioteca + descargas, cuenta opcional). Se muestra
/// UNA vez — al terminar se persiste el flag y no vuelve a aparecer.
///
/// El fondo es el CustomizedBackground compartido de la app (scaffold
/// transparente), así el onboarding ya se ve "como Vibra" desde el
/// primer segundo.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  static const seenPrefsKey = 'vibra.onboarding.seen.v1';

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageCtrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(OnboardingScreen.seenPrefsKey, true);
    } catch (_) {
      // Si prefs falla, el onboarding volverá a salir la próxima vez —
      // molesto pero no bloqueante.
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
    );
  }

  Future<void> _login() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const LoginScreen()),
    );
    if (!mounted) return;
    // Con o sin login exitoso, el usuario ya pasó por la pantalla de
    // cuenta — el onboarding cumplió su trabajo.
    if (ok == true) await _finish();
  }

  void _next() {
    if (_page >= 2) {
      _finish();
      return;
    }
    _pageCtrl.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Saltar — siempre disponible; el onboarding jamás retiene.
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Saltar'),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _OnboardPage(
                    asset: 'assets/branding/symbol/vibra-symbol-white.png',
                    icon: null,
                    title: 'Bienvenido a Vibra',
                    body: 'Tu música local y el catálogo de YouTube Music '
                        'en un solo reproductor, con una interfaz que se '
                        'tiñe con los colores de cada portada. Fondos, '
                        'formas y animaciones: todo se puede personalizar '
                        'en Ajustes.',
                  ),
                  _OnboardPage(
                    icon: Icons.library_music_rounded,
                    title: 'Biblioteca y descargas',
                    body: 'Vibra escanea la música de tu dispositivo y la '
                        'agrupa por álbumes y artistas. Las canciones de '
                        'streaming se pueden descargar (menú ⋮ → '
                        'Descargar) y quedan como MP3 con carátula en una '
                        'carpeta pública — visibles desde el explorador '
                        'de archivos y otras apps.',
                  ),
                  _OnboardPage(
                    icon: Icons.account_circle_rounded,
                    title: 'Tu cuenta (opcional)',
                    body: 'Sin cuenta puedes buscar y reproducir todo el '
                        'catálogo. Iniciando sesión con Google además '
                        'tienes tu biblioteca personal: tus playlists, '
                        'gustadas, historial y recomendaciones a tu '
                        'medida.',
                  ),
                ],
              ),
            ),
            // Dots + acción principal.
            Padding(
              padding: EdgeInsets.fromLTRB(
                  tokens.gapLg, 0, tokens.gapLg, tokens.gapLg),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < 3; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: i == _page ? 22 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: i == _page
                                ? scheme.primary
                                : scheme.onSurface.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: tokens.gap),
                  if (_page == 2) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _login,
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Iniciar sesión con Google'),
                      ),
                    ),
                    SizedBox(height: tokens.gapSm),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _finish,
                        child: const Text('Explorar sin cuenta'),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _next,
                        child: const Text('Siguiente'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardPage extends StatelessWidget {
  const _OnboardPage({
    required this.title,
    required this.body,
    this.icon,
    this.asset,
  });

  final String title;
  final String body;
  final IconData? icon;
  final String? asset;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: tokens.gapLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (asset != null)
                Image.asset(asset!, width: 108, height: 108)
              else if (icon != null)
                Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 52, color: scheme.primary),
                ),
              SizedBox(height: tokens.gapLg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: tokens.gap),
              GlassCard(
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.5,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
