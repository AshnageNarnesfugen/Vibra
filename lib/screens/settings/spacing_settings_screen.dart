import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/theme/layout_tokens.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/labeled_slider.dart';
import '../../widgets/stable_backdrop_group.dart';

class SpacingSettingsScreen extends StatelessWidget {
  const SpacingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Espaciado y bordes')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          GlassCard(
            child: Column(
              children: [
                LabeledSlider(
                  label: 'Densidad / espaciado',
                  subtitle:
                      'Multiplica todos los paddings y márgenes de la app.',
                  value: s.spacingScale,
                  min: 0.6,
                  max: 1.6,
                  divisions: 20,
                  format: (v) => '${(v * 100).round()}%',
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(spacingScale: v)),
                ),
                LabeledSlider(
                  label: 'Radio de bordes',
                  subtitle:
                      '0 = bordes rectos · 32 = totalmente redondeados.',
                  value: s.cornerRadius,
                  min: 0,
                  max: 32,
                  divisions: 32,
                  format: (v) => '${v.round()} px',
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(cornerRadius: v)),
                ),
                LabeledSlider(
                  label: 'Densidad de la lista de canciones',
                  subtitle: 'Mueve a la izquierda para apilar varias canciones '
                      'por fila cuando hay espacio (auto en horizontal). '
                      'A la derecha, una canción por fila a todo lo ancho.',
                  value: s.songTileMinWidth,
                  min: 240,
                  max: 640,
                  divisions: 40,
                  format: (v) => '${v.round()} px / tile',
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(songTileMinWidth: v)),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vista previa',
                    style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: tokens.gap),
                Container(
                  padding: tokens.cardPadding(),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.18),
                    borderRadius: tokens.radius,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.album_rounded,
                          color: Theme.of(context).colorScheme.primary),
                      SizedBox(width: tokens.gap),
                      const Expanded(
                        child: Text('Tarjeta de ejemplo · prueba el slider'),
                      ),
                      FilledButton(
                        onPressed: () {},
                        child: const Text('Acción'),
                      ),
                    ],
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
