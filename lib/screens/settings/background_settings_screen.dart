import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/settings/ui_settings.dart';
import '../../core/theme/layout_tokens.dart';
import '../../widgets/adjustable_background_image.dart';
import '../../widgets/color_picker_sheet.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/labeled_slider.dart';
import '../../widgets/shader_background.dart';
import '../../widgets/stable_backdrop_group.dart';

class BackgroundSettingsScreen extends StatelessWidget {
  const BackgroundSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);

    // BackdropGroup hace que las GlassCards visibles compartan UN solo pase
    // de blur — sin esto cada card crea su propio BackdropFilter y se ve
    // el flash transparente al scrollear.
    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Fondo')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Tipo de fondo',
                    style: Theme.of(context).textTheme.titleMedium),
                SizedBox(height: tokens.gapSm),
                SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<BackgroundMode>(
                    groupValue: s.backgroundMode,
                    thumbColor: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.85),
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    children: {
                      for (final m in BackgroundMode.values)
                        m: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                switch (m) {
                                  BackgroundMode.solidColor =>
                                    Icons.format_color_fill_rounded,
                                  BackgroundMode.image =>
                                    Icons.image_rounded,
                                  BackgroundMode.animatedGradient =>
                                    Icons.gradient_rounded,
                                },
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(m.label),
                            ],
                          ),
                        ),
                    },
                    onValueChanged: (v) {
                      if (v == null) return;
                      ctrl.update((p) => p.copyWith(backgroundMode: v));
                    },
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.gap),
          // El override de carátula como fondo SOLO aplica en modo imagen
          // (donde la carátula reemplaza la imagen del usuario). En gradient
          // se ignora porque el gradiente ya usa la paleta de la portada; en
          // solid color no tiene sentido (un sólido es un sólido).
          if (s.backgroundMode == BackgroundMode.image) ...[
            GlassCard(
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Usar carátula como fondo'),
                    subtitle: const Text(
                      'Cuando hay una canción con portada, se muestra como '
                      'fondo. Si no hay carátula o no hay canción activa, '
                      'vuelve al fondo que definiste abajo.',
                    ),
                    value: s.useAlbumArtAsBackground,
                    onChanged: (v) => ctrl.update(
                        (p) => p.copyWith(useAlbumArtAsBackground: v)),
                  ),
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Usar video musical si disponible'),
                    subtitle: const Text(
                      'Si la canción tiene music video en YouTube, se '
                      'reproduce muteado como fondo. Si no hay video, cae '
                      'a la imagen/carátula normal.',
                    ),
                    value: s.useVideoBackgroundIfAvailable,
                    onChanged: (v) => ctrl.update(
                      (p) => p.copyWith(useVideoBackgroundIfAvailable: v),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.gap),
          ],
          if (s.backgroundMode == BackgroundMode.solidColor)
            _SolidColorSection(controller: ctrl)
          else if (s.backgroundMode == BackgroundMode.image)
            _BackgroundImageSection(controller: ctrl)
          else
            _AnimatedGradientSection(controller: ctrl),
          SizedBox(height: tokens.gap),
          // Toggle global del "ambient mode": aplica cuando hay un music
          // video reproduciéndose (en cover o como bg), independiente del
          // modo de fondo elegido.
          GlassCard(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Iluminación cinematográfica del video'),
              subtitle: const Text(
                'Cuando hay un music video activo, muestrea los colores de '
                'sus esquinas y filtra esa "luz" al resto de la UI con '
                'transiciones suaves. Inspirado en el ambient mode de '
                'YouTube. Apágalo si notas lag en gama baja.',
              ),
              value: s.useAmbientVideoPalette,
              onChanged: (v) =>
                  ctrl.update((p) => p.copyWith(useAmbientVideoPalette: v)),
            ),
          ),
          SizedBox(height: tokens.gap),
          GlassCard(
            child: Column(
              children: [
                LabeledSlider(
                  label: 'Opacidad del fondo',
                  subtitle:
                      'Bajalo para que el fondo no opaque al contenido principal.',
                  value: s.backgroundOpacity,
                  min: 0.2,
                  max: 1.0,
                  format: (v) => '${(v * 100).round()}%',
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(backgroundOpacity: v)),
                ),
                LabeledSlider(
                  label: 'Opacidad de superficies (cards)',
                  subtitle:
                      'Controla qué tan translúcidas son las tarjetas y sheets.',
                  value: s.surfaceOpacity,
                  min: 0.3,
                  max: 1.0,
                  format: (v) => '${(v * 100).round()}%',
                  onChanged: (v) =>
                      ctrl.update((p) => p.copyWith(surfaceOpacity: v)),
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

class _SolidColorSection extends StatelessWidget {
  const _SolidColorSection({required this.controller});
  final SettingsController controller;

  /// Sugerencias rápidas — al usuario le sigue siendo útil un set de
  /// presets oscuros y un blanco. El picker completo está justo al lado
  /// para libertad total (HEX/RGBA/HSL + slider HSV).
  static const _presets = [
    Color(0xFF101015),
    Color(0xFF1B1B26),
    Color(0xFF15253A),
    Color(0xFF0F2222),
    Color(0xFF231221),
    Color(0xFF1E1B14),
    Color(0xFF000000),
    Color(0xFFF6F6F8),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final s = controller.value;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Color sólido',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: () => showColorPickerSheet(
                  context,
                  initialColor: s.solidBackgroundColor,
                  allowAlpha: false,
                  title: 'Color del fondo',
                  onChanged: (c) => controller
                      .update((p) => p.copyWith(solidBackgroundColor: c)),
                ),
                icon: const Icon(Icons.colorize_rounded, size: 18),
                label: const Text('Picker'),
              ),
            ],
          ),
          SizedBox(height: tokens.gapSm),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _presets
                .map((c) => _ColorSwatch(
                      color: c,
                      selected:
                          c.toARGB32() == s.solidBackgroundColor.toARGB32(),
                      onTap: () => controller
                          .update((p) => p.copyWith(solidBackgroundColor: c)),
                    ))
                .toList(),
          ),
          SizedBox(height: tokens.gapSm),
          // Override del color sólido con el dominante de la portada — el
          // fondo SIGUE siendo un color plano (no la imagen, no el blur).
          // Útil si quieres un look minimal pero coherente con cada canción.
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Permitir que la carátula se ponga de fondo'),
            subtitle: const Text(
              'Cuando hay canción con portada, el fondo toma su color '
              'dominante (sigue siendo un color sólido, no la imagen). '
              'Sin canción vuelve al color elegido arriba.',
            ),
            value: s.useAlbumColorAsSolid,
            onChanged: (v) =>
                controller.update((p) => p.copyWith(useAlbumColorAsSolid: v)),
          ),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.white24,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}

