import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../l10n/app_localizations.dart';
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
    final t = AppLocalizations.of(context);
    String audioLabel(MediaQuality q) => switch (q) {
          MediaQuality.low => t.qualityAudioLow,
          MediaQuality.medium => t.qualityAudioMedium,
          MediaQuality.high => t.qualityAudioHigh,
        };
    String videoLabel(MediaQuality q) => switch (q) {
          MediaQuality.low => t.qualityVideoLow,
          MediaQuality.medium => t.qualityVideoMedium,
          MediaQuality.high => t.qualityVideoHigh,
        };

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(t.settingsQualityTitle)),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          _Section(
            title: t.qualityAudioWifi,
            labelOf: audioLabel,
            value: s.audioQualityWifi,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(audioQualityWifi: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: t.qualityAudioCellular,
            labelOf: audioLabel,
            subtitle: t.qualityAudioCellularSubtitle,
            value: s.audioQualityCellular,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(audioQualityCellular: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: t.qualityVideoWifi,
            subtitle: t.qualityVideoWifiSubtitle,
            value: s.videoQualityWifi,
            labelOf: videoLabel,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(videoQualityWifi: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: t.qualityVideoCellular,
            subtitle: t.qualityVideoCellularSubtitle,
            value: s.videoQualityCellular,
            labelOf: videoLabel,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(videoQualityCellular: v)),
          ),
          SizedBox(height: tokens.gap),
          _Section(
            title: t.qualityDownloads,
            labelOf: audioLabel,
            subtitle: t.qualityDownloadsSubtitle,
            value: s.downloadQuality,
            onChanged: (v) =>
                ctrl.update((p) => p.copyWith(downloadQuality: v)),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(t.autoplayTitle),
              subtitle: Text(t.autoplaySubtitle),
              value: s.autoplayRelated,
              onChanged: (v) =>
                  ctrl.update((p) => p.copyWith(autoplayRelated: v)),
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(t.downloadAsMp3Title),
              subtitle: Text(t.downloadAsMp3Subtitle),
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
