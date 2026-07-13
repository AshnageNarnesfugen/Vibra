import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/theme/layout_tokens.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/labeled_slider.dart';
import '../../widgets/stable_backdrop_group.dart';

class EffectsSettingsScreen extends StatelessWidget {
  const EffectsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Efectos')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          // ---------- Fondo ----------
          _SectionHeader(label: 'Fondo'),
          SizedBox(height: tokens.gapSm),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Desenfoque del fondo'),
                  subtitle: const Text(
                      'Aplica un BackdropFilter sobre la imagen / gradiente.'),
                  value: s.blurEnabled,
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(blurEnabled: v)),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: s.blurEnabled
                      ? LabeledSlider(
                          label: 'Intensidad',
                          value: s.blurIntensity,
                          min: 0,
                          max: 40,
                          format: (v) => v.toStringAsFixed(1),
                          onChanged: (v) => ctrl
                              .update((p) => p.copyWith(blurIntensity: v)),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: LabeledSlider(
              label: 'Ruido / grano del fondo',
              subtitle:
                  'Añade textura granosa al fondo para evitar bandas y dar carácter.',
              value: s.noiseIntensity,
              min: 0,
              max: 0.6,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) =>
                  ctrl.update((p) => p.copyWith(noiseIntensity: v)),
            ),
          ),
          SizedBox(height: tokens.gapLg),

          // ---------- Tarjetas / superficies ----------
          _SectionHeader(label: 'Tarjetas y superficies'),
          SizedBox(height: tokens.gapSm),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Frosted glass en las cartas'),
                  subtitle: const Text(
                    'Cada tarjeta difumina lo que tiene debajo, '
                    'independientemente del blur del fondo.',
                  ),
                  value: s.cardBlurEnabled,
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(cardBlurEnabled: v)),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: s.cardBlurEnabled
                      ? LabeledSlider(
                          label: 'Intensidad',
                          value: s.cardBlurIntensity,
                          min: 0,
                          max: 30,
                          format: (v) => v.toStringAsFixed(1),
                          onChanged: (v) => ctrl.update(
                              (p) => p.copyWith(cardBlurIntensity: v)),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: LabeledSlider(
              label: 'Ruido / grano de las cartas',
              subtitle: 'Solo afecta a las superficies, no al fondo.',
              value: s.cardNoiseIntensity,
              min: 0,
              max: 0.6,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) =>
                  ctrl.update((p) => p.copyWith(cardNoiseIntensity: v)),
            ),
          ),
          SizedBox(height: tokens.gapLg),

          // ---------- Movimiento ----------
          _SectionHeader(label: 'Movimiento'),
          SizedBox(height: tokens.gapSm),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Parallax al inclinar el dispositivo'),
                  subtitle: const Text(
                    'El fondo responde a los movimientos del móvil con '
                    'inercia suave, como el wallpaper de la lock screen iOS.',
                  ),
                  value: s.parallaxEnabled,
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(parallaxEnabled: v)),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: s.parallaxEnabled
                      ? LabeledSlider(
                          label: 'Intensidad',
                          value: s.parallaxIntensity,
                          min: 0,
                          max: 1,
                          format: (v) => '${(v * 100).round()}%',
                          onChanged: (v) => ctrl
                              .update((p) => p.copyWith(parallaxIntensity: v)),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),

          // ---------- Audio ----------
          SizedBox(height: tokens.gap),
          _SectionHeader(label: 'Audio'),
          SizedBox(height: tokens.gapSm),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fade al reproducir y pausar'),
                  subtitle: const Text(
                      'Sube/baja el volumen gradualmente en vez de cortar '
                      'el audio en seco.'),
                  value: s.fadeOnPlayPauseEnabled,
                  onChanged: (v) => ctrl
                      .update((p) => p.copyWith(fadeOnPlayPauseEnabled: v)),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: s.fadeOnPlayPauseEnabled
                      ? LabeledSlider(
                          label: 'Duración del fade',
                          value: s.fadeDurationMs.toDouble(),
                          min: 100,
                          max: 1500,
                          divisions: 28,
                          format: (v) => '${v.round()} ms',
                          onChanged: (v) => ctrl.update(
                            (p) => p.copyWith(fadeDurationMs: v.round()),
                          ),
                        )
                      : const SizedBox.shrink(),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
      ),
    );
  }
}
