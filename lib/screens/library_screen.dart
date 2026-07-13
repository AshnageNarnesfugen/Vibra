import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/animations/page_transitions.dart';
import '../core/settings/settings_controller.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers/library_controller.dart';
import '../providers/playback_controller.dart';
import '../services/download_service.dart';
import '../services/playlist_service.dart';
import '../services/streaming/streaming_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_popup_menu.dart';
import '../widgets/home_carousel.dart';
import '../widgets/large_title_scaffold.dart';
import '../widgets/responsive_song_grid.dart';
import '../widgets/skeleton.dart';
import '../widgets/stable_backdrop_group.dart';
import 'login_screen.dart';
import 'player_screen.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'local_album_detail_screen.dart';
import 'playlist_detail_screen.dart';
import 'search_screen.dart';
import '../widgets/song_thumbnail.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.showOnlyHome = false});
  final bool showOnlyHome;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _localTabIndex = 0; // 0: Songs, 1: Albums, 2: Artists

  // --- Home / carousels state (modo streaming sin query) ---
  List<HomeShelf> _homeShelves = const [];
  bool _homeLoading = false;
  bool _homeAttempted = false; // evita reintentos en cada rebuild
  String? _lastSourceForHome;

  StreamSubscription<String>? _errorSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryController>();
      if (lib.songs.isEmpty && !lib.isLoading) {
        lib.reload();
      }
      _errorSub = context.read<PlaybackController>().errors.listen((msg) {
        if (!mounted) return;
        try {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 4),
            ));
        } catch (_) {}
      });
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  /// Cambia a modo `manualFolder`. Si [forcePicker] es false y ya hay
  /// una ruta guardada, reutiliza esa ruta sin abrir el file picker —
  /// el banner "Carpeta manual" del header igual deja al usuario
  /// editarla con un tap explícito (que llama con forcePicker=true).
  ///
  /// Antes el menú "Carpeta manual…" siempre abría el picker incluso
  /// cuando la ruta ya estaba guardada → al alternar streaming ↔ local
  /// el usuario tenía que renavegar al directorio cada vez.
  Future<void> _pickFolder({bool forcePicker = false}) async {
    final settingsCtrl = context.read<SettingsController>();
    final messenger = ScaffoldMessenger.of(context);
    final savedPath = settingsCtrl.value.manualFolderPath;

    if (savedPath != null && !forcePicker) {
      settingsCtrl.update((s) => s.copyWith(
            librarySource: LibrarySource.manualFolder,
          ));
      return;
    }

    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Elige tu carpeta de música',
    );
    if (picked == null) return;
    settingsCtrl.update((s) => s.copyWith(
          librarySource: LibrarySource.manualFolder,
          manualFolderPath: picked,
        ));
    messenger.showSnackBar(
      SnackBar(content: Text('Escaneando $picked …')),
    );
  }

  void _useAuto() {
    context.read<SettingsController>().update(
          (s) => s.copyWith(
            librarySource: LibrarySource.auto,
            clearManualFolderPath: true,
          ),
        );
  }

  void _useStreaming() {
    context.read<SettingsController>().update(
          (s) => s.copyWith(librarySource: LibrarySource.streaming),
        );
    setState(() {
      _homeShelves = const [];
      _homeAttempted = false;
    });
  }

  Future<void> _maybeLoadHome({
    required bool isStreaming,
    required bool hasAuth,
  }) async {
    if (!isStreaming) return;
    final cacheKey = '${isStreaming}_$hasAuth';
    if (_lastSourceForHome == cacheKey && _homeAttempted) return;
    _lastSourceForHome = cacheKey;
    _homeAttempted = true;

    setState(() => _homeLoading = true);
    try {
      final svc = context.read<StreamingService>();
      // `getEnrichedHome` combina home + history + library en paralelo y
      // garantiza una fila "Escucha de nuevo" cuando hay sesión, aunque el
      // home oficial no la incluya ese día.
      final shelves = await svc.getEnrichedHome();
      if (!mounted) return;
      setState(() {
        _homeShelves = shelves;
        _homeLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _homeShelves = const [];
        _homeLoading = false;
      });
    }
  }

  Future<void> _playShelfItem(ShelfItem item) async {
    // Album y playlist reusan AlbumScreen (mismo formato de respuesta:
    // header + musicPlaylistShelfRenderer con tracks).
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
      return;
    }

    if (item.kind != ShelfItemKind.song || item.streamingId == null) return;
    final pb = context.read<PlaybackController>();
    final settings = UiSettingsScope.of(context);
    final song = Song(
      id: 'yt:${item.streamingId}',
      title: item.title,
      artist: item.subtitle.isNotEmpty ? item.subtitle : 'YouTube Music',
      album: '—',
      uri: 'ytmusic://${item.streamingId}',
      streamingId: item.streamingId,
      thumbnailUrl: item.thumbnailUrl,
      // Propagar los browseIds del shelf item así PlayerScreen puede mostrar
      // el artista subrayado y clickeable para abrir ArtistScreen.
      artistBrowseId: item.artistBrowseId,
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
  }

  /// Re-carga los shelves del home streaming (botón "Recargar" del menú).
  /// Invalida también el cache del service (sino devolvería lo anterior).
  void _reloadHomeShelves() {
    context.read<StreamingService>().clearEnrichedHomeCache();
    setState(() {
      _homeShelves = const [];
      _homeAttempted = false;
    });
  }

  /// Handler para pull-to-refresh. Async — el RefreshIndicator deja el
  /// spinner visible hasta que el Future se completa. Refresca según
  /// el modo activo: streaming busca shelves nuevos del API, local
  /// re-escanea la biblioteca.
  Future<void> _onPullToRefresh(bool isStreaming) async {
    if (isStreaming) {
      _reloadHomeShelves();
      // Espera a que la siguiente carga complete antes de quitar el
      // spinner. _homeLoading se setea true al disparar la fetch.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Si todavía sigue loading, espera más (polling barato).
      while (mounted && _homeLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } else {
      await context.read<LibraryController>().reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final lib = context.watch<LibraryController>();
    final pb = context.watch<PlaybackController>();
    final settings = UiSettingsScope.of(context);
    final source = settings.librarySource;
    final isStreaming = source == LibrarySource.streaming;

    // Sin TextField inline ya no hay filter — Biblioteca muestra todo. La
    // búsqueda con filtro vive en SearchScreen (lupa del AppBar).
    final visibleSongs = lib.songs;
    final loading = lib.isLoading;
    final hasSession = settings.ytMusicCookie != null;
    // Distribución de contenido por tab + source:
    //
    //   - Inicio   + streaming → shelves YT Music (quick picks + algoritmo).
    //   - Inicio   + local     → carruseles locales (playlists, descargas,
    //                            biblioteca).
    //   - Biblioteca + streaming → SOLO playlists + descargas (sin shelves
    //                              de YT Music — esos van en Inicio. En
    //                              Biblioteca el usuario espera ver "su
    //                              música", no recomendaciones globales).
    //   - Biblioteca + local     → grids canciones/álbumes/artistas con
    //                              segmented tabs.
    final isHomeTab = widget.showOnlyHome;
    final isLibraryTab = !widget.showOnlyHome;
    final showStreamingHome = isStreaming && isHomeTab;
    final showLocalHome = (isHomeTab && !isStreaming) ||
        (isLibraryTab && isStreaming);

    if (showStreamingHome) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeLoadHome(isStreaming: true, hasAuth: hasSession);
      });
    }

    // `StableBackdropGroup` permite que todas las GlassCards visibles
    // compartan un único pase de blur (vía `BackdropFilter.grouped`).
    // Sin esto cada card computa su propio backdrop al entrar al viewport
    // → flash de blur. La versión "stable" cachea la `BackdropKey` para
    // que sobreviva a los rebuilds del widget (scroll/state changes).
    return StableBackdropGroup(
      child: LargeTitleScaffold(
      title: widget.showOnlyHome
          ? 'Inicio'
          : (isStreaming ? 'Streaming' : 'Biblioteca'),
      // 200px (antes 160) — el mini-player + NavigationBar ocupan ~150-160
      // y el reserve antiguo dejaba la última fila pegada al borde
      // superior del mini-player sin margen. Con 200 hay aire visual.
      bottomReserve: 200,
      // Pull-to-refresh: streaming pide shelves frescos al API; local
      // re-escanea biblioteca/playlists. Mismo gesto, comportamiento
      // adaptado al modo.
      onRefresh: () => _onPullToRefresh(isStreaming),
      actions: [
        IconButton(
          tooltip: 'Buscar',
          icon: const Icon(Icons.search_rounded),
          onPressed: () {
            final s = UiSettingsScope.of(context);
            Navigator.of(context).pushAnimated(
              const SearchScreen(),
              style: s.transitionStyle,
              durationMs: s.transitionDurationMs,
            );
          },
        ),
        GlassPopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          tooltip: 'Fuente de la biblioteca',
          items: const [
            GlassMenuItem(
                value: 'auto',
                label: 'Automático del sistema',
                icon: Icons.auto_awesome_rounded),
            GlassMenuItem(
                value: 'pick',
                label: 'Carpeta manual…',
                icon: Icons.folder_open_rounded),
            GlassMenuItem(
                value: 'streaming',
                label: 'Streaming (YT Music)',
                icon: Icons.cloud_outlined),
            GlassMenuItem(
                value: 'reload',
                label: 'Recargar',
                icon: Icons.refresh_rounded),
          ],
          onSelected: (v) {
            switch (v) {
              case 'pick':
                _pickFolder();
              case 'auto':
                _useAuto();
              case 'streaming':
                _useStreaming();
              case 'reload':
                if (isStreaming) {
                  _reloadHomeShelves();
                } else {
                  lib.reload();
                }
            }
          },
        ),
      ],
      slivers: [
        // Tabs canciones/álbumes/artistas SOLO para modo local. La búsqueda
        // se hizo standalone en SearchScreen (lupa del AppBar) — antes vivía
        // aquí inline pero confundía con el modo streaming.
        if (!widget.showOnlyHome && !isStreaming)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                tokens.space(20), tokens.gap, tokens.space(20), tokens.gapSm),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        label: Text('Canciones'),
                        icon: Icon(Icons.music_note_rounded)),
                    ButtonSegment(
                        value: 1,
                        label: Text('Álbumes'),
                        icon: Icon(Icons.album_rounded)),
                    ButtonSegment(
                        value: 2,
                        label: Text('Artistas'),
                        icon: Icon(Icons.person_rounded)),
                  ],
                  selected: {_localTabIndex},
                  onSelectionChanged: (s) =>
                      setState(() => _localTabIndex = s.first),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ),
        if (source == LibrarySource.manualFolder && settings.manualFolderPath != null)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space(20)).copyWith(bottom: tokens.gap),
            sliver: SliverToBoxAdapter(
              child: GlassCard(
                padding: tokens.tilePadding(),
                // Tap del banner SÍ abre el picker — el usuario lo
                // hace explícito ("quiero cambiar la ruta"). El menú
                // genérico "Carpeta manual…" solo reactiva la ruta
                // guardada sin re-prompt.
                onTap: () => _pickFolder(forcePicker: true),
                child: Row(
                  children: [
                    Icon(Icons.folder_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                    SizedBox(width: tokens.gap),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Carpeta manual', style: Theme.of(context).textTheme.labelSmall),
                      Text(settings.manualFolderPath!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                    ])),
                    const Icon(Icons.edit_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ),
        if (isStreaming)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space(20)).copyWith(bottom: tokens.gap),
            sliver: SliverToBoxAdapter(
              child: GlassCard(
                padding: tokens.tilePadding(),
                child: Row(
                  children: [
                    Icon(Icons.cloud_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
                    SizedBox(width: tokens.gap),
                    Expanded(child: Text('Modo streaming · YouTube Music · usa API no oficial; las URLs caducan en horas.', style: Theme.of(context).textTheme.bodySmall)),
                  ],
                ),
              ),
            ),
          ),
        if (showStreamingHome)
          ..._buildHomeSlivers(context, hasSession)
        else if (showLocalHome)
          ..._buildLocalHomeSlivers(
            context,
            lib.songs,
            settings,
            pb,
            // En Library + streaming queremos solo "tu música" online: las
            // playlists locales y las descargas. Los archivos locales del
            // dispositivo (lib.songs) NO aplican aquí — el usuario está en
            // modo streaming. En cambio, Home + local SÍ incluye la biblio
            // completa porque es el resumen general del modo offline.
            includeLocalLibrary: !isStreaming,
          )
        else if (loading)
          const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()))
        else if (visibleSongs.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _Empty(
              source: source,
              hasQuery: false,
              onPickFolder: () => _pickFolder(forcePicker: true),
              onReload: () => lib.reload(),
            ),
          )
        else if (_localTabIndex == 1)
          _buildLocalAlbumGrid(context, lib.albums)
        else if (_localTabIndex == 2)
          _buildLocalArtistGrid(context, lib.artists)
        else
          ResponsiveSongSliverGrid(
            songs: visibleSongs,
            minTileWidth: settings.songTileMinWidth,
            selectedSongId: pb.currentSong?.id,
            onTap: (song, i) async {
              await pb.setQueue(visibleSongs, startIndex: i);
              if (!context.mounted) return;
              Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
                  const PlayerScreen(),
                  routeName: kPlayerRouteName,
                  style: settings.transitionStyle,
                  durationMs: settings.transitionDurationMs);
            },
          ),
      ],
      ),
    );
  }

  Widget _buildLocalAlbumGrid(BuildContext context, List<Album> albums) {
    final tokens = LayoutTokensScope.of(context);
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
      sliver: SliverGrid.builder(
        itemCount: albums.length,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 240, crossAxisSpacing: 16, mainAxisSpacing: 16),
        itemBuilder: (context, i) {
          final album = albums[i];
          return _GridCard(
            title: album.name,
            subtitle: album.artist,
            inlineArtwork: album.inlineArtwork,
            thumbnailUrl: album.thumbnailUrl,
            onTap: () {
              final s = UiSettingsScope.of(context);
              Navigator.of(context).pushAnimated(
                LocalAlbumDetailScreen(
                  title: album.name,
                  subtitle: album.artist,
                  songs: album.songs,
                  inlineArtwork: album.inlineArtwork,
                  thumbnailUrl: album.thumbnailUrl,
                ),
                style: s.transitionStyle,
                durationMs: s.transitionDurationMs,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildLocalArtistGrid(BuildContext context, List<Artist> artists) {
    final tokens = LayoutTokensScope.of(context);
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
      sliver: SliverGrid.builder(
        itemCount: artists.length,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 240, crossAxisSpacing: 16, mainAxisSpacing: 16),
        itemBuilder: (context, i) {
          final artist = artists[i];
          return _GridCard(
            title: artist.name,
            subtitle: '${artist.songs.length} canciones',
            onTap: () {
              final s = UiSettingsScope.of(context);
              Navigator.of(context).pushAnimated(
                LocalAlbumDetailScreen(
                  title: artist.name,
                  subtitle: 'Artista',
                  songs: artist.songs,
                ),
                style: s.transitionStyle,
                durationMs: s.transitionDurationMs,
              );
            },
          );
        },
      ),
    );
  }

  /// Carruseles cuando el contenido del scaffold es "tu música" (no
  /// recomendaciones de YT Music). Dos casos:
  ///   - Inicio + local: muestra playlists + descargas + biblioteca local
  ///     completa (es el resumen del modo offline).
  ///   - Biblioteca + streaming: muestra SOLO playlists + descargas —
  ///     la biblioteca local de archivos no aplica porque el usuario está
  ///     en modo streaming. Los shelves de YT Music viven en el tab Inicio.
  ///
  /// [includeLocalLibrary] controla si se añade el grid "Tu biblioteca".
  List<Widget> _buildLocalHomeSlivers(
    BuildContext context,
    List<Song> songs,
    UiSettings settings,
    PlaybackController pb, {
    bool includeLocalLibrary = true,
  }) {
    final tokens = LayoutTokensScope.of(context);
    final out = <Widget>[];

    final localPlaylists = context.watch<PlaylistService>().playlists;
    if (localPlaylists.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: _LocalPlaylistsShelf(playlists: localPlaylists),
      ));
    }

    final downloads = context.watch<DownloadService?>();
    final downloadedSongs = downloads == null
        ? const <Song>[]
        : downloads.downloadedIds
            .map((id) => downloads.metadataOf(id))
            .whereType<Song>()
            .toList();
    if (downloadedSongs.isNotEmpty) {
      out.add(SliverPadding(
        padding: EdgeInsets.fromLTRB(
            tokens.space(20), 16, tokens.space(20), 8),
        sliver: SliverToBoxAdapter(
          child: Text(
            'Descargas · ${downloadedSongs.length}',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
      ));
      out.add(ResponsiveSongSliverGrid(
        songs: downloadedSongs,
        minTileWidth: settings.songTileMinWidth,
        selectedSongId: pb.currentSong?.id,
        onTap: (song, i) async {
          await pb.setQueue(downloadedSongs, startIndex: i);
          if (!context.mounted) return;
          Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
            const PlayerScreen(),
            routeName: kPlayerRouteName,
            style: settings.transitionStyle,
            durationMs: settings.transitionDurationMs,
          );
        },
      ));
      out.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    }

    // Empty state: nada que mostrar.
    final hasAnyContent = localPlaylists.isNotEmpty ||
        downloadedSongs.isNotEmpty ||
        (includeLocalLibrary && songs.isNotEmpty);
    if (!hasAnyContent) {
      out.add(SliverFillRemaining(
        hasScrollBody: false,
        child: _Empty(
          source: settings.librarySource,
          hasQuery: false,
          onPickFolder: _pickFolder,
          onReload: () => context.read<LibraryController>().reload(),
        ),
      ));
      return out;
    }

    if (!includeLocalLibrary) {
      return out;
    }

    out.add(SliverPadding(
      padding:
          EdgeInsets.fromLTRB(tokens.space(20), 16, tokens.space(20), 8),
      sliver: SliverToBoxAdapter(
        child: Text(
          'Tu biblioteca · ${songs.length}',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
    ));
    out.add(ResponsiveSongSliverGrid(
      songs: songs,
      minTileWidth: settings.songTileMinWidth,
      selectedSongId: pb.currentSong?.id,
      onTap: (song, i) async {
        await pb.setQueue(songs, startIndex: i);
        if (!context.mounted) return;
        Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
          const PlayerScreen(),
          routeName: kPlayerRouteName,
          style: settings.transitionStyle,
          durationMs: settings.transitionDurationMs,
        );
      },
    ));
    return out;
  }

  List<Widget> _buildHomeSlivers(BuildContext context, bool hasSession) {
    final tokens = LayoutTokensScope.of(context);
    final out = <Widget>[];

    if (!hasSession) {
      out.add(SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: tokens.space(20))
            .copyWith(bottom: tokens.gap),
        sliver: SliverToBoxAdapter(
          child: GlassCard(
            onTap: () {
              final s = UiSettingsScope.of(context);
              Navigator.of(context, rootNavigator: true).pushAnimated(
                const LoginScreen(),
                style: s.transitionStyle,
                durationMs: s.transitionDurationMs,
              );
            },
            child: Row(
              children: [
                Icon(Icons.login_rounded,
                    color: Theme.of(context).colorScheme.primary),
                SizedBox(width: tokens.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Inicia sesión en YouTube Music',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        'Tu biblioteca personal, gustadas y recomendaciones '
                        'a tu nombre.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ));
    }

    // "Tus playlists" — sección con las playlists LOCALES del usuario. Se
    // muestra arriba (antes de los shelves de YT Music) para que sea fácil
    // de acceder. Si no hay playlists, no se muestra nada.
    final localPlaylists = context.watch<PlaylistService>().playlists;
    if (localPlaylists.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: _LocalPlaylistsShelf(playlists: localPlaylists),
      ));
    }

    if (_homeLoading && _homeShelves.isEmpty) {
      // Hidratación visual estilo Facebook/YT Music: 3 shelves
      // placeholder pulsantes mientras carga el API. Da feedback visual
      // inmediato del shape del contenido que viene, en vez del spinner
      // estático que se siente "vacío".
      out.add(
        SliverList.builder(
          itemCount: 3,
          itemBuilder: (_, i) => Padding(
            padding: EdgeInsets.only(top: i == 0 ? 8 : 24),
            child: const SkeletonShelf(),
          ),
        ),
      );
      return out;
    }

    if (_homeShelves.isEmpty) {
      out.add(SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_outlined, size: 56),
              const SizedBox(height: 12),
              Text(
                hasSession
                    ? 'YouTube Music no devolvió shelves para tu cuenta.'
                    : 'Empieza a buscar canciones en YouTube Music.',
                textAlign: TextAlign.center,
              ),
              if (hasSession) ...[
                const SizedBox(height: 8),
                Text(
                  'Esto puede pasar si tu cookie expiró o si la API cambió. '
                  'Revisa los logs ([YTM] home/history/library) para más detalle.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white60),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reintentar'),
                  onPressed: () {
                    // Invalida el cache del service también: sino el método
                    // devolvería el último cache vacío sin tocar red.
                    context.read<StreamingService>().clearEnrichedHomeCache();
                    setState(() {
                      _homeAttempted = false;
                      _lastSourceForHome = null;
                    });
                    _maybeLoadHome(isStreaming: true, hasAuth: hasSession);
                  },
                ),
              ],
            ],
          ),
        ),
      ));
      return out;
    }

    for (final shelf in _homeShelves) {
      out.add(SliverToBoxAdapter(child: HomeCarousel(shelf: shelf, onPlayItem: _playShelfItem)));
    }
    return out;
  }
}

