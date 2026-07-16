import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../core/dev_log.dart';
import '../core/settings/settings_controller.dart';

/// Extrae el color acento de la imagen de fondo custom del usuario y lo
/// cachea en settings (`backgroundImageAccentColor`). Cuando el fondo es
/// una imagen custom, ese color override al acento por defecto — la UI se
/// tiñe acorde al wallpaper, no al morado genérico.
///
/// Se llama desde:
///   1. El picker de imagen de fondo (con [force] = true) — imagen nueva,
///      re-extraer siempre.
///   2. El arranque de la app (force = false) — backfill para usuarios que
///      eligieron su imagen ANTES de que existiera esta extracción.
///
/// Preferimos vibrant sobre dominant: el dominante de la mayoría de
/// wallpapers es un tono casi-negro/casi-blanco del cielo o las sombras —
/// inservible como acento. El vibrante es "el color" que una persona
/// diría que tiene la imagen.
Future<void> ensureBackgroundImageAccent(
  SettingsController ctrl, {
  bool force = false,
}) async {
  final s = ctrl.value;
  final path = s.backgroundImagePath;
  if (path == null || path.isEmpty) return;
  if (!force && s.backgroundImageAccentColor != null) return;
  try {
    final file = File(path);
    if (!await file.exists()) return;
    final pg = await PaletteGenerator.fromImageProvider(
      FileImage(file),
      // Downscale agresivo — para extraer 1 color no hace falta analizar
      // los 2400px del original.
      size: const Size(200, 200),
      maximumColorCount: 16,
    );
    final c = pg.vibrantColor?.color ??
        pg.lightVibrantColor?.color ??
        pg.darkVibrantColor?.color ??
        pg.dominantColor?.color;
    if (c == null) return;
    // La imagen pudo cambiar mientras extraíamos (la extracción es async);
    // no pisar la config de otra imagen.
    if (ctrl.value.backgroundImagePath != path) return;
    ctrl.update((p) => p.copyWith(backgroundImageAccentColor: c));
    devLog('[BG] acento extraído de la imagen de fondo: $c');
  } catch (e) {
    devLog('[BG] extracción de acento de imagen falló: $e');
  }
}
