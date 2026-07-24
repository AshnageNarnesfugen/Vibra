// Layout horizontal/ancho: split cover | cola + overlay de lyrics.
//
// `part` de player_screen.dart: las clases del player comparten
// estado privado entre sí, así que viven en una sola librería
// partida en archivos por concern (imports en el archivo raíz).
part of '../player_screen.dart';

class _SplitLayout extends StatelessWidget {
  const _SplitLayout({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showLyrics = context.select<LyricsController, bool>(
      (c) => c.showLyrics,
    );
    return Row(
      children: [
        // Player ocupa ~45% — el cover suele ser cuadrado y necesita altura.
        Expanded(
          flex: 45,
          child: _PlayerPanel(playback: playback),
        ),
        Container(
          width: 0.5,
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
        // Panel derecho: alterna entre cola y letra. AnimatedSwitcher
        // hace un fade suave en vez del salto duro.
        Expanded(
          flex: 55,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: showLyrics
                ? const Padding(
                    key: ValueKey('lyrics-panel-wide'),
                    padding: EdgeInsets.all(12),
                    child: LyricsPanel(),
                  )
                : _QueuePanel(
                    key: const ValueKey('queue-panel-wide'),
                    playback: playback,
                  ),
          ),
        ),
      ],
    );
  }
}

class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final song = playback.currentSong!;
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);

    // Cover con toggle Cover ↔ Video — gestionado por
    // VideoAvailabilityController. Si la canción no tiene video o el
    // toggle está OFF, muestra SongThumbnail clásico.
    // RepaintBoundary aísla el coste de repintado del video/imagen del
    // resto del player (transport controls, scrubber, etc.).
    // Layout horizontal: el botón de fullscreen va arriba-izquierda para
    // no quedar tapado por la _HorizontalControlsCard del fondo.
    final cover = RepaintBoundary(
      child: _CoverWithVideoToggle(
        song: song,
        fullscreenButtonAtTopLeft: true,
      ),
    );

    final title = GestureDetector(
      onLongPress: () => showSongContextSheet(context, songs: [song]),
      child: MarqueeText(
        song.title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );

    final artistStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: scheme.onSurface.withValues(alpha: 0.7),
          decoration:
              song.artistBrowseId != null ? TextDecoration.underline : null,
        );
    final artist = GestureDetector(
      onTap: () {
        if (song.isStreaming && song.artistBrowseId != null) {
          final browseId = song.artistBrowseId!;
          Navigator.of(context).pop();
          TabNavigation.pushInActiveTab(
            ArtistScreen(browseId: browseId),
            style: settings.transitionStyle,
            durationMs: settings.transitionDurationMs,
          );
        }
      },
      child: MarqueeText(
        song.artist,
        style: artistStyle,
      ),
    );

    return _WideCoverWithControls(
      cover: cover,
      playback: playback,
      title: title,
      artist: artist,
      radius: tokens.radiusLg,
      outerPadding: EdgeInsets.all(tokens.gap),
    );
  }
}

/// Overlay del panel de lyrics en portrait: scrim oscuro sobre el cover +
/// LyricsPanel encima. La carátula queda visible como "lienzo" detrás de
/// las líneas, en lugar de desaparecer. El scrim garantiza legibilidad
/// aunque la portada sea muy brillante o de colores complejos.
class _LyricsOverlay extends StatelessWidget {
  const _LyricsOverlay({super.key, required this.radius});
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Scrim con el color `surface` del tema (que ya viene del album
          // palette procesado por AppThemeBuilder). El gradient vertical
          // tiene el centro más opaco para que la línea activa tenga
          // mejor fondo que las pasadas/futuras de los bordes.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surface.withValues(alpha: 0.78),
                  scheme.surface.withValues(alpha: 0.92),
                  scheme.surface.withValues(alpha: 0.78),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: LyricsPanel(transparent: true),
          ),
        ],
      ),
    );
  }
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({super.key, required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            tokens.space(20),
            tokens.gap,
            tokens.space(20),
            tokens.gapSm,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Cola',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
            ),
          ),
        ),
        ResponsiveSongSliverGrid(
          songs: playback.queue,
          minTileWidth: settings.songTileMinWidth,
          selectedSongId: playback.currentSong?.id,
          onTap: (song, _) async {
            final i = playback.queue.indexOf(song);
            if (i >= 0) await playback.playAt(i);
          },
        ),
        SliverToBoxAdapter(child: SizedBox(height: tokens.gapLg)),
      ],
    );
  }
}
