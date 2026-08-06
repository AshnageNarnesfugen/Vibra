import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/layout_tokens.dart';
import '../services/app_storage.dart';
import '../services/ratings_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/song_thumbnail.dart';
import '../widgets/star_rating.dart';
import '../widgets/stable_backdrop_group.dart';

enum _RatingsSort { recent, best, worst }

/// Sección dedicada de calificaciones: todo lo que el usuario ha
/// calificado, con orden por fecha/rating, resumen (promedio + histograma)
/// y export a CSV. Tap en una fila reabre el sheet de estrellas.
class RatingsScreen extends StatefulWidget {
  const RatingsScreen({super.key});

  @override
  State<RatingsScreen> createState() => _RatingsScreenState();
}

class _RatingsScreenState extends State<RatingsScreen> {
  _RatingsSort _sort = _RatingsSort.recent;

  Future<void> _exportCsv(RatingsService ratings) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = AppStorage.isInitialized
          ? AppStorage.instance.musicDir
          : Directory.systemTemp.path;
      final path = '$dir/vibra-calificaciones.csv';
      await File(path).writeAsString(ratings.toCsv());
      if (AppStorage.isInitialized) {
        // ignore: discarded_futures
        AppStorage.instance.scanFile(path);
      }
      messenger.showSnackBar(SnackBar(
        content: Text('CSV exportado a $path'),
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Export falló: $e'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final ratings = context.watch<RatingsService?>();

    if (ratings == null) {
      return StableBackdropGroup(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Calificaciones')),
          body: const Center(child: Text('Servicio no disponible.')),
        ),
      );
    }

    final list = ratings.all;
    switch (_sort) {
      case _RatingsSort.recent:
        break; // ya viene por fecha desc
      case _RatingsSort.best:
        list.sort((a, b) => b.rating.compareTo(a.rating));
      case _RatingsSort.worst:
        list.sort((a, b) => a.rating.compareTo(b.rating));
    }

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Calificaciones'),
          actions: [
            PopupMenuButton<_RatingsSort>(
              tooltip: 'Ordenar',
              icon: const Icon(Icons.sort_rounded),
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: _RatingsSort.recent, child: Text('Recientes')),
                PopupMenuItem(
                    value: _RatingsSort.best, child: Text('Mejor calificadas')),
                PopupMenuItem(
                    value: _RatingsSort.worst, child: Text('Peor calificadas')),
              ],
            ),
            if (ratings.count > 0)
              IconButton(
                tooltip: 'Exportar CSV',
                icon: const Icon(Icons.ios_share_rounded),
                onPressed: () => _exportCsv(ratings),
              ),
          ],
        ),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            // ─── Resumen ───
            GlassCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${ratings.count} canciones calificadas',
                            style: Theme.of(context).textTheme.titleMedium),
                        if (ratings.average != null) ...[
                          SizedBox(height: tokens.gapSm),
                          Row(
                            children: [
                              StarRatingBar(
                                  rating: ratings.average!, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'promedio ${ratings.average!.toStringAsFixed(2)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),
            if (list.isEmpty)
              GlassCard(
                child: Text(
                  'Todavía no calificas nada. Mantén presionada una canción '
                  '(o el botón ⋮) → "Calificar" para darle estrellas.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          color: Theme.of(context)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.3),
                        ),
                      _RatingRow(entry: list[i]),
                    ],
                  ],
                ),
              ),
            SizedBox(
              height: 200 + MediaQuery.viewPaddingOf(context).bottom,
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.entry});
  final SongRating entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => showRatingSheet(context, entry.song),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SongThumbnail(song: entry.song, size: 44),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(entry.song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.65),
                      )),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                StarRatingBar(rating: entry.rating, size: 16),
                Text(
                  entry.rating.toStringAsFixed(1),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
