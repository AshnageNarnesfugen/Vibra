import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/animations/page_transitions.dart';
import '../core/settings/ui_settings.dart';
import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../providers/playback_controller.dart';
import '../screens/album_screen.dart';
import '../screens/artist_screen.dart';
import '../screens/home_screen.dart';
import '../screens/player_screen.dart';
import '../services/download_service.dart';
import 'save_to_playlist_sheet.dart';
import '../core/dev_log.dart';

/// Menú de contexto compartido para canciones (1) o álbumes/playlists (varias).
///
/// Para una canción: triggered por long-press en song tile / grid. Ofrece
/// reproducir-ahora, añadir-a-cola, ir-al-artista, ir-al-álbum, guardar en
/// playlist, descargar.
///
/// Para varias canciones (álbum, playlist): triggered por 3-dot button en
/// header. Ofrece reproducir todas, aleatorio, guardar todas en playlist,
/// descargar todas.
Future<void> showSongContextSheet(
  BuildContext context, {
  required List<Song> songs,
  String? title,
  String? subtitle,
}) {
  if (songs.isEmpty) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // CLAVE: usamos el navigator raíz para que el sheet se monte POR ENCIMA
    // de la barra inferior + mini-player (que viven en HomeScreen como hijo
    // del Stack root). Sin esto, el sheet se monta en el nested navigator
    // de la tab activa y queda tapado por la barra (los últimos ítems no se
    // pueden tocar).
    useRootNavigator: true,
    builder: (ctx) => _SongContextSheet(
      songs: songs,
      title: title,
      subtitle: subtitle,
    ),
  );
}

class _SongContextSheet extends StatelessWidget {
  const _SongContextSheet({
    required this.songs,
    this.title,
    this.subtitle,
  });

  final List<Song> songs;
  final String? title;
  final String? subtitle;

