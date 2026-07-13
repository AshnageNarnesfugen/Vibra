import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/settings/ui_settings.dart';
import '../providers/playback_controller.dart';
import '../services/streaming/streaming_service.dart';
import '../widgets/home_carousel.dart';
import '../widgets/song_thumbnail.dart';
import '../models/song.dart';
import 'player_screen.dart';
import 'album_screen.dart';
import 'shelf_full_screen.dart';
import '../core/animations/page_transitions.dart';

class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.browseId});
  final String browseId;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  bool _loading = true;
  dynamic _artist;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = context.read<StreamingService>();
    final data = await svc.getArtistDetails(widget.browseId);
    if (mounted) {
      setState(() {
        _artist = data;
        _loading = false;
      });
    }
  }

  Future<void> _onPlayItem(ShelfItem item) async {
    switch (item.kind) {
      case ShelfItemKind.song:
        if (item.streamingId == null) return;
        final pb = context.read<PlaybackController>();
        final settings = UiSettingsScope.of(context);
        // En la página del artista, el subtitle de un song shelf suele ser
        // "5.4M reproducciones" o el álbum, NO el nombre del artista (que es
        // implícito: la página entera ya es del artista). Usamos el nombre
        // del header en lugar del subtitle del item.
        final String artistName = _artist?.name ?? item.subtitle;
        final song = Song(
          id: 'yt:${item.streamingId}',
          title: item.title,
          artist: artistName,
          album: '—',
          uri: 'ytmusic://${item.streamingId}',
          streamingId: item.streamingId,
          thumbnailUrl: item.thumbnailUrl,
          // El artista es el dueño de la página → si no viene en el shelf
          // item, usamos el browseId de la ArtistScreen actual para que el
          // subrayado de PlayerScreen abra el artista correcto.
          artistBrowseId: item.artistBrowseId ?? widget.browseId,
          albumBrowseId: item.albumBrowseId,
        );
        await pb.setQueue([song]);
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
          const PlayerScreen(),
          routeName: kPlayerRouteName,
          style: settings.transitionStyle,
          durationMs: settings.transitionDurationMs,
        );
      case ShelfItemKind.album:
      case ShelfItemKind.playlist:
        // Reusamos AlbumScreen: el browseId de una playlist (VL...) y el de
        // un álbum (MPREb_...) generan respuestas con la misma estructura
        // (header + musicPlaylistShelfRenderer con tracks).
        final s = UiSettingsScope.of(context);
        Navigator.of(context).pushAnimated(
          AlbumScreen(
            browseId: item.id,
            initialThumb: item.thumbnailUrl,
          ),
          style: s.transitionStyle,
          durationMs: s.transitionDurationMs,
        );
      case ShelfItemKind.artist:
        // Related artist — push otro ArtistScreen (mismo widget, distinto
        // browseId).
        final s = UiSettingsScope.of(context);
        Navigator.of(context).pushAnimated(
          ArtistScreen(browseId: item.id),
          style: s.transitionStyle,
          durationMs: s.transitionDurationMs,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_artist == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('No se pudo cargar el artista.')),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            backgroundColor: Colors.transparent,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(_artist.name, style: const TextStyle(shadows: [Shadow(blurRadius: 10)])),
              background: SongThumbnail(song: Song(id: '', title: '', artist: '', album: '', uri: '', thumbnailUrl: _artist.thumb)),
            ),
          ),
          for (final shelf in (_artist.shelves as List<HomeShelf>))
            SliverToBoxAdapter(
              child: HomeCarousel(
                shelf: shelf,
                onPlayItem: _onPlayItem,
                // "Ver todo": push de ShelfFullScreen con la lista completa
                // en grid. Útil cuando un shelf (Álbumes, Singles, etc.)
                // trae muchos items que no caben cómodamente en carrusel.
                onShowAll: () {
                  final s = UiSettingsScope.of(context);
                  Navigator.of(context).pushAnimated(
                    ShelfFullScreen(
                      title: shelf.title,
                      initialItems: shelf.items,
                      onTapItem: _onPlayItem,
                      // Si el shelf trae el endpoint "Ver todo", se hace
                      // fetch async dentro de la pantalla para mostrar la
                      // lista completa (30+ items) en vez de los ~10 del
                      // carrusel inicial.
                      moreBrowseId: shelf.moreBrowseId,
                      moreParams: shelf.moreParams,
                    ),
                    style: s.transitionStyle,
                    durationMs: s.transitionDurationMs,
                  );
                },
              ),
            ),
          // Reserva inferior: el mini-player + nav ocupan ~160px y antes
          // dejábamos 160 sin margen → la última fila quedaba al ras del
          // borde superior del mini-player. Con 200 hay aire visual.
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200 + MediaQuery.viewPaddingOf(context).bottom,
            ),
          ),
        ],
      ),
    );
  }
}
