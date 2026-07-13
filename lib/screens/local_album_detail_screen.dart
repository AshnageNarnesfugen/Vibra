import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../providers/playback_controller.dart';
import '../widgets/responsive_song_grid.dart';
import '../widgets/song_thumbnail.dart';
import 'player_screen.dart';
import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';

class LocalAlbumDetailScreen extends StatelessWidget {
  const LocalAlbumDetailScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.songs,
    this.inlineArtwork,
    this.thumbnailUrl,
  });

  final String title;
  final String subtitle;
  final List<Song> songs;
  final dynamic inlineArtwork; // Uint8List?
  final String? thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);
    
    final dummySong = Song(
      id: 'dummy',
      title: title,
      artist: subtitle,
      album: title,
      uri: '',
      inlineArtwork: inlineArtwork,
      thumbnailUrl: thumbnailUrl,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 350,
            pinned: true,
            stretch: true,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  SongThumbnail(song: dummySong),
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
                  Text(title, 
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)
                  )),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _playAll(context, songs, shuffle: false),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Reproducir'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => _playAll(context, songs, shuffle: true),
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
            songs: songs,
            minTileWidth: settings.songTileMinWidth,
            selectedSongId: context.watch<PlaybackController>().currentSong?.id,
            onTap: (song, i) async {
              final pb = context.read<PlaybackController>();
              await pb.setQueue(songs, startIndex: i);
              if (!context.mounted) return;
              Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
                const PlayerScreen(),
                routeName: kPlayerRouteName,
                style: settings.transitionStyle,
                durationMs: settings.transitionDurationMs,
              );
            },
          ),
          // 100px era insuficiente: mini-player + nav suman ~160px →
          // varias canciones del final quedaban tapadas.
          SliverToBoxAdapter(
            child: SizedBox(
                height: 200 + MediaQuery.viewPaddingOf(context).bottom),
          ),
        ],
      ),
    );
  }

  Future<void> _playAll(BuildContext context, List<Song> songs, {required bool shuffle}) async {
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
}
