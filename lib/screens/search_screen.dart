import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../providers/library_controller.dart';
import '../providers/playback_controller.dart';
import '../services/streaming/streaming_service.dart';
import '../widgets/responsive_song_grid.dart';
import '../widgets/shelf_cards.dart';
import '../widgets/stable_backdrop_group.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'player_screen.dart';

/// Vista de búsqueda unificada: filtra la biblioteca local y consulta a
/// YouTube Music en paralelo, devolviendo categorías (canciones, álbumes,
/// artistas, videos). Reemplaza la búsqueda inline que vivía en
/// `LibraryScreen` y `HomeScreen`.
///
/// Acceso: botón lupa en el AppBar de Home/Library → push de esta pantalla.
/// Auto-focus del TextField al abrir.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

enum _ResultTab { all, local, songs, albums, artists, videos }

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  int _token = 0;

  // Resultados streaming.
  List<Song> _streamingSongs = const [];
  List<ShelfItem> _streamingAlbums = const [];
  List<ShelfItem> _streamingArtists = const [];
  List<Song> _streamingVideos = const [];
  bool _streamingLoading = false;
  String? _streamingError;

  // Filtro local computado en `_filteredLocal`.
  String _query = '';
  _ResultTab _tab = _ResultTab.all;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
      _ctrl.text = widget.initialQuery!;
      _query = widget.initialQuery!.toLowerCase();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runStreamingSearch(widget.initialQuery!);
      });
    } else {
      // Auto-focus solo si no hay query inicial — sino el push viene
      // probablemente de un deep link y no queremos abrir el teclado.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _query = value.toLowerCase());
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _runStreamingSearch(value);
    });
  }

  void _clearQuery() {
    _ctrl.clear();
    setState(() {
      _query = '';
      _streamingSongs = const [];
      _streamingAlbums = const [];
      _streamingArtists = const [];
      _streamingVideos = const [];
      _streamingError = null;
      _streamingLoading = false;
    });
    _focus.requestFocus();
  }

  Future<void> _runStreamingSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _streamingSongs = const [];
        _streamingAlbums = const [];
        _streamingArtists = const [];
        _streamingVideos = const [];
        _streamingLoading = false;
        _streamingError = null;
      });
      return;
    }
    final t = ++_token;
    setState(() {
      _streamingLoading = true;
      _streamingError = null;
    });
    try {
      final svc = context.read<StreamingService>();
      final res = await svc.searchUnified(q);
      if (t != _token || !mounted) return;
      setState(() {
        _streamingSongs = res.songs;
        _streamingAlbums = res.albums;
        _streamingArtists = res.artists;
        _streamingVideos = res.videos;
        _streamingLoading = false;
      });
    } catch (e) {
      if (t != _token || !mounted) return;
      setState(() {
        _streamingLoading = false;
        _streamingError = e.toString();
      });
    }
  }

  List<Song> _filteredLocal(List<Song> all) {
    if (_query.isEmpty) return const [];
    return all
        .where((s) =>
            s.title.toLowerCase().contains(_query) ||
            s.artist.toLowerCase().contains(_query) ||
            s.album.toLowerCase().contains(_query))
        .toList();
  }

  Future<void> _playLocalAt(List<Song> queue, int index) async {
    final pb = context.read<PlaybackController>();
    final settings = UiSettingsScope.of(context);
    await pb.setQueue(queue, startIndex: index);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
      const PlayerScreen(),
      routeName: kPlayerRouteName,
      style: settings.transitionStyle,
      durationMs: settings.transitionDurationMs,
    );
  }

  Future<void> _openShelfItem(ShelfItem item) async {
    final s = UiSettingsScope.of(context);
    if (item.kind == ShelfItemKind.album ||
        item.kind == ShelfItemKind.playlist) {
      Navigator.of(context).pushAnimated(
        AlbumScreen(
          browseId: item.id,
          initialThumb: item.thumbnailUrl,
        ),
        style: s.transitionStyle,
        durationMs: s.transitionDurationMs,
      );
      return;
    }
    if (item.kind == ShelfItemKind.artist) {
      Navigator.of(context).pushAnimated(
        ArtistScreen(browseId: item.id),
        style: s.transitionStyle,
        durationMs: s.transitionDurationMs,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = LayoutTokensScope.of(context);
    final lib = context.watch<LibraryController>();
    final localResults = _filteredLocal(lib.songs);

    final hasResults = localResults.isNotEmpty ||
        _streamingSongs.isNotEmpty ||
        _streamingAlbums.isNotEmpty ||
        _streamingArtists.isNotEmpty ||
        _streamingVideos.isNotEmpty;

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          titleSpacing: 0,
          title: TextField(
            controller: _ctrl,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Buscar canciones, artistas, álbumes…',
              border: InputBorder.none,
              hintStyle: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.5),
                fontSize: 16,
              ),
            ),
            style: TextStyle(color: scheme.onSurface, fontSize: 16),
            onChanged: _onChanged,
            onSubmitted: (v) => _runStreamingSearch(v),
          ),
          actions: [
            if (_ctrl.text.isNotEmpty)
              IconButton(
                tooltip: 'Limpiar',
                icon: const Icon(Icons.close_rounded),
                onPressed: _clearQuery,
              )
            else if (_streamingLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  tokens.space(20), tokens.gapSm, tokens.space(20), tokens.gap),
              sliver: SliverToBoxAdapter(
                child: _TabsBar(
                  current: _tab,
                  onChanged: (t) => setState(() => _tab = t),
                ),
              ),
            ),
            if (_query.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _Hint(
                  icon: Icons.search_rounded,
                  text:
                      'Escribe para buscar en tu biblioteca y en YouTube Music.',
                ),
              )
            else if (_streamingLoading &&
                !hasResults &&
                _streamingError == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_streamingError != null && !hasResults)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _Hint(
                  icon: Icons.cloud_off_rounded,
                  text: 'Error en la búsqueda streaming.\n$_streamingError',
                ),
              )
            else ...[
              if (_visibleLocal && localResults.isNotEmpty)
                ..._buildLocalSection(localResults),
              if (_visible(_ResultTab.songs) && _streamingSongs.isNotEmpty)
                ..._buildStreamingSongs(),
              if (_visible(_ResultTab.albums) && _streamingAlbums.isNotEmpty)
                ..._buildStreamingAlbums(tokens),
              if (_visible(_ResultTab.artists) && _streamingArtists.isNotEmpty)
                ..._buildStreamingArtists(tokens),
              if (_visible(_ResultTab.videos) && _streamingVideos.isNotEmpty)
                ..._buildStreamingVideos(),
              if (!hasResults && !_streamingLoading)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Hint(
                    icon: Icons.sentiment_dissatisfied_rounded,
                    text: 'Sin resultados para "${_ctrl.text}".',
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ],
        ),
      ),
    );
  }

  bool get _visibleLocal =>
      _tab == _ResultTab.all || _tab == _ResultTab.local;
  bool _visible(_ResultTab t) => _tab == _ResultTab.all || _tab == t;

  List<Widget> _buildLocalSection(List<Song> local) {
    final settings = UiSettingsScope.of(context);
    final pb = context.watch<PlaybackController>();
    // Si el tab es "all" enseñamos solo los primeros 8 (rest detrás de un
    // "Ver todo"). Si el tab es "local", mostramos todo.
    final showAll = _tab == _ResultTab.local;
    final visible = showAll ? local : local.take(8).toList();
    return [
      ShelfSectionTitle(
        label: showAll
            ? 'Tu biblioteca · ${local.length}'
            : 'Tu biblioteca',
        onShowAll: (!showAll && local.length > 8)
            ? () => setState(() => _tab = _ResultTab.local)
            : null,
      ),
      ResponsiveSongSliverGrid(
        songs: visible,
        minTileWidth: settings.songTileMinWidth,
        selectedSongId: pb.currentSong?.id,
        onTap: (song, i) => _playLocalAt(visible, i),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }

  List<Widget> _buildStreamingSongs() {
    final settings = UiSettingsScope.of(context);
    final pb = context.watch<PlaybackController>();
    final showAll = _tab == _ResultTab.songs;
    final visible =
        showAll ? _streamingSongs : _streamingSongs.take(5).toList();
    return [
      ShelfSectionTitle(
        label: 'Canciones',
        onShowAll:
            (!showAll && _streamingSongs.length > 5)
                ? () => setState(() => _tab = _ResultTab.songs)
                : null,
      ),
      ResponsiveSongSliverGrid(
        songs: visible,
        minTileWidth: settings.songTileMinWidth,
        selectedSongId: pb.currentSong?.id,
        onTap: (song, i) => _playLocalAt(visible, i),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }

  List<Widget> _buildStreamingAlbums(LayoutTokens tokens) {
    final showAll = _tab == _ResultTab.albums;
    final list = showAll ? _streamingAlbums : _streamingAlbums.take(8).toList();
    return [
      ShelfSectionTitle(
        label: 'Álbumes',
        onShowAll: (!showAll && _streamingAlbums.length > 5)
            ? () => setState(() => _tab = _ResultTab.albums)
            : null,
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) =>
                SmallShelfCard(item: list[i], onTap: () => _openShelfItem(list[i])),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  List<Widget> _buildStreamingArtists(LayoutTokens tokens) {
    final showAll = _tab == _ResultTab.artists;
    final list =
        showAll ? _streamingArtists : _streamingArtists.take(8).toList();
    return [
      ShelfSectionTitle(
        label: 'Artistas',
        onShowAll: (!showAll && _streamingArtists.length > 5)
            ? () => setState(() => _tab = _ResultTab.artists)
            : null,
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) => SmallArtistCard(
                item: list[i], onTap: () => _openShelfItem(list[i])),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  List<Widget> _buildStreamingVideos() {
    final settings = UiSettingsScope.of(context);
    final pb = context.watch<PlaybackController>();
    final showAll = _tab == _ResultTab.videos;
    final visible =
        showAll ? _streamingVideos : _streamingVideos.take(5).toList();
    return [
      ShelfSectionTitle(
        label: 'Videos musicales',
        onShowAll: (!showAll && _streamingVideos.length > 5)
            ? () => setState(() => _tab = _ResultTab.videos)
            : null,
      ),
      ResponsiveSongSliverGrid(
        songs: visible,
        minTileWidth: settings.songTileMinWidth,
        selectedSongId: pb.currentSong?.id,
        onTap: (song, i) => _playLocalAt(visible, i),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }
}

class _TabsBar extends StatelessWidget {
  const _TabsBar({required this.current, required this.onChanged});
  final _ResultTab current;
  final ValueChanged<_ResultTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final t in _ResultTab.values) ...[
            ChoiceChip(
              label: Text(_label(t)),
              selected: current == t,
              onSelected: (_) => onChanged(t),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  static String _label(_ResultTab t) => switch (t) {
        _ResultTab.all => 'Todo',
        _ResultTab.local => 'Tu biblioteca',
        _ResultTab.songs => 'Canciones',
        _ResultTab.albums => 'Álbumes',
        _ResultTab.artists => 'Artistas',
        _ResultTab.videos => 'Videos',
      };
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 48, color: scheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.7),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
