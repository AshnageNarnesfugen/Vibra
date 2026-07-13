import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import 'song_tile.dart';

/// Grilla responsive de canciones. Calcula columnas dinámicamente:
///   columns = floor(anchoDisponible / minTileWidth)  → al menos 1.
///
/// Usa [SliverGridDelegateWithMaxCrossAxisExtent] de modo que el ajuste sea
/// fluido al rotar el dispositivo o cambiar el split-view sin que el layout
/// "salte" de bruces.
class ResponsiveSongSliverGrid extends StatelessWidget {
  const ResponsiveSongSliverGrid({
    super.key,
    required this.songs,
    required this.minTileWidth,
    required this.selectedSongId,
    required this.onTap,
  });

  final List<Song> songs;
  final double minTileWidth;
  final String? selectedSongId;
  final void Function(Song song, int index) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    // Altura del tile DINÁMICA, no constante. El extent fijo de 72px
    // truncaba los tiles cuando:
    //   a) el usuario subía el slider de "Espaciado" en ajustes —
    //      `tilePadding()` escala con spacingScale y a 1.5x el padding
    //      vertical solo ya consume 30px;
    //   b) el font scale de accesibilidad del sistema es >1.2 — las dos
    //      líneas de texto superan los 48px del thumbnail y la Row crece.
    // Computamos el alto real: max(thumbnail, texto escalado) + padding.
    final textScaler = MediaQuery.textScalerOf(context);
    final theme = Theme.of(context).textTheme;
    double lineHeight(TextStyle? s, double fallbackSize, double fallbackH) {
      final size = s?.fontSize ?? fallbackSize;
      final h = s?.height ?? fallbackH;
      return textScaler.scale(size) * h;
    }

    // Las dos líneas del SongTile: titleSmall + bodySmall. Los fallbacks
    // de height (1.45/1.4) corresponden a los line-heights efectivos de
    // Material 3 cuando TextStyle.height viene null del theme.
    final textH = lineHeight(theme.titleSmall, 14, 1.45) +
        lineHeight(theme.bodySmall, 12, 1.4);
    const thumbH = 48.0; // SongThumbnail(size: 48) del SongTile.
    final contentH = math.max(thumbH, textH);
    final extent = (contentH + tokens.tilePadding().vertical).ceilToDouble();

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
      sliver: SliverGrid.builder(
        itemCount: songs.length,
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: minTileWidth.clamp(220.0, 720.0),
          mainAxisExtent: extent,
          crossAxisSpacing: tokens.gapSm,
          mainAxisSpacing: 4,
        ),
        itemBuilder: (context, i) {
          final song = songs[i];
          return SongTile(
            song: song,
            selected: selectedSongId == song.id,
            onTap: () => onTap(song, i),
          );
        },
      ),
    );
  }
}
