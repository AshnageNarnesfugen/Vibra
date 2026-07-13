import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../providers/playback_controller.dart';
import '../services/streaming/streaming_service.dart';
import '../widgets/responsive_song_grid.dart';
import '../widgets/song_context_sheet.dart';
import '../widgets/song_thumbnail.dart';
import 'player_screen.dart';
import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';

class AlbumScreen extends StatefulWidget {
  const AlbumScreen({super.key, required this.browseId, this.initialThumb});
  final String browseId;
  final String? initialThumb;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  bool _loading = true;
  dynamic _album;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = context.read<StreamingService>();
    final data = await svc.getAlbumDetails(widget.browseId);
    if (mounted) {
      setState(() {
        _album = data;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);

    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.initialThumb != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 400,
                child: SongThumbnail(song: Song(id: '', title: '', artist: '', album: '', uri: '', thumbnailUrl: widget.initialThumb)),
              ),
            const Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }

    if (_album == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('No se pudo cargar el álbum.')),
      );
    }

    // PRIORIDAD DE IMAGEN:
    // 1. Siempre preferimos la heredada (initialThumb) si existe, ya que viene de una vista donde era correcta.
    // 2. Solo usamos la de la API (_album.thumb) si no hay heredada o si la de la API parece ser de mayor calidad (opcional).
    final String thumb = (widget.initialThumb != null && widget.initialThumb!.isNotEmpty) 
        ? widget.initialThumb! 
        : ((_album.thumb as String).isEmpty ? '' : _album.thumb);

    // ¿Estamos viendo un álbum o una playlist? Los álbumes (MPREb_*) tienen
    // todas sus canciones con la MISMA carátula → safe forzar la heredada.
    // Las playlists (VL*) son colecciones de canciones de álbumes distintos
    // → cada track tiene su propia carátula y NO debemos sobreescribir, o
    // todas las canciones se ven con la portada de la playlist.
    final bool isPlaylist = widget.browseId.startsWith('VL');

    final List<Song> tracks =
        (_album.tracks as List<StreamingTrack>).map<Song>((t) {
      final s = t.toSong();
      if (isPlaylist) {
        // Playlist: respeta la carátula propia de cada canción. Solo cae al
        // thumb de la playlist como último recurso (evita placeholder vacío).
        if (s.thumbnailUrl == null || s.thumbnailUrl!.isEmpty) {
          return s.copyWith(thumbnailUrl: thumb);
        }
        return s;
      }
      // Álbum: forzamos la portada del álbum a todas las canciones — todas
      // pertenecen al mismo álbum y así evitamos que el scavenger de la API
      // meta avatares de artista o thumbnails inconsistentes.
      if (widget.initialThumb != null && widget.initialThumb!.isNotEmpty) {
        return s.copyWith(thumbnailUrl: widget.initialThumb);
      }
      if (s.thumbnailUrl == null || s.thumbnailUrl!.isEmpty) {
        return s.copyWith(thumbnailUrl: thumb);
      }
      return s;
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: tracks.isEmpty ? AppBar(backgroundColor: Colors.transparent) : null,
      body: tracks.isEmpty 
        ? const Center(child: Text('Este álbum no tiene canciones disponibles.'))
        : CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 400,
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
                onPressed: () => showSongContextSheet(
                  context,
                  songs: tracks,
                  title: _album.title,
                  subtitle: _album.subtitle,
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  SongThumbnail(song: Song(id: '', title: '', artist: '', album: '', uri: '', thumbnailUrl: thumb)),
                  // Gradiente para asegurar visibilidad del título
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
                  Text(_album.title, 
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_album.subtitle, style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)
                  )),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _playAll(tracks, shuffle: false),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Reproducir'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => _playAll(tracks, shuffle: true),
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
          ResponsiveSongSliverGrid(
            songs: tracks,
            minTileWidth: settings.songTileMinWidth,
            selectedSongId: context.watch<PlaybackController>().currentSong?.id,
            onTap: (song, i) async {
              final pb = context.read<PlaybackController>();
              await pb.setQueue(tracks, startIndex: i);
              if (!mounted) return;
              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
                  const PlayerScreen(),
                  routeName: kPlayerRouteName,
                  style: settings.transitionStyle,
                  durationMs: settings.transitionDurationMs,
                );
              }
            },
          ),
          // Reserva inferior: el mini-player + nav ocupan ~160px y antes
          // dejábamos 160 sin margen → la última fila quedaba al ras del
          // borde superior del mini-player. Con 200 hay aire visual.
          SliverToBoxAdapter(
              child: SizedBox(
                  height: 200 + MediaQuery.viewPaddingOf(context).bottom)),
        ],
      ),
    );
  }

  Future<void> _playAll(List<Song> songs, {required bool shuffle}) async {
    final pb = context.read<PlaybackController>();
    final settings = UiSettingsScope.of(context);
    final list = List<Song>.from(songs);
    if (shuffle) list.shuffle();
    await pb.setQueue(list);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
      const PlayerScreen(),
      routeName: kPlayerRouteName,
      style: settings.transitionStyle,
      durationMs: settings.transitionDurationMs,
    );
  }
}
