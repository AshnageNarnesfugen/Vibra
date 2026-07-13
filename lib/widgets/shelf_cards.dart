import 'package:flutter/material.dart';

import '../core/theme/layout_tokens.dart';
import '../services/streaming/streaming_service.dart';

/// Header de una sección de resultados/shelf con título y enlace opcional
/// "Ver todo".
class ShelfSectionTitle extends StatelessWidget {
  const ShelfSectionTitle({super.key, required this.label, this.onShowAll});
  final String label;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    return SliverPadding(
      padding:
          EdgeInsets.fromLTRB(tokens.space(20), 16, tokens.space(20), 8),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (onShowAll != null)
              TextButton(onPressed: onShowAll, child: const Text('Ver todo')),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta compacta para un item de shelf (álbum/playlist/single). Usada en
/// carruseles horizontales de búsqueda y home.
class SmallShelfCard extends StatelessWidget {
  const SmallShelfCard({super.key, required this.item, required this.onTap});
  final ShelfItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    return SizedBox(
      width: 140,
      child: InkWell(
        onTap: onTap,
        borderRadius: tokens.radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Imagen FLEXIBLE (no fija de 140): cede altura cuando el
            // texto crece por font scale de accesibilidad. Con la
            // altura fija, font scale ≥1.5 desbordaba el contenedor del
            // carrusel y el card aparecía truncado con stripes de
            // overflow. La imagen mantiene su recorte cover dentro del
            // espacio que quede.
            Expanded(
              child: SizedBox(
                width: 140,
                child: ClipRRect(
                  borderRadius: tokens.radius,
                  child: Image.network(
                    item.thumbnailUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 280,
                    cacheHeight: 280,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Colors.black12,
                      child: Icon(Icons.album),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold)),
            Text(item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                )),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta redonda para un artista (avatar circular + nombre).
class SmallArtistCard extends StatelessWidget {
  const SmallArtistCard({super.key, required this.item, required this.onTap});
  final ShelfItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(50),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(50),
              child: Image.network(
                item.thumbnailUrl,
                width: 80,
                height: 80,
                fit: BoxFit.cover,
                cacheWidth: 160,
                cacheHeight: 160,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: Colors.black12,
                  child: Icon(Icons.person),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
