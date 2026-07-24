import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/settings/settings_controller.dart';
import '../core/theme/layout_tokens.dart';
import '../providers/playback_controller.dart';
import 'glass_card.dart';

/// Bottom sheet con sliders de velocidad de reproducción y pitch.
///
/// Persiste en settings: cualquier cambio se propaga inmediatamente al
/// `PlaybackController` via el `_onSettingsChanged` listener — el usuario
/// oye el cambio en vivo mientras arrastra los sliders.
///
/// El lock pitch↔speed (chipmunk) está OFF por default — la mayoría
/// quiere cambiar velocidad SIN que la voz suene a ardilla. Quien quiera
/// el efecto retro de "reproducir un cassette mal" lo activa explícito.
Future<void> showPlaybackParamsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (ctx) => const _PlaybackParamsSheet(),
  );
}

class _PlaybackParamsSheet extends StatelessWidget {
  const _PlaybackParamsSheet();

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    final isNeutral = s.playbackSpeed == 1.0 && s.playbackPitchSemitones == 0.0;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: tokens.gap,
          right: tokens.gap,
          top: tokens.gap,
          bottom: tokens.gap + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.speed_rounded,
                      size: 22, color: scheme.primary),
                  SizedBox(width: tokens.gapSm),
                  Text('Velocidad y tono',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  if (!isNeutral)
                    TextButton.icon(
                      onPressed: () => ctrl.update((p) => p.copyWith(
                            playbackSpeed: 1.0,
                            playbackPitchSemitones: 0.0,
                          )),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Reset'),
                    ),
                ],
              ),
              SizedBox(height: tokens.gap),
              // ─────────── Speed ───────────
              Row(
                children: [
                  Text('Velocidad',
                      style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  Text(_fmtSpeed(s.playbackSpeed),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: s.playbackSpeed == 1.0
                                ? null
                                : scheme.primary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          )),
                ],
              ),
              Slider(
                value: s.playbackSpeed,
                min: 0.5,
                max: 2.0,
                // Divisions cada 0.05 → 30 pasos. Lo bastante fino para
                // ajuste preciso sin que el slider se sienta continuo
                // (Material recomienda divisiones discretas para valores
                // que el usuario va a recordar).
                divisions: 30,
                label: _fmtSpeed(s.playbackSpeed),
                onChanged: (v) =>
                    ctrl.update((p) => p.copyWith(playbackSpeed: v)),
              ),
              // Atajos rápidos: chips con los valores más usados.
              Wrap(
                spacing: 8,
                children: [
                  for (final v in const [0.75, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                      label: Text(_fmtSpeed(v)),
                      selected: (s.playbackSpeed - v).abs() < 0.001,
                      onSelected: (_) =>
                          ctrl.update((p) => p.copyWith(playbackSpeed: v)),
                    ),
                ],
              ),
              SizedBox(height: tokens.gap),
              // ─────────── Pitch ───────────
              Row(
                children: [
                  Text('Tono (semitonos)',
                      style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  Text(_fmtSemis(s.playbackPitchSemitones),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: s.playbackPitchSemitones == 0
                                ? null
                                : scheme.primary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          )),
                ],
              ),
              Slider(
                value: s.playbackPitchSemitones,
                min: -12,
                max: 12,
                // 48 divisions = paso de 0.5 semitono. Más fino que esto
                // ya no es perceptible para el oído humano sin training.
                divisions: 48,
                label: _fmtSemis(s.playbackPitchSemitones),
                onChanged: s.lockPitchToSpeed
                    ? null
                    : (v) => ctrl.update(
                        (p) => p.copyWith(playbackPitchSemitones: v)),
              ),
              if (s.lockPitchToSpeed)
                Padding(
                  padding: EdgeInsets.only(left: 12, bottom: tokens.gapSm),
                  child: Text(
                    'Pitch bloqueado a velocidad — el slider de tono '
                    'queda desactivado.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                ),
              SizedBox(height: tokens.gapSm),
              // ─────────── Lock toggle ───────────
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tono sigue a velocidad (chipmunk)'),
                subtitle: const Text(
                  'Subir velocidad sube el tono y viceversa, como una '
                  'cinta vieja. Default: tono independiente.',
                ),
                value: s.lockPitchToSpeed,
                onChanged: (v) =>
                    ctrl.update((p) => p.copyWith(lockPitchToSpeed: v)),
              ),
              SizedBox(height: tokens.gapSm),
              Divider(
                color: scheme.outlineVariant.withValues(alpha: 0.3),
                height: 1,
              ),
              SizedBox(height: tokens.gap),
              // ─────────── Sleep timer ───────────
              const _SleepTimerSection(),
              SizedBox(height: tokens.gapSm),
            ],
          ),
        ),
      ),
    );
  }

  /// Formato del label de velocidad. 1.0 → "1.0x", 1.25 → "1.25x". Forzamos
  /// 1 decimal mínimo para que "1x" y "1.5x" alineen visualmente con
  /// tabular figures.
  static String _fmtSpeed(double v) {
    if (v == v.roundToDouble()) return '${v.toStringAsFixed(1)}x';
    return '${v.toStringAsFixed(2)}x';
  }

  /// Semitonos: 0 → "±0", -3.5 → "−3.5 st", +5 → "+5 st". Signo explícito
  /// para que el usuario sepa la dirección sin tener que pensar.
  static String _fmtSemis(double v) {
    if (v == 0) return '±0 st';
    final sign = v > 0 ? '+' : '−';
    final abs = v.abs();
    final txt = abs == abs.roundToDouble()
        ? abs.toStringAsFixed(0)
        : abs.toStringAsFixed(1);
    return '$sign$txt st';
  }
}

