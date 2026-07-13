import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/theme/layout_tokens.dart';
import '../../providers/bit_perfect_controller.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

/// Pantalla "Modo Hi-Fi / Bit-perfect" — toggle + estado del output device
/// + lista de lo que se desactiva al activar + capability del AAudio
/// nativo (cuando exista).
class HiFiSettingsScreen extends StatelessWidget {
  const HiFiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final bp = context.watch<BitPerfectController>();
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final scheme = Theme.of(context).colorScheme;

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Modo Hi-Fi')),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            // ─────────── Toggle principal ───────────
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.high_quality_rounded,
                          size: 32,
                          color: s.bitPerfectModeEnabled
                              ? scheme.primary
                              : scheme.onSurface),
                      SizedBox(width: tokens.gap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Bit-perfect',
                                style:
                                    Theme.of(context).textTheme.titleLarge),
                            SizedBox(height: tokens.gapSm / 2),
                            Text(
                              'Desactiva todo lo que toca la señal de '
                              'audio en la app. El archivo se entrega lo '
                              'más fiel posible al output.',
                              style:
                                  Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: s.bitPerfectModeEnabled,
                        onChanged: (v) => ctrl.update(
                            (p) => p.copyWith(bitPerfectModeEnabled: v)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),

            // ─────────── Qué se desactiva ───────────
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Qué se desactiva',
                      style: Theme.of(context).textTheme.titleMedium),
                  SizedBox(height: tokens.gapSm),
                  Text(
                    s.bitPerfectModeEnabled
                        ? 'Con bit-perfect ON estos procesos están bloqueados:'
                        : 'Si activas bit-perfect, estos procesos se desactivan automáticamente:',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SizedBox(height: tokens.gapSm),
                  const _RuleRow(
                    label: 'Ecualizador',
                    detail: 'Toggle bloqueado en off, bandas planas.',
                  ),
                  const _RuleRow(
                    label: 'Preamp',
                    detail: 'Ganancia fijada en 0 dB.',
                  ),
                  const _RuleRow(
                    label: 'Fade in / out al play/pause',
                    detail: 'Sin rampa de volumen — corte instantáneo.',
                  ),
                  const _RuleRow(
                    label: 'Chipmunk lock (pitch↔speed)',
                    detail: 'Velocidad y pitch se mantienen independientes.',
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),

            // ─────────── Output actual ───────────
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Salida actual',
                      style: Theme.of(context).textTheme.titleMedium),
                  SizedBox(height: tokens.gap),
                  Row(
                    children: [
                      Icon(
                        bp.output.isUsbDac
                            ? Icons.usb_rounded
                            : bp.output.isWiredHeadphones
                                ? Icons.headphones_rounded
                                : bp.output.isBluetooth
                                    ? Icons.bluetooth_audio_rounded
                                    : Icons.speaker_phone_rounded,
                        size: 28,
                        color: bp.output.isLosslessPath
                            ? scheme.primary
                            : scheme.onSurface.withValues(alpha: 0.7),
                      ),
                      SizedBox(width: tokens.gap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bp.output.displayName,
                              style:
                                  Theme.of(context).textTheme.titleSmall,
                            ),
                            if (bp.output.isLosslessPath)
                              Text(
                                'Path apto para bit-perfect',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: scheme.primary),
                              )
                            else if (bp.output.nonBitPerfectReason != null)
                              Text(
                                bp.output.nonBitPerfectReason!,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: scheme.error,
                                    ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),

            // ─────────── AAudio capability ───────────
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('AAudio nativo',
                          style:
                              Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.tertiary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('Beta',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: scheme.tertiary,
                            )),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.gapSm),
                  if (!bp.aaudioAvailable)
                    Text(
                      'El plugin nativo AAudio no está disponible en este '
                      'device. Requiere Android 8+ (API 26) y un device que '
                      'soporte EXCLUSIVE stream. Sin él, bit-perfect aplica '
                      'sólo en la parte de la app — el routing al DAC sigue '
                      'pasando por AudioFlinger.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else ...[
                    _CapRow(
                      label: 'EXCLUSIVE stream',
                      value: bp.aaudioCapability?.exclusiveSupported == true
                          ? 'Soportado'
                          : 'No soportado',
                      good: bp.aaudioCapability?.exclusiveSupported ?? false,
                    ),
                    _CapRow(
                      label: 'Sample rate nativo',
                      value: bp.aaudioCapability?.preferredSampleRate == 0
                          ? '—'
                          : '${bp.aaudioCapability!.preferredSampleRate} Hz',
                    ),
                    _CapRow(
                      label: 'Burst frames',
                      value: bp.aaudioCapability?.preferredBurstFrames == 0
                          ? '—'
                          : '${bp.aaudioCapability!.preferredBurstFrames} frames',
                    ),
                    _CapRow(
                      label: 'Device',
                      value: bp.aaudioCapability?.deviceName ?? '—',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.label, required this.detail});
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block_rounded,
              size: 16, color: scheme.onSurface.withValues(alpha: 0.6)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        )),
                Text(detail,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.7),
                        )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CapRow extends StatelessWidget {
  const _CapRow({required this.label, required this.value, this.good});
  final String label;
  final String value;
  final bool? good;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color valueColor;
    if (good == true) {
      valueColor = scheme.primary;
    } else if (good == false) {
      valueColor = scheme.error;
    } else {
      valueColor = scheme.onSurface;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: valueColor,
                    fontWeight: FontWeight.w600,
                  )),
        ],
      ),
    );
  }
}