class _GridCard extends StatelessWidget {
  const _GridCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.inlineArtwork,
    this.thumbnailUrl,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final dynamic inlineArtwork;
  final String? thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: tokens.radius,
              child: SongThumbnail(
                song: Song(
                  id: '',
                  title: title,
                  artist: subtitle,
                  album: '',
                  uri: '',
                  inlineArtwork: inlineArtwork,
                  thumbnailUrl: thumbnailUrl,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.source,
    required this.hasQuery,
    required this.onPickFolder,
    required this.onReload,
  });

  final LibrarySource source;
  final bool hasQuery;
  final VoidCallback onPickFolder;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final isStreaming = source == LibrarySource.streaming;
    final icon = isStreaming
        ? Icons.cloud_outlined
        : Icons.library_music_rounded;
    final message = isStreaming
        ? (hasQuery
            ? 'Sin resultados para tu búsqueda.'
            : 'Empieza a buscar canciones en YouTube Music.')
        : source == LibrarySource.manualFolder
            ? 'No se encontraron canciones en esa carpeta.'
            : 'No se encontraron canciones.';

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (!isStreaming)
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onPickFolder,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Elegir carpeta'),
                ),
                OutlinedButton.icon(
                  onPressed: onReload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Shelf horizontal con las playlists locales del usuario. Tap → abre el
/// detalle. La idea es que las playlists tengan visibilidad de primera
/// clase en el home, igual que los shelves de YT Music.
class _LocalPlaylistsShelf extends StatelessWidget {
  const _LocalPlaylistsShelf({required this.playlists});
  final List<Playlist> playlists;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.gapSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
            child: Text(
              'Tus playlists',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(height: tokens.gapSm),
          SizedBox(
            height: 196,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: tokens.space(20)),
              itemCount: playlists.length,
              separatorBuilder: (_, _) => SizedBox(width: tokens.gap),
              itemBuilder: (context, i) {
                final pl = playlists[i];
                final thumb = pl.displayThumbnailUrl;
                return SizedBox(
                  width: 140,
                  child: InkWell(
                    borderRadius: tokens.radius,
                    onTap: () {
                      final s = UiSettingsScope.of(context);
                      Navigator.of(context).pushAnimated(
                        PlaylistDetailScreen(playlistId: pl.id),
                        style: s.transitionStyle,
                        durationMs: s.transitionDurationMs,
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 140,
                          height: 140,
                          child: ClipRRect(
                            borderRadius: tokens.radius,
                            child: thumb != null && thumb.isNotEmpty
                                ? Image.network(
                                    thumb,
                                    fit: BoxFit.cover,
                                    cacheWidth: 280,
                                    cacheHeight: 280,
                                    errorBuilder: (_, _, _) =>
                                        _placeholder(scheme),
                                  )
                                : _placeholder(scheme),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          pl.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            '${pl.songs.length} canción${pl.songs.length == 1 ? '' : 'es'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: scheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => ColoredBox(
        color: scheme.primary.withValues(alpha: 0.15),
        child: Icon(
          Icons.queue_music_rounded,
          size: 48,
          color: scheme.primary,
        ),
      );
}