class _BackgroundImageSection extends StatelessWidget {
  const _BackgroundImageSection({required this.controller});
  final SettingsController controller;

  Future<void> _pick(BuildContext context) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 92,
    );
    if (picked == null) return;
    controller.update(
      (p) => p.copyWith(
        backgroundImagePath: picked.path,
        backgroundImageTransform: const BackgroundImageTransform(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final s = controller.value;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Imagen de fondo',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _pick(context),
                icon: const Icon(Icons.add_photo_alternate_rounded),
                label: const Text('Elegir'),
              ),
            ],
          ),
          SizedBox(height: tokens.gap),
          if (s.backgroundImagePath == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Selecciona una imagen para colocarla como fondo. Después podrás\n'
                'arrastrarla y hacer pinch-zoom para acomodarla.',
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            Text(
              'Coloca la imagen como quieres que se vea en tu pantalla. '
              'Pellizca con dos dedos para hacer zoom · arrastra para '
              'reposicionar · doble tap para resetear.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SizedBox(height: tokens.gap),
            // Damos al editor un alto generoso — el frame interno se
            // auto-ajusta al aspecto real del teléfono.
            SizedBox(
              height: 460,
              child: BackgroundImageEditor(controller: controller),
            ),
            SizedBox(height: tokens.gap),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => controller.update(
                    (p) => p.copyWith(
                      backgroundImageTransform:
                          const BackgroundImageTransform(),
                    ),
                  ),
                  icon: const Icon(Icons.center_focus_strong_rounded),
                  label: const Text('Centrar'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => controller.update(
                    (p) => p.copyWith(clearBackgroundImagePath: true),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Quitar imagen'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AnimatedGradientSection extends StatelessWidget {
  const _AnimatedGradientSection({required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final s = controller.value;
    final preview = _previewColors(s);

    return Column(
      children: [
        // Preview en grande del shader actualmente seleccionado.
        GlassCard(
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: tokens.radius,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ShaderBackground(
                shader: s.backgroundShader,
                palette1: preview[0],
                palette2: preview[1],
                palette3: preview[2],
                speed: s.gradientSpeed,
              ),
            ),
          ),
        ),
        SizedBox(height: tokens.gap),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Estilo de animación',
                  style: Theme.of(context).textTheme.titleMedium),
              SizedBox(height: tokens.gapSm),
              Text(
                'Cada estilo es un shader GLSL. Los marcados con paleta '
                'toman los colores de la portada de la canción actual.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: tokens.gap),
              _ShaderGrid(
                selected: s.backgroundShader,
                previewColors: preview,
                speed: s.gradientSpeed,
                onSelected: (sh) => controller
                    .update((p) => p.copyWith(backgroundShader: sh)),
              ),
              SizedBox(height: tokens.gapSm),
              Text(
                s.backgroundShader.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.gap),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Colores desde la portada',
                  style: Theme.of(context).textTheme.titleMedium),
              SizedBox(height: tokens.gapSm),
              Text(
                'Cómo se eligen los 3 colores del álbum que alimentan el shader.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: tokens.gap),
              RadioGroup<BackgroundPaletteMode>(
                groupValue: s.backgroundPaletteMode,
                onChanged: (v) {
                  if (v == null) return;
                  controller
                      .update((p) => p.copyWith(backgroundPaletteMode: v));
                },
                child: Column(
                  children: [
                    for (final mode in BackgroundPaletteMode.values)
                      RadioListTile<BackgroundPaletteMode>(
                        value: mode,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        title: Text(mode.label),
                        subtitle: Text(mode.description),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.gap),
        // ─── Colores por defecto (sin canción activa) ───
        // Sin canción, el shader usa el acento del usuario + un secundario.
        // Históricamente el secundario era SIEMPRE una derivación oscura del
        // acento (el "moradito" con el acento default) — ahora es
        // configurable, con "Automático" para volver a la derivación.
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Colores sin canción',
                  style: Theme.of(context).textTheme.titleMedium),
              SizedBox(height: tokens.gapSm),
              Text(
                'Los colores del fondo cuando no hay nada reproduciéndose. '
                'El primario es el mismo acento de la app (ajustes de Tema).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: tokens.gap),
              Row(
                children: [
                  Expanded(
                    child: Text('Primario',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  _ColorSwatch(
                    color: s.fallbackAccentColor,
                    selected: false,
                    onTap: () => showColorPickerSheet(
                      context,
                      initialColor: s.fallbackAccentColor,
                      allowAlpha: false,
                      title: 'Color primario',
                      onChanged: (c) => controller
                          .update((p) => p.copyWith(fallbackAccentColor: c)),
                    ),
                  ),
                ],
              ),
              SizedBox(height: tokens.gapSm),
              Row(
                children: [
                  Expanded(
                    child: Text('Secundario',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  if (s.fallbackSecondaryColor != null)
                    TextButton(
                      onPressed: () => controller.update((p) =>
                          p.copyWith(clearFallbackSecondaryColor: true)),
                      child: const Text('Automático'),
                    ),
                  _ColorSwatch(
                    // Con secundario sin setear mostramos el derivado
                    // actual — lo que realmente se ve en el fondo.
                    color: s.fallbackSecondaryColor ?? preview[1],
                    selected: false,
                    onTap: () => showColorPickerSheet(
                      context,
                      initialColor: s.fallbackSecondaryColor ?? preview[1],
                      allowAlpha: false,
                      title: 'Color secundario',
                      onChanged: (c) => controller.update(
                          (p) => p.copyWith(fallbackSecondaryColor: c)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.gap),
        GlassCard(
          child: LabeledSlider(
            label: 'Velocidad de la animación',
            subtitle:
                'A 0 el shader queda estático · a 100% fluye rápido.',
            value: s.gradientSpeed,
            min: 0,
            max: 1,
            format: (v) => '${(v * 100).round()}%',
            onChanged: (v) =>
                controller.update((p) => p.copyWith(gradientSpeed: v)),
          ),
        ),
      ],
    );
  }

  /// Colores que muestra la preview del shader paletteAware. No tenemos
  /// acceso a la AlbumPalette aquí (vive en provider distinto), así que
  /// usamos el acento del usuario como aproximación — el shader siempre se
  /// ve coherente con el resto de la app.
  List<Color> _previewColors(UiSettings s) {
    // Mismo cálculo que computeGradientColors sin paleta: respeta el
    // secundario elegido por el usuario (o deriva del acento si es null).
    final secondary = s.fallbackSecondaryColor;
    if (secondary != null) {
      final hslSec = HSLColor.fromColor(secondary);
      return [
        s.fallbackAccentColor,
        secondary,
        hslSec
            .withLightness((hslSec.lightness * 0.45).clamp(0.0, 1.0))
            .toColor(),
      ];
    }
    final hsl = HSLColor.fromColor(s.fallbackAccentColor);
    return [
      s.fallbackAccentColor,
      hsl.withLightness((hsl.lightness * 0.7).clamp(0.0, 1.0)).toColor(),
      hsl.withLightness((hsl.lightness * 0.30).clamp(0.0, 1.0)).toColor(),
    ];
  }
}

/// Grid de tarjetas con preview en vivo del shader. Cada tile corre su propio
/// ShaderBackground pequeñito — son lightweight (mismo FragmentProgram cacheado
/// entre instancias) pero suman GPU. Si esto se vuelve pesado, se puede
/// reemplazar por screenshots estáticos sin perder la idea visual.
class _ShaderGrid extends StatelessWidget {
  const _ShaderGrid({
    required this.selected,
    required this.previewColors,
    required this.speed,
    required this.onSelected,
  });

  final BackgroundShader selected;
  final List<Color> previewColors;
  final double speed;
  final ValueChanged<BackgroundShader> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 16 / 11,
      children: [
        for (final sh in BackgroundShader.values)
          GestureDetector(
            onTap: () => onSelected(sh),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: sh == selected
                      ? scheme.primary
                      : Colors.white.withValues(alpha: 0.1),
                  width: sh == selected ? 3 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ShaderBackground(
                      shader: sh,
                      palette1: previewColors[0],
                      palette2: previewColors[1],
                      palette3: previewColors[2],
                      speed: speed,
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 6,
                      child: Text(
                        sh.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          shadows: [
                            Shadow(
                              color: Colors.black54,
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
