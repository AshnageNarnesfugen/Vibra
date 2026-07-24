// Cola: handle arrastrable, lista reordenable y tiles.
//
// `part` de player_screen.dart: las clases del player comparten
// estado privado entre sí, así que viven en una sola librería
// partida en archivos por concern (imports en el archivo raíz).
part of '../player_screen.dart';

/// Handle del queue: caret animado + "Tu fila · N". El widget no tiene fondo
/// para no romper la integración con la paleta del bg; sólo respeta el
/// gesture área completo (vertical drag + tap).
class _QueueHandle extends StatelessWidget {
  const _QueueHandle({
    required this.queueLength,
    required this.queueAnim,
    required this.onTap,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
  });

  final int queueLength;
  final Animation<double> queueAnim;
  final VoidCallback onTap;
  final GestureDragUpdateCallback onVerticalDragUpdate;
  final GestureDragEndCallback onVerticalDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: SizedBox(
        height: _PortraitPlayer._handleHeight,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Barrita "drag indicator" estilo iOS — hint visual fuerte
            // de que el panel es deslizable vertical. Material la usa en
            // sus modal sheets; replicamos el patrón aquí para que el
            // usuario sepa al instante que la franja del queue es
            // interactiva con swipe up/down.
            //
            // 36px de ancho × 4px de alto es la spec de Material para
            // drag handles. El color va con onSurface a baja opacidad
            // así no compite con el contenido pero sigue visible.
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            AdaptiveColor(
              builder: (context, adaptive) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: queueAnim,
                    builder: (_, _) => Transform.rotate(
                      angle: queueAnim.value * math.pi,
                      child: Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 20,
                        color: adaptive,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Tu fila',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      letterSpacing: 0.2,
                      color: adaptive,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '· $queueLength',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lista scrolleable de la cola usada por el portrait expandido.
/// Reusa `_QueueTile` para mantener idéntico look con el panel wide.
class _QueueListView extends StatelessWidget {
  const _QueueListView({required this.playback});

  final PlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final queue = playback.queue;
    final currentId = playback.currentSong?.id;
    // Keys ESTABLES por ocurrencia: `id` solo no alcanza (la misma canción
    // puede estar 2+ veces en la cola → keys duplicadas → exception), pero
    // `id+index` rompe el reorder (al soltar el drag, todos los items
    // desplazados cambian de índice → de key → Flutter no los matchea
    // entre frames y la animación de drop glitchea). La key correcta es
    // `id + número de ocurrencia`: la 2ª aparición de la canción X mantiene
    // su key sin importar a qué índice se mueva.
    final occurrence = <String, int>{};
    final keys = List<String>.generate(queue.length, (i) {
      final id = queue[i].id;
      final n = occurrence[id] = (occurrence[id] ?? 0) + 1;
      return 'queue-$id-$n';
    });
    // ReorderableListView en lugar de ListView para soportar el drag &
    // drop por handle. La animación nativa de Material levanta el tile
    // con elevación y desliza el resto suavemente — se siente como
    // una app dedicada de música.
    return ReorderableListView.builder(
      padding: EdgeInsets.zero,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: queue.length,
      // buildDefaultDragHandles: false → no queremos el handle invisible
      // que cubre todo el tile. Nuestro handle es un IconButton específico
      // al final del tile (envuelto en ReorderableDragStartListener).
      buildDefaultDragHandles: false,
      // Proxy "levantado" cuando se está arrastrando: replica el tile
      // sin fondo translúcido y con un borde sutil para que parezca
      // "despegado" del resto de la lista.
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final scheme = Theme.of(context).colorScheme;
            final elevation =
                Curves.easeInOut.transform(animation.value) * 6;
            return Material(
              elevation: elevation,
              color: scheme.surfaceContainerHighest
                  .withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(10),
              child: child,
            );
          },
        );
      },
      // `onReorderItem` (más nuevo) ajusta `newIndex` internamente, pero
      // nuestro `reorderQueue` ya hace ese ajuste explícito + maneja el
      // `_index` activo y la cola original de shuffle. Mantener `onReorder`
      // hasta que migremos toda la lógica al nuevo callback.
      // ignore: deprecated_member_use
      onReorder: playback.reorderQueue,
      itemBuilder: (context, i) {
        final song = queue[i];
        final isCurrent = song.id == currentId;
        return _QueueTile(
          // Key estable por ocurrencia (ver cálculo de `keys` arriba).
          key: ValueKey(keys[i]),
          index: i,
          song: song,
          isCurrent: isCurrent,
          onTap: () => playback.playAt(i),
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.index,
    required this.song,
    required this.isCurrent,
    required this.onTap,
  });

  /// Posición del tile en la cola — necesaria para el
  /// `ReorderableDragStartListener` que envuelve el handle.
  final int index;
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Highlight de la canción activa: fondo ligeramente más oscuro
    // + borde izquierdo de color primary como acento. Hace que el item
    // activo se distinga al instante incluso con scroll rápido.
    final highlightBg = isCurrent
        ? scheme.onSurface.withValues(alpha: 0.08)
        : Colors.transparent;

    return Material(
      color: highlightBg,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: isCurrent
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: scheme.primary,
                      width: 3,
                    ),
                  ),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SongThumbnail(song: song, size: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                        color: isCurrent ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.equalizer_rounded,
                      size: 18, color: scheme.primary),
                ),
              // Handle de drag — SOLO esta zona inicia el reorder gesture.
              // El resto del tile sigue respondiendo al tap (play). El
              // `ReorderableDragStartListener` es la API oficial para
              // restringir la activación del drag a un sub-widget.
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6),
                  child: Icon(
                    Icons.drag_handle_rounded,
                    size: 22,
                    color: scheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
