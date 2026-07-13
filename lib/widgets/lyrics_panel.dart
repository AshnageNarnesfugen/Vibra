import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/contrast.dart';
import '../models/lyrics.dart';
import '../providers/lyrics_controller.dart';
import '../providers/playback_controller.dart';

/// Panel de letras sincronizadas.
///
/// **Estados**:
///   - loading: spinner.
///   - notFound: mensaje + botón reintentar.
///   - error: igual que notFound (lrclib falló).
///   - loaded synced: ListView con la línea actual destacada (escala +
///     color primario + fontWeight) y auto-scroll suave a su posición.
///   - loaded plain: ListView estático sin highlight.
///
/// **Auto-scroll**: cuando cambia el `activeIndex` del controller, usamos
/// `Scrollable.ensureVisible` sobre un `GlobalKey` adjunto al tile activo.
/// El callback va dentro de un `addPostFrameCallback` para que el ListView
/// ya haya reconstruido la celda con la key en su nueva posición.
///
/// **Tap en línea**: seek del audio principal a ese timestamp.
class LyricsPanel extends StatefulWidget {
  const LyricsPanel({super.key, this.transparent = false});

  /// Si es `true`, el panel no pinta su fondo gradient ni border. Útil
  /// cuando se monta como overlay sobre el cover (portrait mode) donde
  /// el scrim externo ya provee el contraste. Default `false` para usos
  /// standalone (landscape, reemplazo del queue panel).
  final bool transparent;

  @override
  State<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<LyricsPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _activeKey = GlobalKey();
  LyricsController? _ctrl;
  int _lastIndex = -2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<LyricsController>();
    if (_ctrl != next) {
      _ctrl?.activeIndex.removeListener(_onActiveChanged);
      _ctrl = next;
      _ctrl!.activeIndex.addListener(_onActiveChanged);
    }
  }

  @override
  void dispose() {
    _ctrl?.activeIndex.removeListener(_onActiveChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onActiveChanged() {
    final idx = _ctrl?.activeIndex.value ?? -1;
    if (idx == _lastIndex) return;
    _lastIndex = idx;
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          alignment: 0.4,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<LyricsController>();
    final scheme = Theme.of(context).colorScheme;

    if (widget.transparent) {
      // Sin chrome: el caller provee el fondo (scrim sobre cover).
      return _buildContent(context, ctrl);
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        // Mismo patrón que el overlay vertical (78% bordes → 92% centro)
        // para que el panel se vea como una superficie sólida del tema.
        // Antes los alphas eran 0.25 / 0.10 → casi transparente y las
        // líneas inactivas (35-55% alpha) se mezclaban con el bg.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface.withValues(alpha: 0.78),
            scheme.surface.withValues(alpha: 0.92),
            scheme.surface.withValues(alpha: 0.78),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: _buildContent(context, ctrl),
      ),
    );
  }

  Widget _buildContent(BuildContext context, LyricsController ctrl) {
    switch (ctrl.status) {
      case LyricsStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case LyricsStatus.idle:
        return _Empty(
          icon: Icons.music_note_rounded,
          text: 'Sin canción reproduciéndose.',
        );
      case LyricsStatus.notFound:
        return _Empty(
          icon: Icons.lyrics_outlined,
          text: 'No encontramos letra para esta canción.',
          actionLabel: 'Reintentar',
          onAction: ctrl.retry,
        );
      case LyricsStatus.error:
        return _Empty(
          icon: Icons.error_outline_rounded,
          text: 'Error al cargar la letra.',
          actionLabel: 'Reintentar',
          onAction: ctrl.retry,
        );
      case LyricsStatus.loaded:
        final lyrics = ctrl.current;
        if (lyrics == null || lyrics.isEmpty) {
          return _Empty(
            icon: Icons.lyrics_outlined,
            text: 'Letra vacía.',
            actionLabel: 'Reintentar',
            onAction: ctrl.retry,
          );
        }
        return _LyricsList(
          lyrics: lyrics,
          activeIndex: ctrl.activeIndex,
          scrollController: _scrollController,
          activeKey: _activeKey,
          transparent: widget.transparent,
        );
    }
  }
}

