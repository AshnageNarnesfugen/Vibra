import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../services/streaming/streaming_service.dart';
import 'song_context_sheet.dart';

/// Sección horizontal del home estilo OpenTune / YouTube Music.
///
/// Tiene dos modos visuales según el contenido del shelf:
///   - **Carrusel** (por defecto): scroll horizontal con tarjetas cuadradas
///     grandes. Para álbumes, artistas, playlists y mezclas.
///   - **Compacto multi-columna**: para shelves tipo "Selección rápida" /
///     "Quick picks" — todos canciones, muchos items. Renderiza una grid
///     horizontal con N páginas de ~4 filas × 1 columna cada una, igual
///     que la web de YT Music que ahorra espacio vertical mostrando varias
///     canciones por slot.
///
/// Items reproducibles (kind == song) se manejan vía [onPlayItem]. Álbumes /
/// playlists / artistas el caller debe navegar al detail screen
/// correspondiente.
class HomeCarousel extends StatelessWidget {
  const HomeCarousel({
    super.key,
    required this.shelf,
    required this.onPlayItem,
    this.onShowAll,
  });

  final HomeShelf shelf;
  final void Function(ShelfItem item) onPlayItem;

  /// Si se provee, aparece un botón "Ver todo" junto al título del carrusel.
  /// Tap → el caller decide qué hacer (típicamente push de `ShelfFullScreen`).
  /// Solo se muestra cuando el shelf tiene suficientes items para que valga
  /// la pena una vista dedicada (>= 6).
  final VoidCallback? onShowAll;

