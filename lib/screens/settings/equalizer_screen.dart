import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../providers/equalizer_controller.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

/// Pantalla del ecualizador: sliders verticales por banda + selector de
/// presets + preamp + toggle on/off.
///
/// El número de sliders viene dictado por el SO: típicamente 5 en stock
/// Android, hasta 10 en Samsung One UI. Los presets builtin están diseñados
/// para 10 bandas y se interpolan al número real del device.
class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final eq = context.watch<EqualizerController>();

    if (!eq.available) {
      return StableBackdropGroup(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Ecualizador')),
          body: Center(
            child: Padding(
              padding: tokens.pagePadding(),
              child: const Text(
                'El ecualizador solo está disponible en Android. '
                'iOS y escritorio usan rutas de audio distintas.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Ecualizador'),
          actions: [
            // Toggle global on/off. Cuando OFF, los effects se desactivan
            // pero los valores se mantienen — al reactivar el usuario los
            // recupera tal cual.
            //
            // Si bit-perfect está ON, el toggle queda desactivado y el
            // banner de arriba explica por qué — sin esto el usuario
            // podía tocarlo y el BitPerfectController lo apagaba
            // inmediatamente, dando un flicker confuso.
            Builder(builder: (ctx) {
              final bitPerfect =
                  UiSettingsScope.of(ctx).bitPerfectModeEnabled;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Switch.adaptive(
                  value: eq.enabled,
                  onChanged: bitPerfect
                      ? null
                      : (v) => eq.setEnabled(v),
                ),
              );
            }),
          ],
        ),
        body: !eq.isReady
            ? const _LoadingState()
            : ListView(
                padding: tokens.pagePadding(),
                children: [
                  // Banner explicativo cuando bit-perfect está ON — el
                  // toggle del EQ está forzado a OFF y los sliders no
                  // responden. Le decimos al usuario por qué para que no
                  // piense que la app está bugueada.
                  if (UiSettingsScope.of(context).bitPerfectModeEnabled) ...[
                    const _BitPerfectLockedBanner(),
                    SizedBox(height: tokens.gap),
                  ],
                  _PresetSelector(eq: eq),
                  SizedBox(height: tokens.gap),
                  _BandsCard(eq: eq),
                  SizedBox(height: tokens.gap),
                  _PreampCard(eq: eq),
                  SizedBox(height: tokens.gap),
                  _ActionsCard(eq: eq),
                  SizedBox(height: tokens.gap),
                ],
              ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Inicializando ecualizador…\n'
              'Reproduce una canción para que el sistema cargue '
              'los parámetros nativos.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetSelector extends StatelessWidget {
  const _PresetSelector({required this.eq});
  final EqualizerController eq;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preset', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.gapSm),
          // SingleChildScrollView horizontal con chips para evitar layout
          // pesado de DropdownButton — es más rápido tocar un chip que
          // abrir un menú con 10+ opciones.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in eq.builtinPresets) ...[
                  ChoiceChip(
                    label: Text(p.name),
                    selected: eq.activePresetName == p.name,
                    onSelected: (_) => eq.applyPreset(p),
                  ),
                  const SizedBox(width: 6),
                ],
                if (eq.customPresets.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Container(
                      width: 1,
                      height: 24,
                      color: scheme.outline.withValues(alpha: 0.4),
                    ),
                  ),
                for (final p in eq.customPresets) ...[
                  InputChip(
                    label: Text(p.name),
                    selected: eq.activePresetName == p.name,
                    onSelected: (_) => eq.applyPreset(p),
                    onDeleted: () => _confirmDelete(context, p.name),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar preset'),
        content: Text('¿Borrar el preset "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await eq.deleteCustomPreset(name);
    }
  }
}

class _BandsCard extends StatelessWidget {
  const _BandsCard({required this.eq});
  final EqualizerController eq;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bandCount = eq.gainsDb.length;
    final freqs = eq.bandCenterFrequencies;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Bandas',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                '${eq.bandMinDb.round()} dB / +${eq.bandMaxDb.round()} dB',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
              ),
            ],
          ),
          SizedBox(height: tokens.gap),
          // Row de sliders verticales. Cada slider ocupa ancho equitativo
          // dentro del card. Altura fija para evitar layout dance cuando
          // el usuario arrastra.
          SizedBox(
            height: 220,
            child: Row(
              children: [
                for (var i = 0; i < bandCount; i++)
                  Expanded(
                    child: _BandSlider(
                      eq: eq,
                      bandIndex: i,
                      frequency:
                          i < freqs.length ? freqs[i] : 0.0,
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

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.eq,
    required this.bandIndex,
    required this.frequency,
  });
  final EqualizerController eq;
  final int bandIndex;
  final double frequency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = eq.gainsDb[bandIndex];
    return Column(
      children: [
        Text(
          _fmtDb(value),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color:
                    value == 0 ? scheme.onSurface.withValues(alpha: 0.6) : null,
              ),
        ),
        Expanded(
          // RotatedBox(quarterTurns: -1) gira el slider 90° → vertical.
          // Es el truco estándar para no escribir un VerticalSlider custom.
          child: RotatedBox(
            quarterTurns: -1,
            child: Slider(
              value: value,
              min: eq.bandMinDb,
              max: eq.bandMaxDb,
              onChanged: !eq.enabled
                  ? null
                  : (v) => eq.setBandGain(bandIndex, v),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _fmtFreq(frequency),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
        ),
      ],
    );
  }

  static String _fmtDb(double v) {
    if (v.abs() < 0.05) return '0';
    final sign = v > 0 ? '+' : '';
    return '$sign${v.toStringAsFixed(1)}';
  }

  /// Freq en Hz → "60", "250", "1k", "8k". El SO devuelve algunos en
  /// fracciones (62.5 Hz, 125 Hz); redondeamos al entero.
  static String _fmtFreq(double hz) {
    if (hz <= 0) return '';
    if (hz < 1000) return '${hz.round()}';
    final khz = hz / 1000;
    if (khz == khz.roundToDouble()) return '${khz.round()}k';
    return '${khz.toStringAsFixed(1)}k';
  }
}

class _PreampCard extends StatelessWidget {
  const _PreampCard({required this.eq});
  final EqualizerController eq;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Preamp',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                _fmtDb(eq.preampDb),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: eq.preampDb == 0 ? null : scheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ],
          ),
          SizedBox(height: tokens.gapSm),
          Text(
            'Ganancia general antes del EQ. Útil para subir volumen de '
            'archivos muy bajos o evitar clipping cuando todas las '
            'bandas están en positivo.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Slider(
            value: eq.preampDb,
            min: -15,
            max: 15,
            divisions: 60,
            label: _fmtDb(eq.preampDb),
            onChanged: !eq.enabled ? null : (v) => eq.setPreampDb(v),
          ),
        ],
      ),
    );
  }

  static String _fmtDb(double v) {
    if (v.abs() < 0.05) return '0 dB';
    final sign = v > 0 ? '+' : '';
    return '$sign${v.toStringAsFixed(1)} dB';
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.eq});
  final EqualizerController eq;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Acciones', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.gap),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: !eq.enabled
                    ? null
                    : () => _promptSavePreset(context, eq),
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Guardar como preset'),
              ),
              OutlinedButton.icon(
                onPressed: !eq.enabled ? null : eq.resetFlat,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reset a plano'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _promptSavePreset(
      BuildContext context, EqualizerController eq) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo preset'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Mi mezcla',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await eq.saveCurrentAsPreset(name.trim());
    }
  }
}

/// Banner que se muestra encima del EQ cuando el modo bit-perfect está
/// activo. Explica por qué los controles están bloqueados y ofrece atajo
/// para apagar el modo si el usuario quiere usar el EQ.
class _BitPerfectLockedBanner extends StatelessWidget {
  const _BitPerfectLockedBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.high_quality_rounded,
              color: scheme.tertiary, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Modo bit-perfect activo',
                  style:
                      Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: scheme.tertiary,
                          ),
                ),
                const SizedBox(height: 4),
                Text(
                  'El ecualizador está deshabilitado mientras bit-perfect '
                  'está prendido — la idea es no tocar la señal. '
                  'Apaga el modo en Ajustes › Modo Hi-Fi para usar EQ.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
