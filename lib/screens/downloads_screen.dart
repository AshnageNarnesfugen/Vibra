import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../services/download_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/song_thumbnail.dart';
import '../widgets/stable_backdrop_group.dart';

/// Cola de descargas: muestra la descarga activa (con progreso), las
/// pendientes en orden, y las ya completadas. Permite cancelar
/// individualmente o toda la cola.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final dl = context.watch<DownloadService?>();

    if (dl == null) {
      return StableBackdropGroup(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Descargas')),
          body: const Center(
            child: Text('El servicio de descargas no está disponible.'),
          ),
        ),
      );
    }

    final active = dl.activeDownload;
    final queued = dl.queuedDownloads;
    final done = dl.downloaded;
    final hasPending = active != null || queued.isNotEmpty;

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Descargas'),
          actions: [
            if (hasPending)
              TextButton.icon(
                onPressed: () => dl.cancelAll(),
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('Cancelar todo'),
              ),
          ],
        ),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            // ─────────── En curso + pendientes ───────────
            if (hasPending) ...[
              _SectionLabel('En cola · ${dl.pendingCount}'),
              SizedBox(height: tokens.gapSm),
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    if (active != null)
                      _DownloadRow(
                        song: active,
                        progress: dl.progressOf(active.id),
                        isActive: true,
                        onCancel: () => dl.cancel(active.id),
                      ),
                    for (var i = 0; i < queued.length; i++) ...[
                      if (i > 0 || active != null)
                        Divider(
                          height: 1,
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                        ),
                      _DownloadRow(
                        song: queued[i],
                        progress: null,
                        isActive: false,
                        queuePosition: i + 1,
                        onCancel: () => dl.cancel(queued[i].id),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(height: tokens.gap),
            ] else ...[
              GlassCard(
                child: Row(
                  children: [
                    Icon(Icons.cloud_done_rounded,
                        color: Theme.of(context).colorScheme.primary),
                    SizedBox(width: tokens.gap),
                    const Expanded(
                      child: Text('No hay descargas en cola.'),
                    ),
                  ],
                ),
              ),
              SizedBox(height: tokens.gap),
            ],

            // ─────────── Completadas ───────────
            _SectionLabel('Descargadas · ${done.length}'),
            SizedBox(height: tokens.gapSm),
            if (done.isEmpty)
              GlassCard(
                child: Text(
                  'Todavía no descargaste ninguna canción. Usa "Descargar" '
                  'en el menú de una canción de streaming.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < done.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                        ),
                      _DownloadedRow(
                        song: done[i],
                        onDelete: () => dl.delete(done[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            // Spacer final para que el último ítem libre la bottom bar +
            // mini player (flotan ENCIMA del contenido de la tab) — mismo
            // patrón que album/artist/playlist screens. Sin esto el scroll
            // quedaba truncado: las últimas filas eran inalcanzables.
            SizedBox(
              height: 200 + MediaQuery.viewPaddingOf(context).bottom,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
        color: scheme.primary,
      ),
    );
  }
}

/// Fila de una descarga en cola (activa con barra de progreso, o pendiente).
class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.song,
    required this.progress,
    required this.isActive,
    required this.onCancel,
    this.queuePosition,
  });

  final Song song;
  final double? progress;
  final bool isActive;
  final int? queuePosition;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // progress 0.99 = fase de transcode MP3 (el encode tarda). Lo
    // señalamos con texto en vez de dejar la barra "colgada" en 99%.
    final transcoding = isActive && progress != null && progress! >= 0.99;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SongThumbnail(song: song, size: 44),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                Text(song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.65),
                    )),
                const SizedBox(height: 6),
                if (isActive)
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: transcoding ? null : progress,
                            minHeight: 4,
                            backgroundColor:
                                scheme.onSurface.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        transcoding
                            ? 'Convirtiendo…'
                            : '${((progress ?? 0) * 100).round()}%',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    'En espera · #${queuePosition ?? '?'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Cancelar',
            visualDensity: VisualDensity.compact,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Fila de una descarga ya completada, con opción de borrar.
class _DownloadedRow extends StatelessWidget {
  const _DownloadedRow({required this.song, required this.onDelete});
  final Song song;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SongThumbnail(song: song, size: 44),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Icon(Icons.download_done_rounded,
                        size: 13, color: scheme.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.65),
                          )),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Borrar descarga',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
