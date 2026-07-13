import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/layout_tokens.dart';
import '../models/song.dart';
import '../services/playlist_service.dart';

/// Bottom sheet "Guardar en playlist". Recibe las canciones a añadir; el
/// usuario elige una playlist existente o crea una nueva.
///
/// Muestra un SnackBar con el resultado al cerrar (cuántas canciones nuevas
/// se añadieron — duplicadas no cuentan).
Future<void> showSaveToPlaylistSheet(
  BuildContext context, {
  required List<Song> songs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Igual que el context sheet: navigator raíz para que la barra inferior
    // de HomeScreen no tape los items inferiores del sheet.
    useRootNavigator: true,
    builder: (ctx) => _SaveToPlaylistSheet(songs: songs),
  );
}

class _SaveToPlaylistSheet extends StatefulWidget {
  const _SaveToPlaylistSheet({required this.songs});
  final List<Song> songs;

  @override
  State<_SaveToPlaylistSheet> createState() => _SaveToPlaylistSheetState();
}

class _SaveToPlaylistSheetState extends State<_SaveToPlaylistSheet> {
  bool _busy = false;

  Future<void> _addToExisting(String playlistId) async {
    if (_busy) return;
    setState(() => _busy = true);
    final svc = context.read<PlaylistService>();
    final messenger = ScaffoldMessenger.of(context);
    final added = await svc.addSongs(playlistId, widget.songs);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(added == 0
          ? 'Ya estaba todo en la playlist.'
          : 'Añadidas $added canción${added == 1 ? '' : 'es'}.'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _createAndAdd() async {
    // Capturamos antes del primer await — sin esto el analyzer se queja de
    // "BuildContext usado a través de async gaps" y peor: si el sheet se
    // cerrara durante el dialog, el context quedaría desmontado.
    final svc = context.read<PlaylistService>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    if (_busy) return;
    setState(() => _busy = true);
    await svc.create(name: name, initialSongs: widget.songs);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text('Playlist "$name" creada con ${widget.songs.length} '
          'canción${widget.songs.length == 1 ? '' : 'es'}.'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final playlists = context.watch<PlaylistService>().playlists;

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
            // Drag handle iOS-style.
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
            Text('Guardar en playlist',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
            const SizedBox(height: 4),
            Text(
              '${widget.songs.length} canción${widget.songs.length == 1 ? '' : 'es'} '
              'a añadir',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
            ),
            SizedBox(height: tokens.gap),
            FilledButton.icon(
              onPressed: _busy ? null : _createAndAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nueva playlist'),
            ),
            SizedBox(height: tokens.gap),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    'Aún no tienes playlists.\nCrea una para empezar.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  separatorBuilder: (_, _) => Divider(
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                      height: 0),
                  itemBuilder: (context, i) {
                    final pl = playlists[i];
                    final thumb = pl.displayThumbnailUrl;
                    return ListTile(
                      onTap: _busy ? null : () => _addToExisting(pl.id),
                      contentPadding: EdgeInsets.zero,
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: thumb != null && thumb.isNotEmpty
                              ? Image.network(thumb,
                                  fit: BoxFit.cover,
                                  cacheWidth: 132,
                                  cacheHeight: 132,
                                  filterQuality: FilterQuality.low,
                                  errorBuilder: (_, _, _) =>
                                      _placeholder(scheme))
                              : _placeholder(scheme),
                        ),
                      ),
                      title: Text(pl.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${pl.songs.length} canción${pl.songs.length == 1 ? '' : 'es'}'),
                      trailing: const Icon(Icons.add_rounded),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => ColoredBox(
        color: scheme.primary.withValues(alpha: 0.15),
        child: Icon(Icons.queue_music_rounded, color: scheme.primary),
      );
}

class _NameDialog extends StatefulWidget {
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nueva playlist'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Nombre de la playlist',
          border: OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Crear'),
        ),
      ],
    );
  }
}
