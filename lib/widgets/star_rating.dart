import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/ratings_service.dart';
import 'glass_card.dart';

/// Fila de 5 estrellas con soporte de MEDIA estrella (escala 0.5–5.0,
/// estilo RateYourMusic). En modo interactivo, tap/drag sobre la mitad
/// izquierda de una estrella da la media, sobre la derecha la entera.
class StarRatingBar extends StatelessWidget {
  const StarRatingBar({
    super.key,
    required this.rating,
    this.size = 28,
    this.onChanged,
    this.color,
  });

  /// 0 = sin calificar.
  final double rating;
  final double size;
  final ValueChanged<double>? onChanged;
  final Color? color;

  void _handle(Offset localPos, double totalWidth) {
    if (onChanged == null) return;
    // Posición 0..1 sobre la fila → rating 0.5..5.0 en medios.
    final f = (localPos.dx / totalWidth).clamp(0.001, 1.0);
    final r = (f * 10).ceil() / 2;
    onChanged!(r.clamp(0.5, 5.0));
  }

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            rating >= i
                ? Icons.star_rounded
                : (rating >= i - 0.5
                    ? Icons.star_half_rounded
                    : Icons.star_outline_rounded),
            size: size,
            color: rating >= i - 0.5 ? c : dim,
          ),
      ],
    );
    if (onChanged == null) return row;
    final totalWidth = size * 5;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _handle(d.localPosition, totalWidth),
      onHorizontalDragUpdate: (d) => _handle(d.localPosition, totalWidth),
      child: SizedBox(width: totalWidth, child: row),
    );
  }
}

/// Sheet de calificación de [song]: estrellas grandes interactivas +
/// quitar calificación. Los cambios se guardan al instante en
/// [RatingsService].
Future<void> showRatingSheet(BuildContext context, Song song) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (ctx) => _RatingSheet(song: song),
  );
}

class _RatingSheet extends StatelessWidget {
  const _RatingSheet({required this.song});
  final Song song;

  @override
  Widget build(BuildContext context) {
    final ratings = context.watch<RatingsService?>();
    final rating = ratings?.ratingOf(song.id) ?? 0.0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              StarRatingBar(
                rating: rating,
                size: 44,
                onChanged: ratings == null
                    ? null
                    : (v) => ratings.rate(song, v),
              ),
              const SizedBox(height: 8),
              Text(
                rating > 0 ? rating.toStringAsFixed(1) : '—',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (rating > 0)
                    TextButton.icon(
                      onPressed: () {
                        final nav = Navigator.of(context);
                        // ignore: discarded_futures
                        ratings?.unrate(song.id);
                        nav.pop();
                      },
                      icon: const Icon(Icons.star_outline_rounded, size: 18),
                      label: const Text('Quitar calificación'),
                    )
                  else
                    const SizedBox.shrink(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Listo'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

}