class _LyricsList extends StatelessWidget {
  const _LyricsList({
    required this.lyrics,
    required this.activeIndex,
    required this.scrollController,
    required this.activeKey,
    required this.transparent,
  });

  final Lyrics lyrics;
  final ValueListenable<int> activeIndex;
  final ScrollController scrollController;
  final GlobalKey activeKey;
  final bool transparent;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: activeIndex,
      builder: (context, idx, _) {
        return ListView.builder(
          controller: scrollController,
          // Padding superior/inferior generoso para que la primera/última
          // línea puedan centrarse cuando son la activa (el auto-scroll
          // usa alignment 0.4 y necesita espacio para llevarlas allí).
          padding: const EdgeInsets.symmetric(vertical: 120, horizontal: 24),
          itemCount: lyrics.lines.length,
          itemBuilder: (context, i) {
            final line = lyrics.lines[i];
            final isActive = lyrics.synced && i == idx;
            // El estado "pasada" (líneas ya cantadas) se atenúa más que
            // las "futuras" para guiar la mirada del usuario.
            final isPast = lyrics.synced && idx >= 0 && i < idx;
            return _LyricLineTile(
              key: isActive ? activeKey : null,
              text: line.text,
              isActive: isActive,
              isPast: isPast,
              isSynced: lyrics.synced,
              transparent: transparent,
              onTap: lyrics.synced
                  ? () => context.read<PlaybackController>().seek(line.time)
                  : null,
            );
          },
        );
      },
    );
  }
}

/// Una línea de la letra con animación al volverse activa.
class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    super.key,
    required this.text,
    required this.isActive,
    required this.isPast,
    required this.isSynced,
    required this.transparent,
    this.onTap,
  });

  final String text;
  final bool isActive;
  final bool isPast;
  final bool isSynced;

  /// Modo overlay sobre cover. El fondo detrás (scrim oscuro con blur)
  /// es predecible, así que forzamos colores blancos en lugar de los
  /// del scheme — más legible y no depende de `ensureReadable` que
  /// asumía contraste contra `surface`.
  final bool transparent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final Color color;
    if (transparent) {
      // El scrim del overlay usa `scheme.surface` con alpha alta. El
      // contraste correcto para texto sobre surface es `scheme.onSurface`
      // (light en dark mode, dark en light mode). Variamos alpha por
      // estado para guiar la mirada a la línea activa.
      if (!isSynced) {
        color = scheme.onSurface.withValues(alpha: 0.92);
      } else if (isActive) {
        color = scheme.onSurface;
      } else if (isPast) {
        color = scheme.onSurface.withValues(alpha: 0.40);
      } else {
        color = scheme.onSurface.withValues(alpha: 0.62);
      }
    } else {
      // Modo standalone (landscape o queue replacement): contraste vs
      // surface del scheme. ensureReadable evita el caso "primary ≈ surface".
      if (!isSynced) {
        color = scheme.onSurface.withValues(alpha: 0.85);
      } else if (isActive) {
        color = ContrastUtils.ensureReadable(
          scheme.primary,
          scheme.surface,
          target: 4.5,
        );
      } else if (isPast) {
        color = scheme.onSurface.withValues(alpha: 0.35);
      } else {
        color = scheme.onSurface.withValues(alpha: 0.55);
      }
    }

    // Tamaño/peso: la línea activa crece para enfatizar el flow musical.
    final fontSize = isActive ? 22.0 : 18.0;
    final fontWeight = isActive ? FontWeight.w700 : FontWeight.w500;

    Widget body = AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        height: 1.35,
        letterSpacing: -0.2,
      ),
      child: Text(
        text.isEmpty ? '♪' : text,
        textAlign: TextAlign.center,
      ),
    );

    if (onTap != null) {
      body = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: body,
        ),
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: body,
      );
    }

    return body;
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurface.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.7),
                fontSize: 14,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
