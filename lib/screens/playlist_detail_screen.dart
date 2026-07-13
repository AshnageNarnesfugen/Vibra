import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers/playback_controller.dart';
import '../services/playlist_service.dart';
import '../widgets/responsive_song_grid.dart';
import '../widgets/song_context_sheet.dart';
import '../widgets/song_thumbnail.dart';
import 'player_screen.dart';

/// Vista de una playlist local: header con carátula + nombre + botones de
/// reproducir/aleatorio, y lista de canciones.
///
/// Lee el playlist VIVO del PlaylistService — si se añade o quita una
/// canción mientras está abierta, la vista se actualiza sola.
class PlaylistDetailScreen extends StatelessWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);
    final svc = context.watch<PlaylistService>();
    final playlist = svc.playlists.firstWhere(
      (p) => p.id == playlistId,
      orElse: () => Playlist(
        id: playlistId,
        name: 'Playlist eliminada',
        songs: const [],
        createdAt: DateTime.now(),
      ),
    );

    final thumb = playlist.displayThumbnailUrl;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 360,
            pinned: true,
            stretch: true,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.more_vert_rounded),
                tooltip: 'Más opciones',
                onPressed: () =>
                    _showPlaylistMenu(context, svc, playlist),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [
                StretchMode.zoomBackground,
                StretchMode.blurBackground,
              ],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb != null && thumb.isNotEmpty)
                    SongThumbnail(
                      song: Song(
                        id: '',
                        title: '',
                        artist: '',
                        album: '',
                        uri: '',
                        thumbnailUrl: thumb,
                      ),
                    )
                  else
                    Container(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.15),
                      child: Icon(
                        Icons.queue_music_rounded,
                        size: 120,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: tokens.pagePadding(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${playlist.songs.length} canción${playlist.songs.length == 1 ? '' : 'es'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.7),
                        ),
                  ),
                  const SizedBox(height: 16),
                  if (playlist.songs.isNotEmpty)
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () =>
                              _playAll(context, playlist.songs, shuffle: false),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Reproducir'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () =>
                              _playAll(context, playlist.songs, shuffle: true),
                          icon: const Icon(Icons.shuffle_rounded),
                          label: const Text('Aleatorio'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          if (playlist.songs.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Playlist vacía.\nMantén presionada o usa el menú "…" de '
                    'una canción para añadirla aquí.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            ResponsiveSongSliverGrid(
              songs: playlist.songs,
              minTileWidth: settings.songTileMinWidth,
              selectedSongId:
                  context.watch<PlaybackController>().currentSong?.id,
              onTap: (song, i) async {
                final pb = context.read<PlaybackController>();
                await pb.setQueue(playlist.songs, startIndex: i);
                if (!context.mounted) return;
                Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
                  const PlayerScreen(),
                  routeName: kPlayerRouteName,
                  style: settings.transitionStyle,
                  durationMs: settings.transitionDurationMs,
                );
              },
            ),
          // Reserva inferior: el mini-player + nav ocupan ~160px y antes
          // dejábamos 160 sin margen → la última fila quedaba al ras del
          // borde superior del mini-player. Con 200 hay aire visual.
          SliverToBoxAdapter(
            child: SizedBox(
                height: 200 + MediaQuery.viewPaddingOf(context).bottom),
          ),
        ],
      ),
    );
  }

  void _playAll(BuildContext context, List<Song> songs,
      {required bool shuffle}) async {
    final pb = context.read<PlaybackController>();
    final settings = UiSettingsScope.of(context);
    final list = List<Song>.from(songs);
    if (shuffle) list.shuffle();
    await pb.setQueue(list);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
      const PlayerScreen(),
      routeName: kPlayerRouteName,
      style: settings.transitionStyle,
      durationMs: settings.transitionDurationMs,
    );
  }

  void _showPlaylistMenu(
    BuildContext context,
    PlaylistService svc,
    Playlist pl,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.97),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('Renombrar'),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final name = await _promptName(context, pl.name);
                    if (name != null && name.trim().isNotEmpty) {
                      await svc.rename(pl.id, name);
                    }
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: scheme.error,
                  ),
                  title: Text(
                    'Eliminar playlist',
                    style: TextStyle(color: scheme.error),
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (dctx) => AlertDialog(
                        title: const Text('¿Eliminar playlist?'),
                        content: Text(
                          'Se borrará "${pl.name}". Las canciones siguen '
                          'donde estaban (esto solo borra la playlist).',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dctx).pop(false),
                            child: const Text('Cancelar'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(dctx).pop(true),
                            child: const Text('Eliminar'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await svc.delete(pl.id);
                      if (context.mounted) Navigator.of(context).pop();
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music_rounded),
                  title: const Text('Ver acciones de canciones'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    showSongContextSheet(
                      context,
                      songs: pl.songs,
                      title: pl.name,
                      subtitle: 'Playlist · ${pl.songs.length} canciones',
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String?> _promptName(BuildContext context, String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar playlist'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}
