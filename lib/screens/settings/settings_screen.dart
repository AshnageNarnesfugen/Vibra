import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/animations/page_transitions.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/large_title_scaffold.dart';
import '../../widgets/stable_backdrop_group.dart';
import '../login_screen.dart';
import 'animation_settings_screen.dart';
import 'background_settings_screen.dart';
import 'effects_settings_screen.dart';
import 'equalizer_screen.dart';
import 'floating_mini_settings_screen.dart';
import 'hifi_settings_screen.dart';
import 'language_settings_screen.dart';
import 'quality_settings_screen.dart';
import 'spacing_settings_screen.dart';
import 'storage_settings_screen.dart';
import 'theme_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);
    final ctrl = context.read<SettingsController>();
    final t = AppLocalizations.of(context);

    // Sesión activa = SOLO cookie. Los tokens OAuth están guardados pero
    // Google los rechaza desde finales de 2024 — no cuentan como sesión
    // funcional. Si el usuario tiene solo OAuth, la sub-pantalla de
    // cuenta le explica el estado.
    final hasSession = settings.ytMusicCookie != null;
    final hasOauthOnly = !hasSession &&
        (settings.ytMusicAccessToken != null ||
            settings.ytMusicRefreshToken != null);
    final entries = <_Entry>[
      _Entry(
        title: t.settingsAccountTitle,
        subtitle: hasSession
            ? t.settingsAccountActive
            : hasOauthOnly
                ? t.settingsAccountOauthLimited
                : t.settingsAccountNone,
        icon: hasSession
            ? Icons.verified_user_rounded
            : hasOauthOnly
                ? Icons.warning_amber_rounded
                : Icons.account_circle_outlined,
        builder: () => const LoginScreen(),
      ),
      _Entry(
        title: t.settingsBackgroundTitle,
        subtitle: t.settingsBackgroundSubtitle,
        icon: Icons.wallpaper_rounded,
        builder: () => const BackgroundSettingsScreen(),
      ),
      _Entry(
        title: t.settingsEffectsTitle,
        subtitle: t.settingsEffectsSubtitle,
        icon: Icons.blur_on_rounded,
        builder: () => const EffectsSettingsScreen(),
      ),
      _Entry(
        title: t.settingsThemeTitle,
        subtitle: t.settingsThemeSubtitle,
        icon: Icons.palette_rounded,
        builder: () => const ThemeSettingsScreen(),
      ),
      _Entry(
        title: t.settingsSpacingTitle,
        subtitle: t.settingsSpacingSubtitle,
        icon: Icons.grid_view_rounded,
        builder: () => const SpacingSettingsScreen(),
      ),
      _Entry(
        title: t.settingsAnimationsTitle,
        subtitle: t.settingsAnimationsSubtitle,
        icon: Icons.animation_rounded,
        builder: () => const AnimationSettingsScreen(),
      ),
      _Entry(
        title: t.settingsQualityTitle,
        subtitle: t.settingsQualitySubtitle,
        icon: Icons.high_quality_rounded,
        builder: () => const QualitySettingsScreen(),
      ),
      _Entry(
        title: t.settingsStorageTitle,
        subtitle: t.settingsStorageSubtitle,
        icon: Icons.folder_special_rounded,
        builder: () => const StorageSettingsScreen(),
      ),
      _Entry(
        title: t.settingsEqTitle,
        subtitle: t.settingsEqSubtitle,
        icon: Icons.equalizer_rounded,
        builder: () => const EqualizerScreen(),
      ),
      _Entry(
        title: t.settingsHifiTitle,
        subtitle: t.settingsHifiSubtitle,
        icon: Icons.graphic_eq_rounded,
        builder: () => const HiFiSettingsScreen(),
      ),
      _Entry(
        title: t.settingsLanguageTitle,
        subtitle: t.settingsLanguageSubtitle,
        icon: Icons.translate_rounded,
        builder: () => const LanguageSettingsScreen(),
      ),
      _Entry(
        title: t.settingsFloatingTitle,
        subtitle: t.settingsFloatingSubtitle,
        icon: Icons.picture_in_picture_alt_rounded,
        builder: () => const FloatingMiniSettingsScreen(),
      ),
    ];

    return StableBackdropGroup(
      child: LargeTitleScaffold.body(
      title: t.settingsTitle,
      // 200px (antes 160) — el mini-player + nav ocupan ~150-160 y con
      // 160 el botón "Restablecer ajustes" del final del scroll quedaba
      // tapado por el mini-player.
      bottomReserve: 200,
      body: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.space(20),
          vertical: tokens.space(8),
        ),
        child: Column(
          children: [
            for (final e in entries) ...[
              GlassCard(
                onTap: () => Navigator.of(context).pushAnimated(
                  e.builder(),
                  style: settings.transitionStyle,
                  durationMs: settings.transitionDurationMs,
                ),
                child: Row(
                  children: [
                    Icon(e.icon, size: 28),
                    SizedBox(width: tokens.gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            e.subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
              SizedBox(height: tokens.gap),
            ],
            SizedBox(height: tokens.gap),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(t.settingsReset),
                    content: const Text(
                        '¿Restaurar todos los ajustes a sus valores por defecto?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(t.cancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(t.settingsReset),
                      ),
                    ],
                  ),
                );
                if (ok == true) ctrl.resetDefaults();
              },
              icon: const Icon(Icons.restart_alt_rounded),
              label: Text(t.settingsReset),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _Entry {
  const _Entry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() builder;
}
