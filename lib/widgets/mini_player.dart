import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';
import '../providers/playback_controller.dart';
import '../screens/player_screen.dart';
import 'adaptive_color.dart';
import 'glass_card.dart';
import 'marquee_text.dart';
import 'song_thumbnail.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final pb = context.watch<PlaybackController>();
    final song = pb.currentSong;
    if (song == null) return const SizedBox.shrink();

    final tokens = LayoutTokensScope.of(context);
    final settings = UiSettingsScope.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.space(12),
        vertical: tokens.space(6),
      ),
      child: GlassCard(
        padding: EdgeInsets.all(tokens.space(10)),
        onTap: () =>
            Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
          const PlayerScreen(),
          routeName: kPlayerRouteName,
          style: settings.transitionStyle,
          durationMs: settings.transitionDurationMs,
        ),
        // Contraste dinámico: el mini-player vive sobre el bg de la app.
        // Cuando la portada de la canción es muy brillante en su parte
        // inferior (donde aparece el mini-player), los iconos/texto
        // claros desaparecen. AdaptiveColor mide la zona detrás y elige
        // tinta clara u oscura → siempre legible.
        child: AdaptiveColor(
          builder: (context, color) => Row(
            children: [
              ClipRRect(
                borderRadius: tokens.radiusSm,
                child: SongThumbnail(song: song, size: 44),
              ),
              SizedBox(width: tokens.gap),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      song.title,
                      textAlign: TextAlign.left,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                    ),
                    MarqueeText(
                      song.artist,
                      textAlign: TextAlign.left,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: color.withValues(alpha: 0.70),
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: pb.previous,
                color: color,
              ),
              IconButton(
                icon: Icon(
                  pb.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 32,
                ),
                onPressed: pb.togglePlayPause,
                color: color,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: pb.next,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