  /// Detecta si el shelf debería usar el layout compacto (Quick Picks style).
  /// Heurística: todos los items son canciones Y hay al menos 5 — los carruseles
  /// "Mixed for you" suelen tener pocos items grandes; "Selección rápida"
  /// tiene 12-24 canciones que se ven mejor compactas.
  bool get _isCompactList {
    if (shelf.items.length < 5) return false;
    return shelf.items.every((i) => i.kind == ShelfItemKind.song);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.gapSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    shelf.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // "Ver todo": aparece si el caller lo proporciona Y hay
                // razón para una vista expandida — bien porque el shelf
                // tiene un endpoint "more" en YT (sabemos que hay más
                // items que descargar), bien porque ya tenemos >= 6
                // items que se ven mejor como grid que como carrusel.
                if (onShowAll != null &&
                    (shelf.moreBrowseId != null || shelf.items.length >= 6))
                  TextButton(
                    onPressed: onShowAll,
                    child: const Text('Ver todo'),
                  ),
              ],
            ),
          ),
          SizedBox(height: tokens.gapSm),
          if (_isCompactList)
            _CompactSongList(items: shelf.items, onPlayItem: onPlayItem)
          else
            SizedBox(
              height: 196,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
                itemCount: shelf.items.length,
                separatorBuilder: (_, _) => SizedBox(width: tokens.gap),
                itemBuilder: (context, i) => _CarouselCard(
                  item: shelf.items[i],
                  onTap: () => onPlayItem(shelf.items[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Layout estilo "Selección rápida" de YT Music: una grid horizontal donde
/// cada "página" contiene 4 canciones en columna. El usuario scrollea
/// horizontalmente para ver más páginas.
///
/// Cada fila: thumbnail 48px + 2 líneas de texto (título / artista).
class _CompactSongList extends StatelessWidget {
  const _CompactSongList({required this.items, required this.onPlayItem});

  final List<ShelfItem> items;
  final void Function(ShelfItem) onPlayItem;

  static const int _rowsPerPage = 4;
  static const double _rowHeight = 56;
  static const double _columnWidth = 320;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    // Agrupamos los items en "páginas" de _rowsPerPage cada una.
    final pageCount = (items.length / _rowsPerPage).ceil();

    // Row height TEXT-SCALE AWARE: el fijo de 56 truncaba las filas
    // cuando el font scale del sistema superaba ~1.3 (las dos líneas de
    // texto + padding exceden 56). Crecemos con el texto; 56 queda como
    // mínimo para mantener el look denso en scale 1.0.
    final textScaler = MediaQuery.textScalerOf(context);
    final textH = textScaler.scale(14) * 1.45 + textScaler.scale(12) * 1.4;
    final rowHeight =
        math.max(_rowHeight, textH + 12); // +12 = padding vertical interno.

    return SizedBox(
      height: _rowsPerPage * rowHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
        itemCount: pageCount,
        itemBuilder: (context, page) {
          final start = page * _rowsPerPage;
          final end = (start + _rowsPerPage).clamp(0, items.length);
          final pageItems = items.sublist(start, end);
          return SizedBox(
            width: _columnWidth,
            child: Column(
              children: pageItems.map((item) {
                return SizedBox(
                  height: rowHeight,
                  child: _CompactRow(
                    item: item,
                    onTap: () => onPlayItem(item),
                  ),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}

class _CompactRow extends StatelessWidget {
  const _CompactRow({required this.item, required this.onTap});

  final ShelfItem item;
  final VoidCallback onTap;

  Song _itemAsSong() => Song(
        id: item.streamingId != null ? 'yt:${item.streamingId}' : item.id,
        title: item.title,
        artist: item.subtitle,
        album: '—',
        uri: item.streamingId != null
            ? 'ytmusic://${item.streamingId}'
            : item.id,
        streamingId: item.streamingId,
        thumbnailUrl: item.thumbnailUrl,
        artistBrowseId: item.artistBrowseId,
        albumBrowseId: item.albumBrowseId,
      );

  void _openContextSheet(BuildContext context) {
    if (item.kind != ShelfItemKind.song) return;
    showSongContextSheet(context, songs: [_itemAsSong()]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      onLongPress: () => _openContextSheet(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: _Thumbnail(item: item, scheme: scheme),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  if (item.subtitle.isNotEmpty)
                    // Texto plano (sin underline / sin click). El artista se
                    // visita desde el menú de contexto (long-press / 3-dot →
                    // "Ir al artista") o entrando al PlayerScreen — el
                    // subtitle aquí no debe interceptar el tap del row, o
                    // tocar la fila abriría artista en vez de reproducir.
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                scheme.onSurface.withValues(alpha: 0.6),
                          ),
                    ),
                ],
              ),
            ),
            // Botón 3-dot — siempre disponible para canciones; el long-press
            // a veces se "come" en zonas con scroll.
            if (item.kind == ShelfItemKind.song)
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: 'Más opciones',
                  color: scheme.onSurface.withValues(alpha: 0.6),
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () => _openContextSheet(context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CarouselCard extends StatelessWidget {
  const _CarouselCard({required this.item, required this.onTap});

  final ShelfItem item;
  final VoidCallback onTap;

  Song _itemAsSong() => Song(
        id: item.streamingId != null ? 'yt:${item.streamingId}' : item.id,
        title: item.title,
        artist: item.subtitle,
        album: '—',
        uri: item.streamingId != null
            ? 'ytmusic://${item.streamingId}'
            : item.id,
        streamingId: item.streamingId,
        thumbnailUrl: item.thumbnailUrl,
        artistBrowseId: item.artistBrowseId,
        albumBrowseId: item.albumBrowseId,
      );

  void _openContextSheet(BuildContext context) {
    if (item.kind != ShelfItemKind.song) return;
    showSongContextSheet(context, songs: [_itemAsSong()]);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    final isCircular = item.kind == ShelfItemKind.artist;
    // Album/playlist usan radio cuadrado-redondeado; artista circular.
    final radius = isCircular
        ? BorderRadius.circular(72)
        : tokens.radius;

    return SizedBox(
      width: 140,
      child: InkWell(
        borderRadius: tokens.radius,
        onTap: onTap,
        onLongPress: () => _openContextSheet(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail FLEXIBLE: toma el alto que sobre tras los textos.
            // Con altura fija de 140, los textos escalados por font scale
            // de accesibilidad (≥1.5) excedían el contenedor de 196 del
            // carrusel → overflow stripes. Expanded deja que la imagen
            // ceda — el texto siempre se ve completo.
            Expanded(
              child: SizedBox(
                width: 140,
                child: ClipRRect(
                  borderRadius: radius,
                  child: _Thumbnail(item: item, scheme: scheme),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
            ),
            if (item.subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.item, required this.scheme});
  final ShelfItem item;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    if (item.thumbnailUrl.isNotEmpty) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final cacheSide = (160 * dpr).round();
      return Image.network(
        item.thumbnailUrl,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: cacheSide,
        cacheHeight: cacheSide,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => _placeholder(),
        loadingBuilder: (_, c, p) => p == null ? c : _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Icon(
          switch (item.kind) {
            ShelfItemKind.song => Icons.music_note_rounded,
            ShelfItemKind.album => Icons.album_rounded,
            ShelfItemKind.playlist => Icons.queue_music_rounded,
            ShelfItemKind.artist => Icons.person_rounded,
          },
          size: 32,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
      );
}
