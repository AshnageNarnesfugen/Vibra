import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../services/network_quality_resolver.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

/// Configuración de calidad/bitrate de stream y descarga, dividido por
/// tipo de red (WiFi vs datos móviles) — porque la mayoría de usuarios
/// quiere alta fidelidad en WiFi pero ahorrar plan en celular. Las
/// descargas tienen su propio nivel (no depende del tipo de red al
/// momento de descargar; el archivo se queda offline).
class QualitySettingsScreen extends StatelessWidget {
  const QualitySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Calidad de audio y video')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          _Section(
            title: 'Audio en WiFi',
            value: s.audioQualityWifi,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(audioQualityWifi: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: 'Audio en datos móviles',
            subtitle:
                'Por defecto media para no quemar el plan. Sube a alta '
                'si tienes datos ilimitados.',
            value: s.audioQualityCellular,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(audioQualityCellular: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: 'Video en WiFi',
            subtitle:
                'Resolución de imagen del music video. El cambio aplica '
                'al siguiente video que cargue.',
            value: s.videoQualityWifi,
            labelOf: (q) => q.videoLabel,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(videoQualityWifi: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: 'Video en datos móviles',
            subtitle:
                'Default baja — 5 minutos de music video en 720p+ '
                'consumen ~100MB.',
            value: s.videoQualityCellular,
            labelOf: (q) => q.videoLabel,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(videoQualityCellular: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: 'Calidad de descargas',
            subtitle:
                'Se aplica a las canciones descargadas para reproducir '
                'offline. Los archivos quedan en el dispositivo.',
            value: s.downloadQuality,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(downloadQuality: v)),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Descargar como MP3'),
              subtitle: const Text(
                'Convierte la descarga a MP3 256 kbps con metadata '
                'incrustada (título, artista, álbum y carátula) — máxima '
                'compatibilidad con otras apps y dispositivos. La '
                'conversión tarda ~1-2 min por canción. Desactivado: se '
                'guarda el stream original (m4a/opus), más rápido y sin '
                're-compresión.',
              ),
              value: s.downloadAsMp3,
              onChanged: (v) =>
                  ctrl.update((p) => p.copyWith(downloadAsMp3: v)),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.labelOf,
  });

  final String title;
  final String? subtitle;
  final MediaQuality value;
  final ValueChanged<MediaQuality> onChanged;

  /// Label por opción — default el de audio (kbps). Los selectores de
  /// video pasan `videoLabel` (resolución en p).
  final String Function(MediaQuality)? labelOf;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            SizedBox(height: tokens.gapSm),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          SizedBox(height: tokens.gapSm),
          RadioGroup<MediaQuality>(
            groupValue: value,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            child: Column(
              children: [
                for (final q in MediaQuality.values)
                  RadioListTile<MediaQuality>(
                    contentPadding: EdgeInsets.zero,
                    value: q,
                    title: Text(labelOf?.call(q) ?? q.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