  bool get _single => songs.length == 1;
  Song get _first => songs.first;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final displayTitle = title ?? (_single ? _first.title : 'Selección');
    final displaySubtitle = subtitle ??
        (_single
            ? _first.artist
            : '${songs.length} canción${songs.length == 1 ? '' : 'es'}');
    final thumb = _first.thumbnailUrl;

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.97),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
            tokens.space(20), 12, tokens.space(20), tokens.space(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: thumb != null && thumb.isNotEmpty
                        ? Image.network(thumb,
                            fit: BoxFit.cover,
                            cacheWidth: 156,
                            cacheHeight: 156,
                            filterQuality: FilterQuality.low,
                            errorBuilder: (_, _, _) => _placeholder(scheme))
                        : _placeholder(scheme),
                  ),
                ),
                SizedBox(width: tokens.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(displaySubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: scheme.onSurface
                                    .withValues(alpha: 0.65),
                              )),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(
                color: scheme.outlineVariant.withValues(alpha: 0.3),
                height: 0),
            // ---- Acciones ----
            _Action(
              icon: Icons.play_arrow_rounded,
              label: 'Reproducir',
              onTap: () => _playAll(context, shuffle: false),
            ),
            _Action(
              icon: Icons.shuffle_rounded,
              label: 'Reproducir aleatorio',
              onTap: () => _playAll(context, shuffle: true),
            ),
            if (_single && _hasActiveQueue(context))
              // "Reproducir a continuación": inserta inmediatamente después
              // de la canción actual. No reinicia el player ni el current
              // track — solo modifica la cola. Más cómodo que "Añadir al
              // final" cuando quieres priorizar una canción.
              _Action(
                icon: Icons.playlist_play_rounded,
                label: 'Reproducir a continuación',
                onTap: () => _playNext(context),
              ),
              _Action(
                icon: Icons.queue_music_rounded,
                label: 'Añadir a la cola actual',
                onTap: () => _addToQueue(context),
              ),
            _Action(
              icon: Icons.playlist_add_rounded,
              label: 'Guardar en playlist',
              onTap: () async {
                Navigator.of(context).pop();
                await showSaveToPlaylistSheet(context, songs: songs);
              },
            ),
            // Solo para streaming: las canciones locales ya están en disco.
            // Cambia entre "Descargar" y "Quitar descarga" según estado.
            if (songs.any((s) => s.isStreaming)) _buildDownloadAction(context),
            if (_single && _first.artistBrowseId != null)
              _Action(
                icon: Icons.person_rounded,
                label: 'Ir al artista',
                onTap: () => _gotoArtist(context, _first.artistBrowseId!),
              ),
            if (_single && _first.albumBrowseId != null)
              _Action(
                icon: Icons.album_rounded,
                label: 'Ir al álbum',
                onTap: () => _gotoAlbum(
                  context,
                  _first.albumBrowseId!,
                  _first.thumbnailUrl,
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _hasActiveQueue(BuildContext context) =>
      context.read<PlaybackController>().queue.isNotEmpty;

  void _playAll(BuildContext context, {required bool shuffle}) {
    final pb = context.read<PlaybackController>();
    final settings = UiSettingsScope.of(context);
    final list = List<Song>.from(songs);
    if (shuffle) list.shuffle();
    Navigator.of(context).pop();
    // ignore: discarded_futures
    pb.setQueue(list);
    Navigator.of(context, rootNavigator: true).pushOrFocusNamed(
      const PlayerScreen(),
      routeName: kPlayerRouteName,
      style: settings.transitionStyle,
      durationMs: settings.transitionDurationMs,
    );
  }

  /// "Reproducir a continuación": inserta una o más canciones justo
  /// después de la activa, preservando lo que suena. Para múltiples
  /// canciones, las insertamos en orden inverso una por una para que
  /// la última agregada quede primera tras la activa (orden visual
  /// natural de "estas tres canciones vienen ahora, en este orden").
  void _playNext(BuildContext context) {
    final pb = context.read<PlaybackController>();
    final messenger = ScaffoldMessenger.of(context);
    // Inserción en reversa para preservar orden visual cuando son varias.
    for (final song in songs.reversed) {
      // ignore: discarded_futures
      pb.playNext(song);
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(songs.length == 1
          ? 'Se reproduce a continuación.'
          : 'Las ${songs.length} canciones se reproducen a continuación.'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// "Añadir a la cola actual": append al final SIN reiniciar el player.
  /// Antes hacíamos `setQueue` con un array nuevo que internamente
  /// llamaba `playAt` y cortaba un fragmento del audio — el nuevo
  /// `addToCurrentQueue` solo muta la lista sin tocar el player.
  void _addToQueue(BuildContext context) {
    final pb = context.read<PlaybackController>();
    final messenger = ScaffoldMessenger.of(context);
    for (final song in songs) {
      // ignore: discarded_futures
      pb.addToCurrentQueue(song);
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(
          'Añadidas ${songs.length} canción${songs.length == 1 ? '' : 'es'} '
          'al final de la cola.'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _gotoArtist(BuildContext context, String browseId) {
    final s = UiSettingsScope.of(context);
    // Capturar el root navigator ANTES de cerrar el sheet — su context
    // queda desactivado tras el pop.
    final rootNav = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).pop();
    // Cierra la vista Reproduciendo si está abierta: ArtistScreen se pushea
    // en el navigator de la TAB, que queda DEBAJO del player (vive en el
    // root navigator). Sin esto la navegación "funcionaba" pero tapada —
    // el usuario daba tap sin ver nada hasta minimizar el player.
    rootNav.popUntil((r) => r.settings.name != kPlayerRouteName);
    TabNavigation.pushInActiveTab(
      ArtistScreen(browseId: browseId),
      style: s.transitionStyle,
      durationMs: s.transitionDurationMs,
    );
  }

  void _gotoAlbum(BuildContext context, String browseId, String? thumb) {
    final s = UiSettingsScope.of(context);
    final rootNav = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).pop();
    // Mismo caso que _gotoArtist: cerrar el player para que AlbumScreen
    // quede visible de inmediato.
    rootNav.popUntil((r) => r.settings.name != kPlayerRouteName);
    TabNavigation.pushInActiveTab(
      AlbumScreen(browseId: browseId, initialThumb: thumb),
      style: s.transitionStyle,
      durationMs: s.transitionDurationMs,
    );
  }

  /// Acción "Descargar" / "Quitar descarga". Cambia el label y el icono
  /// según el estado actual del DownloadService.
  Widget _buildDownloadAction(BuildContext context) {
    final service = context.watch<DownloadService?>();
    if (service == null) {
      // El service falló al inicializar — exponer "no disponible".
      return const _Action(
        icon: Icons.cloud_off_rounded,
        label: 'Descargas no disponibles',
        onTap: _noop,
      );
    }
    final streamable = songs.where((s) => s.isStreaming).toList();
    if (streamable.isEmpty) return const SizedBox.shrink();

    final allDownloaded =
        streamable.every((s) => service.isDownloaded(s.id));
    if (allDownloaded) {
      return _Action(
        icon: Icons.download_done_rounded,
        label: _single ? 'Quitar descarga' : 'Quitar descargas',
        onTap: () => _deleteDownloads(context, service, streamable),
      );
    }
    // "En cola" cubre tanto la descarga activa como las pendientes que
    // esperan turno. Con la cola secuencial, encolar un tema que ya está
    // en cola es no-op; reflejamos ese estado en el label.
    final anyQueued =
        streamable.any((s) => service.isQueued(s.id));
    return _Action(
      icon: anyQueued
          ? Icons.downloading_rounded
          : Icons.download_rounded,
      label: anyQueued
          ? 'En cola…'
          : (_single ? 'Descargar para offline' : 'Descargar todas'),
      onTap: anyQueued
          ? _noop
          : () => _startDownloads(context, service, streamable),
    );
  }

  static void _noop() {}

  void _startDownloads(
      BuildContext context, DownloadService service, List<Song> targets) {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(
          'Descargando ${targets.length} canción${targets.length == 1 ? '' : 'es'}…'),
      duration: const Duration(seconds: 2),
    ));
    // Fire-and-forget en paralelo; el service notifica progreso vía
    // ChangeNotifier — la UI que escucha se actualiza sola.
    for (final s in targets) {
      // ignore: discarded_futures
      service.download(s).catchError((e) {
        devLog('download ${s.id} failed: $e');
      });
    }
  }

  Future<void> _deleteDownloads(
      BuildContext context, DownloadService service, List<Song> targets) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    for (final s in targets) {
      await service.delete(s.id);
    }
    messenger.showSnackBar(SnackBar(
      content: Text('${targets.length} descarga${targets.length == 1 ? '' : 's'} '
          'eliminada${targets.length == 1 ? '' : 's'}.'),
      duration: const Duration(seconds: 2),
    ));
  }

  Widget _placeholder(ColorScheme scheme) => ColoredBox(
        color: scheme.primary.withValues(alpha: 0.15),
        child: Icon(Icons.music_note_rounded, color: scheme.primary),
      );
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Material transparente: el sheet envuelve todo en un Container con
    // color de fondo, y ListTile necesita un Material ancestro donde
    // pintar sus ink splashes. Sin esto Flutter tira la assertion
    // "ListTile background color or ink splashes may be invisible" en
    // debug (inocua pero spamea el log) y los splashes no se ven.
    return Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: onTap,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(label),
      ),
    );
  }
}
