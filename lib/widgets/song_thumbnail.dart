import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../core/image_format.dart';
import '../models/song.dart';

/// Thumbnail polimórfico para [Song]:
///   1. `inlineArtwork` (carpeta manual: bytes leídos de la metadata).
///   2. `thumbnailUrl` (streaming: URL HTTPS de la API InnerTube).
///   3. `id` numérico → `QueryArtworkWidget` (Android system query).
///   4. Placeholder.
///
/// **Importante para rendimiento:** usa `cacheWidth` para que Flutter decodifique
/// la imagen al tamaño de pantalla (no a tamaño full resolución). Esto reduce
/// drásticamente el coste de decodificación y memoria — clave en grilla con
/// muchos tiles.
class SongThumbnail extends StatelessWidget {
  const SongThumbnail({
    super.key,
    required this.song,
    this.size,
  });

  final Song song;
  final double? size;

  /// Cuánto pixel target — usamos 2x el tamaño lógico (hi-dpi) para que
  /// no se vea pixelado. Si el caller no pasó `size` (cover grande), no
  /// limitamos y dejamos resolución original.
  int? _cachePx(BuildContext context) {
    if (size == null) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (size! * dpr).round();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cw = _cachePx(context);
    Widget child;

    if (song.inlineArtwork != null &&
        isDecodableImage(song.inlineArtwork!)) {
      // Skip silenciosamente artwork en HEIC/AVIF (Impeller no los soporta
      // en Android). Sin esto, ImageDecoder spameaba "unimplemented" en
      // cada rebuild del grid → cientos de errors en logcat sin valor.
      child = Image.memory(
        song.inlineArtwork!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // Crítico para memoria: decodificamos al tamaño del tile, no full-res.
        cacheWidth: cw,
        filterQuality:
            (size ?? 64) >= 200 ? FilterQuality.medium : FilterQuality.low,
        errorBuilder: (_, _, _) => _placeholder(scheme),
      );
    } else if (song.thumbnailUrl != null && song.thumbnailUrl!.isNotEmpty) {
      // ASEGURAMOS PROTOCOLO HTTPS
      String url = song.thumbnailUrl!;
      if (url.startsWith('//')) url = 'https:$url';

      child = Image.network(
        url,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: cw,
        filterQuality:
            (size ?? 64) >= 200 ? FilterQuality.medium : FilterQuality.low,
        errorBuilder: (_, _, _) => _placeholder(scheme),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _placeholder(scheme);
        },
      );
    } else {
      final id = int.tryParse(song.id);
      child = id != null
          ? QueryArtworkWidget(
              id: id,
              type: ArtworkType.AUDIO,
              artworkBorder: BorderRadius.zero,
              nullArtworkWidget: _placeholder(scheme),
            )
          : _placeholder(scheme);
    }

    if (size == null) return child;
    return SizedBox(width: size, height: size, child: child);
  }

  /// Placeholder cuando no hay artwork. Llena todo el contenedor (sin esto
  /// el `ColoredBox` colapsaba al tamaño del Icon en algunos layouts —
  /// se veía un cuadrito gris pequeño en vez del fondo completo) y el
  /// icono escala con el tamaño disponible para no quedar minúsculo en
  /// tiles grandes ni gigante en miniaturas.
  Widget _placeholder(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          final maxSide = constraints.biggest.shortestSide;
          // Si el contenedor no tiene constraints válidas (raro pero
          // posible), caemos a un fallback fijo en lugar de NaN.
          final iconSize = maxSide.isFinite && maxSide > 0
              ? (maxSide * 0.40).clamp(20.0, 88.0)
              : 28.0;
          return Container(
            width: double.infinity,
            height: double.infinity,
            alignment: Alignment.center,
            color: scheme.surfaceContainerHighest,
            child: Icon(
              Icons.music_note_rounded,
              color: scheme.onSurface.withValues(alpha: 0.6),
              size: iconSize,
            ),
          );
        },
      );
}
