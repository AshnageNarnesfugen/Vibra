import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../widgets/color_picker_sheet.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  static const _palette = [
    Color(0xFF7C5CFF),
    Color(0xFFFF5C8A),
    Color(0xFF21C7A8),
    Color(0xFFFFB454),
    Color(0xFF4FA8FF),
    Color(0xFFE0E0E0),
    Color(0xFFB388FF),
    Color(0xFFFF8A65),
  ];

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Tema y color')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Color dinámico desde la portada'),
                  subtitle: const Text(
                    'El acento y los textos se derivan del album art y siempre '
                    'respetan contraste mínimo legible.',
                  ),
                  value: s.useDynamicColorFromAlbumArt,
                  onChanged: (v) => ctrl.update(
                      (p) => p.copyWith(useDynamicColorFromAlbumArt: v)),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Acento por defecto',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => showColorPickerSheet(
                        context,
                        initialColor: s.fallbackAccentColor,
                        allowAlpha: false,
                        title: 'Color de acento',
                        onChanged: (c) => ctrl.update(
                            (p) => p.copyWith(fallbackAccentColor: c)),
                      ),
                      icon: const Icon(Icons.colorize_rounded, size: 18),
                      label: const Text('Picker'),
                    ),
                  ],
                ),
                SizedBox(height: tokens.gapSm),
                Text(
                  'Se usa cuando no hay portada o desactivaste color dinámico.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: tokens.gap),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _palette
                      .map(
                        (c) => GestureDetector(
                          onTap: () => ctrl.update(
                              (p) => p.copyWith(fallbackAccentColor: c)),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: c.toARGB32() ==
                                        s.fallbackAccentColor.toARGB32()
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: c.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Modo',
                    style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: tokens.gapSm),
                SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<AppThemeMode>(
                    groupValue: s.themeMode,
                    thumbColor: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.85),
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    children: const {
                      AppThemeMode.light: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.light_mode_rounded, size: 14),
                            SizedBox(width: 4),
                            Text('Claro',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      AppThemeMode.dark: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.dark_mode_rounded, size: 14),
                            SizedBox(width: 4),
                            Text('Oscuro',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      AppThemeMode.auto: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_mode_rounded, size: 14),
                            SizedBox(width: 4),
                            Text('Auto',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      AppThemeMode.system: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.smartphone_rounded, size: 14),
                            SizedBox(width: 4),
                            Text('Sistema',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    },
                    onValueChanged: (v) {
                      if (v == null) return;
                      ctrl.update((p) => p.copyWith(themeMode: v));
                    },
                  ),
                ),
                SizedBox(height: tokens.gapSm),
                Text(
                  switch (s.themeMode) {
                    AppThemeMode.light =>
                      'Tema siempre claro independiente del fondo.',
                    AppThemeMode.dark =>
                      'Tema siempre oscuro independiente del fondo.',
                    AppThemeMode.auto =>
                      'Se adapta al fondo actual: oscuro si el bg es '
                          'oscuro, claro si es luminoso.',
                    AppThemeMode.system =>
                      'Sigue el ajuste de tu sistema operativo.',
                  },
                  style: Theme.of(context).textTheme.bodySmall,
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
