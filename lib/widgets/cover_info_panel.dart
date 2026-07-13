import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/settings/ui_settings.dart';
import '../models/song.dart';
import '../providers/playback_controller.dart';
import '../services/audio_metadata.dart';
import 'playback_params_sheet.dart';

/// Panel con toda la info técnica + metadata + estado de la canción actual.
///
/// Diseñado para servir en dos contenedores distintos:
///   - **Back side de la carátula cuadrada** (card flip animation)
///   - **Bottom sheet** (para CD / holográfico — sheet desde abajo)
///
/// Mismo contenido en ambos modos; el contenedor cambia el padding y la
/// presencia del botón X. La lista es scrollable internamente, así si la
/// carátula es chica (queue expandido en portrait) el panel sigue
/// usable — solo aparece scroll vertical.
///
/// Reemplaza la fila de `_PlayerInfoChips` que vivía debajo del título —
/// el usuario nos dijo que se amontonaban en vertical y empujaban el
/// resto del UI. Mover la info al back del cover libera ese espacio.
class CoverInfoPanel extends StatelessWidget {
  const CoverInfoPanel({
    super.key,
    required this.song,
    required this.compact,
    this.onDismiss,
  });

  /// Canción a describir. La info de formato se lee del provider.
  final Song song;

  /// True cuando el panel vive DENTRO de la carátula (flip back). Reduce
  /// padding y tamaños de fuente para encajar en el cuadrado.
  final bool compact;

  /// Si no es null, dibuja un IconButton X en la esquina superior derecha.
  /// Solo en modo bottom sheet — el flip back se cierra con el mismo swipe.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pb = context.read<PlaybackController>();

    final pad = compact ? 14.0 : 20.0;
    final titleFs = compact ? 13.0 : 16.0;
    final labelFs = compact ? 10.0 : 11.0;
    final valueFs = compact ? 12.0 : 14.0;

