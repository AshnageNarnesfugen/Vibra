import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../services/download_service.dart';
import 'song_context_sheet.dart';
import 'song_thumbnail.dart';

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.selected = false,
    this.onLongPress,
  });

  final Song song;
  final VoidCallback onTap;
  final bool selected;

  /// Override del long-press. Si es null, abrimos el menú de contexto
  /// estándar (guardar en playlist, descargar, ir al artista, etc.).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: tokens.radius,
      child: InkWell(
        borderRadius: tokens.radius,
        onTap: onTap,
        onLongPress: onLongPress ??
            () => showSongContextSheet(context, songs: [song]),
        child: Padding(
          padding: tokens.tilePadding(),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: tokens.radiusSm,
                child: SongThumbnail(song: song, size: 48),
              ),
              SizedBox(width: tokens.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: selected ? scheme.primary : null,
                          ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.65),
                          ),
                    ),
                  ],
                ),
              ),
              if (song.isStreaming)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Builder(builder: (ctx) {
                    // Icono que cambia con el estado de descarga:
                    //  - downloaded: check verde (offline ready).
                    //  - downloading: icono animado de descarga.
                    //  - otherwise: nube (streaming online).
                    final dl = ctx.watch<DownloadService?>();
                    if (dl != null && dl.isDownloaded(song.id)) {
                      return Icon(
                        Icons.download_done_rounded,
                        size: 16,
                        color: scheme.primary,
                      );
                    }
                    if (dl != null && dl.isDownloading(song.id)) {
                      return Icon(
                        Icons.downloading_rounded,
                        size: 16,
                        color: scheme.primary.withValues(alpha: 0.75),
                      );
                    }
                    return Icon(
                      Icons.cloud_outlined,
                      size: 16,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    );
                  }),
                ),
              if (song.durationMs != null)
                Text(
                  _fmt(song.duration),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                ),
              // Fallback de 3-dot: el long-press abre el mismo menú pero no
              // todos los usuarios saben mantener presionado, y en zonas con
              // scroll a veces "se come" el gesto. El botón explícito
              // garantiza acceso al menú de contexto siempre.
              SizedBox(width: tokens.gapSm),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: 'Más opciones',
                  color: scheme.onSurface.withValues(alpha: 0.65),
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () =>
                      showSongContextSheet(context, songs: [song]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
