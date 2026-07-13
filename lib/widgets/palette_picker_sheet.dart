import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/palette_signal.dart';

/// Modal bottom sheet con DOS pickers de color:
///   - **Principal**: tinte ambiental (fondos, scrims, cards).
///   - **Acento**: highlights (primary del scheme, iconos, sliders).
///
/// Las dos secciones son independientes y los taps NO cierran el sheet
/// — el usuario puede preview ambos slots antes de aceptar. Se cierra
/// al deslizar abajo o tocar fuera.
class PalettePickerSheet extends StatelessWidget {
  const PalettePickerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const PalettePickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.watch<PaletteSignal>();
    final swatches = palette.availableSwatches;
    final scheme = Theme.of(context).colorScheme;
    final currentDominant = palette.palette?.dominant;
    final currentAccent = palette.palette?.accent;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle visual.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Colores del álbum',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Elige tinte principal y acento detectados en la portada',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
            ),
            const SizedBox(height: 20),
            if (swatches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No hay paleta disponible para esta canción.',
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              )
            else ...[
              _SectionHeader(
                title: 'Principal',
                hint: 'Tinte de fondos y superficies',
              ),
              const SizedBox(height: 12),
              _SwatchRow(
                swatches: swatches,
                selected: currentDominant,
                onTap: (c) {
                  palette.setUserOverride(
                    palette.buildOverride(dominant: c),
                  );
                },
              ),
              const SizedBox(height: 20),
              _SectionHeader(
                title: 'Acento',
                hint: 'Color de textos, iconos y sliders activos',
              ),
              const SizedBox(height: 12),
              _SwatchRow(
                swatches: swatches,
                selected: currentAccent,
                onTap: (c) {
                  palette.setUserOverride(
                    palette.buildOverride(accent: c),
                  );
                },
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.casino_rounded),
                    label: const Text('Aleatorio'),
                    onPressed: swatches.length < 2
                        ? null
                        : () {
                            // Elige uno principal distinto al actual y un
                            // acento distinto al principal nuevo →
                            // siempre se siente un cambio.
                            final rand = math.Random();
                            final newDom = _pickDifferent(
                                swatches, currentDominant, rand);
                            final newAcc = _pickDifferent(
                                swatches, newDom, rand);
                            palette.setUserOverride(palette.buildOverride(
                              dominant: newDom,
                              accent: newAcc,
                            ));
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Restaurar'),
                    onPressed: () {
                      palette.setUserOverride(null);
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color _pickDifferent(
      List<Color> swatches, Color? avoid, math.Random rand) {
    if (avoid == null) return swatches[rand.nextInt(swatches.length)];
    final cands = swatches.where((c) => !_isSameColor(c, avoid)).toList();
    if (cands.isEmpty) return swatches[rand.nextInt(swatches.length)];
    return cands[rand.nextInt(cands.length)];
  }

  /// Compara dos colores con tolerancia chica para que el "selected" no
  /// falle por diferencias sub-perceptibles que vienen de la
  /// conversión Color → AlbumPalette → Color.
  static bool _isSameColor(Color? a, Color? b) {
    if (a == null || b == null) return false;
    return ((a.r - b.r) * 255).abs() < 4 &&
        ((a.g - b.g) * 255).abs() < 4 &&
        ((a.b - b.b) * 255).abs() < 4;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
        ),
      ],
    );
  }
}

class _SwatchRow extends StatelessWidget {
  const _SwatchRow({
    required this.swatches,
    required this.selected,
    required this.onTap,
  });

  final List<Color> swatches;
  final Color? selected;
  final ValueChanged<Color> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final c in swatches)
          _SwatchChip(
            color: c,
            selected: PalettePickerSheet._isSameColor(selected, c),
            onTap: () => onTap(c),
          ),
      ],
    );
  }
}

class _SwatchChip extends StatelessWidget {
  const _SwatchChip({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? scheme.onSurface
                : scheme.onSurface.withValues(alpha: 0.15),
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check_rounded,
                color: _readableOn(color),
                size: 24,
              )
            : null,
      ),
    );
  }

  /// Tinta legible (blanco u oscuro) sobre el swatch — el checkmark
  /// destaca sin importar si el swatch es claro u oscuro.
  static Color _readableOn(Color bg) {
    final l = bg.computeLuminance();
    return l > 0.5 ? Colors.black87 : Colors.white;
  }
}