    return ValueListenableBuilder<AudioFormatInfo?>(
      valueListenable: pb.currentFormat,
      builder: (context, format, _) {
        return ListView(
          padding: EdgeInsets.fromLTRB(pad, pad, pad, pad + 8),
          children: [
            // ─────────── Header (X opcional + título) ───────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Información',
                        style: TextStyle(
                          fontSize: labelFs,
                          color: scheme.onSurface.withValues(alpha: 0.55),
                          letterSpacing: 0.6,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.title,
                        style: TextStyle(
                          fontSize: titleFs,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        style: TextStyle(
                          fontSize: valueFs - 1,
                          color: scheme.onSurface.withValues(alpha: 0.72),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (onDismiss != null)
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onDismiss,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            SizedBox(height: pad),

            // ─────────── Calidad de audio ───────────
            if (format != null) ...[
              _SectionLabel('Calidad', fontSize: labelFs),
              if (format.isHiRes) ...[
                const SizedBox(height: 6),
                _HiResBadge(compact: compact),
              ],
              const SizedBox(height: 8),
              _PropGrid(
                fontSize: valueFs,
                labelFontSize: labelFs,
                rows: [
                  ('Códec', format.codec),
                  if (format.bitDepth != null)
                    ('Profundidad', '${format.bitDepth}-bit'),
                  if (format.sampleRateHz != null)
                    ('Frecuencia', _fmtFreq(format.sampleRateHz!)),
                  if (format.channels != null)
                    ('Canales', _fmtChannels(format.channels!)),
                  if (format.bitrateBps != null)
                    ('Bitrate', '${(format.bitrateBps! / 1000).round()} kbps'),
                ],
              ),
              SizedBox(height: pad),
            ] else if (song.isStreaming) ...[
              _SectionLabel('Calidad', fontSize: labelFs),
              const SizedBox(height: 6),
              Text(
                'Streaming desde YouTube Music — sin metadata de formato '
                'disponible hasta resolver el stream.',
                style: TextStyle(
                  fontSize: valueFs - 1,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              SizedBox(height: pad),
            ],

            // ─────────── Reproducción (params activos) ───────────
            _SectionLabel('Reproducción', fontSize: labelFs),
            const SizedBox(height: 8),
            _PlaybackParamsRow(fontSize: valueFs),
            SizedBox(height: pad),

            // ─────────── Pista (metadata genérica) ───────────
            _SectionLabel('Pista', fontSize: labelFs),
            const SizedBox(height: 8),
            _PropGrid(
              fontSize: valueFs,
              labelFontSize: labelFs,
              rows: [
                if (song.album.isNotEmpty) ('Álbum', song.album),
                if (song.durationMs != null && song.durationMs! > 0)
                  ('Duración', _fmtDuration(song.durationMs!)),
                if (song.isStreaming)
                  ('Fuente', 'YouTube Music')
                else
                  ('Archivo', _fmtFilePath(song.uri)),
              ],
            ),
          ],
        );
      },
    );
  }

  // ── Helpers de formato ──

  static String _fmtFreq(int hz) {
    final khz = hz / 1000;
    return (khz * 10).round() % 10 == 0
        ? '${khz.round()} kHz'
        : '${khz.toStringAsFixed(1)} kHz';
  }

  static String _fmtChannels(int ch) {
    switch (ch) {
      case 1:
        return 'Mono';
      case 2:
        return 'Estéreo';
      case 6:
        return '5.1';
      case 8:
        return '7.1';
      default:
        return '$ch ch';
    }
  }

  static String _fmtDuration(int ms) {
    final s = ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:'
          '${sec.toString().padLeft(2, '0')}';
    }
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  /// Trunca paths largos al `…/last2segments` para que no rompa el grid.
  static String _fmtFilePath(String uri) {
    final segs = uri.split('/');
    if (segs.length <= 3) return uri;
    return '…/${segs.sublist(segs.length - 2).join('/')}';
  }
}

// ───────────────────── Subwidgets ─────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.fontSize});
  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: fontSize,
        color: scheme.primary,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _PropGrid extends StatelessWidget {
  const _PropGrid({
    required this.rows,
    required this.fontSize,
    required this.labelFontSize,
  });

  /// Tuples (label, value). Se renderizan en dos columnas si caben, una
  /// si el panel es muy angosto.
  final List<(String, String)> rows;
  final double fontSize;
  final double labelFontSize;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (ctx, c) {
      // Si el panel es angosto (flip back de cover chico), una columna.
      final twoCols = c.maxWidth >= 260;
      final children = rows.map((r) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.$1,
                style: TextStyle(
                  fontSize: labelFontSize,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                r.$2,
                style: TextStyle(
                  fontSize: fontSize,
                  color: scheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      }).toList();

      if (!twoCols) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      }
      // Dos columnas vía Wrap (paginado por width).
      return Wrap(
        spacing: 14,
        runSpacing: 0,
        children: children
            .map((w) => SizedBox(width: (c.maxWidth - 14) / 2, child: w))
            .toList(),
      );
    });
  }
}

/// Badge "Hi-Res Audio" — dorado JAS. Mismo look que el chip mini de
/// abajo del título pero más grande para destacar dentro del panel.
class _HiResBadge extends StatelessWidget {
  const _HiResBadge({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const gold = Color(0xFFFFB84D);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 5 : 7,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            gold.withValues(alpha: 0.28),
            gold.withValues(alpha: 0.18),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: gold.withValues(alpha: 0.65)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.high_quality_rounded,
              size: compact ? 14 : 18, color: gold),
          SizedBox(width: compact ? 6 : 8),
          Text(
            'Hi-Res Audio',
            style: TextStyle(
              fontSize: compact ? 11 : 13,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Resumen de los params de reproducción (speed/pitch + bit-perfect)
/// con un botón "Ajustar" que abre el sheet de speed/pitch.
class _PlaybackParamsRow extends StatelessWidget {
  const _PlaybackParamsRow({required this.fontSize});
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final s = UiSettingsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final modified = playbackParamsAreModified(
      speed: s.playbackSpeed,
      pitchSemitones: s.playbackPitchSemitones,
    );
    final bitPerfect = s.bitPerfectModeEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Velocidad + tono
        Row(
          children: [
            Icon(Icons.speed_rounded,
                size: 16,
                color: modified
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.55)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                modified
                    ? 'Velocidad/tono modificados: '
                        '${playbackParamsPillText(
                            speed: s.playbackSpeed,
                            pitchSemitones: s.playbackPitchSemitones,
                          )}'
                    : 'Velocidad y tono en neutral (1.0x · ±0 st)',
                style: TextStyle(
                  fontSize: fontSize - 1,
                  color: scheme.onSurface,
                ),
              ),
            ),
            TextButton(
              onPressed: () => showPlaybackParamsSheet(context),
              child: const Text('Ajustar'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Bit-perfect
        Row(
          children: [
            Icon(Icons.high_quality_rounded,
                size: 16,
                color: bitPerfect
                    ? scheme.tertiary
                    : scheme.onSurface.withValues(alpha: 0.55)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                bitPerfect
                    ? 'Modo bit-perfect ACTIVO — EQ y fades '
                        'desactivados'
                    : 'Modo bit-perfect inactivo (señal pasa por EQ '
                        'y fades)',
                style: TextStyle(
                  fontSize: fontSize - 1,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
