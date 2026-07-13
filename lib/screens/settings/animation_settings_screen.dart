import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/animations/page_transitions.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/labeled_slider.dart';
import '../../widgets/stable_backdrop_group.dart';

class AnimationSettingsScreen extends StatelessWidget {
  const AnimationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Animaciones')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Estilo de transición entre vistas',
                    style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: tokens.gapSm),
                RadioGroup<PageTransitionStyle>(
                  groupValue: s.transitionStyle,
                  onChanged: (v) {
                    if (v == null) return;
                    ctrl.update((p) => p.copyWith(transitionStyle: v));
                  },
                  child: Column(
                    children: PageTransitionStyle.values
                        .map(
                          (style) => RadioListTile<PageTransitionStyle>(
                            contentPadding: EdgeInsets.zero,
                            value: style,
                            title: Text(style.label),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: LabeledSlider(
              label: 'Duración',
              subtitle: 'Velocidad de la animación de transición.',
              value: s.transitionDurationMs.toDouble(),
              min: 120,
              max: 700,
              divisions: 29,
              format: (v) => '${v.round()} ms',
              onChanged: (v) => ctrl.update(
                (p) => p.copyWith(transitionDurationMs: v.round()),
              ),
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Forma de la carátula',
                    style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: tokens.gapSm),
                Text(
                  'Estándar, disco girando (estilo vinilo) o cuadrado con '
                  'overlay holográfico que reacciona al giroscopio.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: tokens.gapSm),
                RadioGroup<CoverShape>(
                  groupValue: s.coverShape,
                  onChanged: (v) {
                    if (v == null) return;
                    ctrl.update((p) => p.copyWith(coverShape: v));
                  },
                  child: const Column(
                    children: [
                      RadioListTile<CoverShape>(
                        contentPadding: EdgeInsets.zero,
                        value: CoverShape.square,
                        title: Text('Cuadrado'),
                      ),
                      RadioListTile<CoverShape>(
                        contentPadding: EdgeInsets.zero,
                        value: CoverShape.cd,
                        title: Text('Disco girando'),
                      ),
                      RadioListTile<CoverShape>(
                        contentPadding: EdgeInsets.zero,
                        value: CoverShape.holographic,
                        title: Text('Holográfico con tilt'),
                      ),
                    ],
                  ),
                ),
                // Sliders de intensidad — solo visibles cuando el shape
                // es holográfico. Los dos efectos son independientes:
                //   - Tilt 3D: el cover se inclina físicamente con el
                //     giroscopio (rotación Matrix4).
                //   - Parallax: las bandas iridiscentes del shader se
                //     desplazan con el viewing angle (efecto "foil").
                // Cualquiera puede estar al 0 sin afectar al otro — útil
                // si el 3D marea pero el foil se quiere mantener vivo, o
                // viceversa.
                if (s.coverShape == CoverShape.holographic) ...[
                  SizedBox(height: tokens.gap),
                  Text('Intensidad del tilt 3D',
                      style: Theme.of(context).textTheme.titleSmall),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    s.holoTiltIntensity == 0
                        ? 'Sin tilt — el cover queda plano.'
                        : 'Inclinación al mover el device: '
                            '${(s.holoTiltIntensity * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Slider(
                    value: s.holoTiltIntensity,
                    min: 0,
                    max: 1,
                    divisions: 10,
                    label: s.holoTiltIntensity == 0
                        ? 'Off'
                        : '${(s.holoTiltIntensity * 100).round()}%',
                    onChanged: (v) =>
                        ctrl.update((p) => p.copyWith(holoTiltIntensity: v)),
                  ),
                  SizedBox(height: tokens.gapSm),
                  Text('Intensidad del parallax holográfico',
                      style: Theme.of(context).textTheme.titleSmall),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    s.holoParallaxIntensity == 0
                        ? 'Sin parallax — bandas animadas solo por tiempo.'
                        : 'Desplazamiento de las bandas con el ángulo: '
                            '${(s.holoParallaxIntensity * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Slider(
                    value: s.holoParallaxIntensity,
                    min: 0,
                    max: 1,
                    divisions: 10,
                    label: s.holoParallaxIntensity == 0
                        ? 'Off'
                        : '${(s.holoParallaxIntensity * 100).round()}%',
                    onChanged: (v) => ctrl
                        .update((p) => p.copyWith(holoParallaxIntensity: v)),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Probar animación',
                    style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: tokens.gap),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pushAnimated(
                    const _PreviewScreen(),
                    style: s.transitionStyle,
                    durationMs: s.transitionDurationMs,
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Abrir pantalla de prueba'),
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

class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Vista de prueba')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Si ves esta pantalla, la transición está funcionando.\n\n'
            'Cierra para regresar y probar otro estilo.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}
