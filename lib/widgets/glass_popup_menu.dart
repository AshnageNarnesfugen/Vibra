import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/settings/ui_settings.dart';

/// Item del menú con look glass. Mismo API que `PopupMenuEntry` pero
/// pensado para usarse dentro de [GlassPopupMenuButton].
class GlassMenuItem<T> {
  const GlassMenuItem({
    required this.value,
    required this.label,
    this.icon,
  });

  /// Valor devuelto a `onSelected` cuando el usuario toca este item.
  final T value;

  /// Texto principal del item.
  final String label;

  /// Icono opcional a la izquierda del label.
  final IconData? icon;
}

/// Botón de menú contextual con look glass: surface translúcida con
/// BackdropFilter (blur real del contenido detrás), borde hairline del
/// tema y esquinas redondeadas. Reemplaza el `PopupMenuButton` estándar
/// de Material — el `popupMenuTheme` global no permite añadir
/// `BackdropFilter` por sí solo, así que este widget lo monta a mano.
///
/// API similar a `PopupMenuButton<T>`:
///   - [items] en vez de `itemBuilder`.
///   - [onSelected] con el value del item tocado.
///   - [icon] opcional para el botón (default: 3-dots vertical).
class GlassPopupMenuButton<T> extends StatefulWidget {
  const GlassPopupMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.icon,
    this.tooltip,
  });

  final List<GlassMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final Widget? icon;
  final String? tooltip;

  @override
  State<GlassPopupMenuButton<T>> createState() =>
      _GlassPopupMenuButtonState<T>();
}

class _GlassPopupMenuButtonState<T> extends State<GlassPopupMenuButton<T>> {
  final MenuController _controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = UiSettingsScope.of(context);
    final radius = settings.cornerRadius.clamp(8.0, 28.0);

    // Surface translúcida (la opacidad real combina con el blur).
    final menuColor = scheme.surface.withValues(
      alpha: (0.55 + settings.effectiveSurfaceOpacity * 0.20).clamp(0.0, 1.0),
    );
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.45);

    return MenuAnchor(
      controller: _controller,
      // Hacemos el menu transparente — el blur + tint van adentro del child.
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      menuChildren: [
        // Wrapper único que contiene blur + decoración + items. Antes
        // queríamos meter el BackdropFilter por item pero eso pintaba
        // bordes duros entre cada item. Un solo blur por menu se ve
        // homogéneo y es más barato en GPU.
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: menuColor,
                border: Border.all(color: borderColor, width: 0.5),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.items.length; i++) ...[
                      _GlassMenuItemTile<T>(
                        item: widget.items[i],
                        onTap: () {
                          _controller.close();
                          widget.onSelected(widget.items[i].value);
                        },
                      ),
                      if (i < widget.items.length - 1)
                        Divider(
                          height: 0.5,
                          thickness: 0.5,
                          color: borderColor,
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          icon: widget.icon ?? const Icon(Icons.more_vert_rounded),
          tooltip: widget.tooltip,
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
        );
      },
    );
  }
}

class _GlassMenuItemTile<T> extends StatelessWidget {
  const _GlassMenuItemTile({required this.item, required this.onTap});

  final GlassMenuItem<T> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 20, color: scheme.onSurface),
                const SizedBox(width: 12),
              ],
              Flexible(
                child: Text(
                  item.label,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
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