/// Helper para mostrar el pill de "modificado" cuando algún param no es
/// neutral. Conviene para el indicador en el player_screen.
bool playbackParamsAreModified({
  required double speed,
  required double pitchSemitones,
}) {
  return speed != 1.0 || pitchSemitones != 0.0;
}

/// Texto compacto para el pill (ej: "1.25x · +2 st"). Si solo uno está
/// modificado, muestra solo ese.
String playbackParamsPillText({
  required double speed,
  required double pitchSemitones,
}) {
  final speedTxt = speed == 1.0 ? '' : '${speed.toStringAsFixed(2)}x';
  String pitchTxt = '';
  if (pitchSemitones != 0) {
    final sign = pitchSemitones > 0 ? '+' : '−';
    final abs = pitchSemitones.abs();
    final n = abs == abs.roundToDouble()
        ? abs.toStringAsFixed(0)
        : abs.toStringAsFixed(1);
    pitchTxt = '$sign$n st';
  }
  if (speedTxt.isEmpty) return pitchTxt;
  if (pitchTxt.isEmpty) return speedTxt;
  return '$speedTxt · $pitchTxt';
}

/// Sección de sleep timer dentro del sheet de velocidad/tono. El estado
/// vive en [PlaybackController] (sobrevive a cerrar el sheet); aquí solo
/// se muestra y se controla.
class _SleepTimerSection extends StatelessWidget {
  const _SleepTimerSection();

  @override
  Widget build(BuildContext context) {
    final pb = context.watch<PlaybackController>();
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    final deadline = pb.sleepDeadline;
    String? statusText;
    if (pb.sleepAtTrackEnd) {
      statusText = 'Se pausará al terminar esta canción.';
    } else if (deadline != null) {
      final hhmm = TimeOfDay.fromDateTime(deadline).format(context);
      statusText = 'Se pausará a las $hhmm.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.bedtime_rounded,
              size: 22,
              color: pb.sleepTimerActive
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.8),
            ),
            SizedBox(width: tokens.gapSm),
            Text('Temporizador de apagado',
                style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            if (pb.sleepTimerActive)
              TextButton(
                onPressed: pb.cancelSleepTimer,
                child: const Text('Cancelar'),
              ),
          ],
        ),
        if (statusText != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              statusText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                  ),
            ),
          ),
        SizedBox(height: tokens.gapSm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final min in const [15, 30, 45, 60])
              ActionChip(
                label: Text('$min min'),
                onPressed: () =>
                    pb.startSleepTimer(Duration(minutes: min)),
              ),
            ActionChip(
              label: const Text('Fin de canción'),
              onPressed: pb.setSleepAtTrackEnd,
            ),
          ],
        ),
      ],
    );
  }
}
