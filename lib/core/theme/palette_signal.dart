import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Paleta extraída de una portada.
///
/// **dominant**: el color con MÁS pixels en la imagen (suele ser el fondo
/// ambiental — gris, beige, oscuro). NO siempre es el más representativo
/// de "la vibra" del album.
/// **accent**: el más saturado disponible (vibrant > lightVibrant > etc).
///
/// Los demás campos son los swatches crudos de palette_generator. El shader
/// del background los usa según [BackgroundPaletteMode] elegido por el
/// usuario — algunos modos prefieren los vibrantes (la "vibra") sobre el
/// dominante (el "fondo"), que es lo que el usuario suele querer ver
/// reflejado en el gradiente animado.
@immutable
class AlbumPalette {
  const AlbumPalette({
    required this.dominant,
    required this.accent,
    this.vibrant,
    this.lightVibrant,
    this.darkVibrant,
    this.muted,
    this.lightMuted,
    this.darkMuted,
    this.isUserPick = false,
  });

  final Color dominant;
  final Color accent;
  final Color? vibrant;
  final Color? lightVibrant;
  final Color? darkVibrant;
  final Color? muted;
  final Color? lightMuted;
  final Color? darkMuted;

  /// True cuando los slots dominant/accent fueron elegidos EXPLÍCITAMENTE
  /// por el usuario en el picker de paleta. El theme builder usa este
  /// flag para respetar los roles tal cual: con paletas automáticas
  /// re-ordena dominant/accent por luminancia (palette_generator no
  /// garantiza roles consistentes), pero con un pick manual ese re-orden
  /// ANULABA la elección — el usuario cambiaba "Acento" y el theme lo
  /// relegaba a hint de texto según le conviniera a la heurística.
  final bool isUserPick;
}

/// Recibe los bytes de la portada actual y expone:
///   - [palette]: colores derivados (alimenta el tema)
///   - [artworkBytes]: los mismos bytes en bruto (alimentan el background si
///     el usuario activó "usar carátula como fondo")
///
/// Cachea por hash de bytes para evitar trabajo repetido al rebuild.
class PaletteSignal extends ChangeNotifier {
  AlbumPalette? _palette;
  Uint8List? _artworkBytes;
  String? _artworkUrl; // NUEVO: Para carga inmediata via URL
  int? _lastBytesHash;

  /// Override de la paleta usada por TODA la app cuando está set. Lo
  /// alimenta `AmbientVideoPaletteService` para el modo "iluminación
  /// cinematográfica" — la UI sigue los colores del music video en vez
  /// de los de la portada estática. Cuando vuelve a `null`, se usa la
  /// paleta normal extraída del album art.
  AlbumPalette? _ambientOverride;

  /// Override del USUARIO: cuando el algoritmo de extracción elige un
  /// dominant que al usuario no le gusta, abre el panel de "Cambiar
  /// color" y elige otro swatch de la paleta. Esa elección queda como
  /// override hasta que el usuario la quite o cambie de canción.
  /// Prioridad: ambient (video) > user > album.
  AlbumPalette? _userOverride;

  /// Paleta efectiva: ambient > user > album.
  AlbumPalette? get palette =>
      _ambientOverride ?? _userOverride ?? _palette;

  /// Paleta cruda del album art (sin override). Útil para tracking/debug.
  AlbumPalette? get rawAlbumPalette => _palette;

  Uint8List? get artworkBytes => _artworkBytes;
  String? get artworkUrl => _artworkUrl;

  /// Set/limpia el override ambient. Notifica a todo el sistema (theme,
  /// shader, AdaptiveLuminance) — el cambio se propaga inmediato.
  ///
  /// Dedupe por hash de los 3 colores principales: la mayoría de ticks
  /// del ambient devuelven una paleta interpolada casi idéntica (cambios
  /// sub-pixel en la luminancia que no perceptibles). Evitamos rebuild
  /// global del theme/shader si el resultado es prácticamente el mismo.
  int? _lastAmbientHash;
  void setAmbientOverride(AlbumPalette? next) {
    if (next == null) {
      if (_ambientOverride == null) return;
      _ambientOverride = null;
      _lastAmbientHash = null;
      notifyListeners();
      return;
    }
    final hash = Object.hash(
      next.dominant.toARGB32(),
      next.accent.toARGB32(),
      next.vibrant?.toARGB32(),
    );
    if (_lastAmbientHash == hash) return;
    _lastAmbientHash = hash;
    _ambientOverride = next;
    notifyListeners();
  }

  Future<void> updateFromBytes(Uint8List? bytes) async {
    if (bytes == null) {
      clear();
      return;
    }
    final hash = Object.hashAll(bytes.take(256));
    if (hash == _lastBytesHash && _palette != null) return;

    // Carátula nueva → el override que el usuario eligió en la anterior
    // ya no aplica. Reset.
    if (_userOverride != null) _userOverride = null;
    _lastBytesHash = hash;
    _artworkBytes = bytes;
    // IMPORTANTE: Notificamos inmediatamente que ya tenemos los bytes para el fondo
    notifyListeners();

    try {
      // 192px (antes 96): da más información a palette_generator para
      // distinguir swatches vibrantes vs muted. Con 96px, álbumes con
      // detalles de color pequeños (tipo "Beautiful Circus" donde el
      // naranja vibrante ocupa menos del 30% del pixel count) terminaban
      // catalogados como puro verde-gris muted.
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 192,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final generator = await PaletteGenerator.fromImage(
        image,
        // 24 colores (antes 12) — más granularidad para que el algoritmo
        // separe los tonos vibrantes minoritarios del wash dominante.
        maximumColorCount: 24,
      );
      image.dispose();

      final dominant = generator.dominantColor?.color ??
          generator.vibrantColor?.color ??
          generator.mutedColor?.color;

      // **Custom vibrant override**: palette_generator clasifica como
      // `vibrantColor` solo swatches que cumplen umbrales de saturación
      // FIJOS. Álbumes mayormente muted pero con detalles vibrantes
      // (logos, prendas) suelen quedar con vibrantColor = null aunque
      // SÍ tengan un naranja brillante minoritario.
      //
      // Aquí hacemos nuestro propio scoring: rank de saturación * sqrt(count)
      // sobre TODOS los paletteColors. El sqrt amortigua el efecto del
      // dominante (que tiene 10× más pixels que cualquier vibrante).
      Color? bestVibrant = generator.vibrantColor?.color;
      if (bestVibrant == null ||
          HSLColor.fromColor(bestVibrant).saturation < 0.45) {
        final ranked = generator.paletteColors.toList()
          ..sort((a, b) {
            final sa = HSLColor.fromColor(a.color).saturation;
            final sb = HSLColor.fromColor(b.color).saturation;
            // Ignora swatches casi grises (saturación < 0.20).
            if (sa < 0.20 && sb < 0.20) return b.population - a.population;
            final wa = sa * _amortizedCount(a.population);
            final wb = sb * _amortizedCount(b.population);
            return wb.compareTo(wa);
          });
        if (ranked.isNotEmpty) {
          final top = ranked.first;
          final topSat = HSLColor.fromColor(top.color).saturation;
          // Solo override si nuestro pick es notablemente más saturado.
          if (bestVibrant == null ||
              topSat > HSLColor.fromColor(bestVibrant).saturation + 0.10) {
            bestVibrant = top.color;
          }
        }
      }

      final accent = bestVibrant ??
          generator.lightVibrantColor?.color ??
          generator.darkVibrantColor?.color ??
          generator.dominantColor?.color;

      _artworkBytes = bytes;
      _lastBytesHash = hash;
      if (dominant != null && accent != null) {
        _palette = AlbumPalette(
          dominant: dominant,
          accent: accent,
          vibrant: bestVibrant ?? generator.vibrantColor?.color,
          lightVibrant: generator.lightVibrantColor?.color,
          darkVibrant: generator.darkVibrantColor?.color,
          muted: generator.mutedColor?.color,
          lightMuted: generator.lightMutedColor?.color,
          darkMuted: generator.darkMutedColor?.color,
        );
      }
      notifyListeners();
    } catch (_) {
      _artworkBytes = bytes;
      _lastBytesHash = hash;
      notifyListeners();
    } finally {
    }
  }

  /// Setea/limpia el override del usuario. Si [next] es null, la paleta
  /// vuelve al pick automático del algoritmo de extracción.
  void setUserOverride(AlbumPalette? next) {
    if (next == null) {
      if (_userOverride == null) return;
      _userOverride = null;
      notifyListeners();
      return;
    }
    _userOverride = next;
    notifyListeners();
  }

  /// Cache de `availableSwatches` — el getter se llama en cada rebuild
  /// del Consumer del botón de paleta en el AppBar, y el dedup loop es
  /// O(n²). Cacheamos por identidad de `_palette` (si la carátula no
  /// cambió, el resultado no cambia). Invalida en `updateFromBytes` /
  /// `clear()` cuando el palette cambia.
  AlbumPalette? _swatchesCacheKey;
  List<Color>? _swatchesCache;

  /// Lista de swatches únicos detectados en la carátula — sirve al panel
  /// "Cambiar color del album" para mostrarle al usuario los candidatos
  /// disponibles. Filtrados por unicidad aproximada en RGB (Δ > 20 por
  /// canal) para no mostrar 8 chips casi-idénticos cuando el album solo
  /// tiene 3 tonos reales.
  List<Color> get availableSwatches {
    final raw = _palette;
    if (raw == null) return const [];
    if (identical(_swatchesCacheKey, raw) && _swatchesCache != null) {
      return _swatchesCache!;
    }
    final candidates = <Color>[
      raw.dominant,
      raw.accent,
      if (raw.vibrant != null) raw.vibrant!,
      if (raw.lightVibrant != null) raw.lightVibrant!,
      if (raw.darkVibrant != null) raw.darkVibrant!,
      if (raw.muted != null) raw.muted!,
      if (raw.lightMuted != null) raw.lightMuted!,
      if (raw.darkMuted != null) raw.darkMuted!,
    ];
    final out = <Color>[];
    for (final c in candidates) {
      final dup = out.any((other) =>
          ((c.r - other.r) * 255).abs() < 20 &&
          ((c.g - other.g) * 255).abs() < 20 &&
          ((c.b - other.b) * 255).abs() < 20);
      if (!dup) out.add(c);
    }
    _swatchesCacheKey = raw;
    _swatchesCache = List.unmodifiable(out);
    return _swatchesCache!;
  }

  /// Construye un `AlbumPalette` overridable por slot. Si [dominant] es
  /// null preserva el dominant actual del override previo (o cae al
  /// pick automático). Lo mismo con [accent]. Esto deja al picker UI
  /// cambiar solo el slot que el usuario toqueteó sin pisar el otro.
  ///
  /// Slots:
  ///   - `dominant`: tinte ambiental — fondos, bg de cards, scrims.
  ///   - `accent`: highlights — primary del ColorScheme, iconos,
  ///     subrayados, sliders activos.
  AlbumPalette buildOverride({Color? dominant, Color? accent}) {
    final base = _palette;
    final cur = _userOverride;
    final fallbackDom = cur?.dominant ?? base?.dominant ?? Colors.black;
    final fallbackAcc = cur?.accent ?? base?.accent ?? Colors.black;
    return AlbumPalette(
      dominant: dominant ?? fallbackDom,
      accent: accent ?? fallbackAcc,
      vibrant: base?.vibrant,
      lightVibrant: base?.lightVibrant,
      darkVibrant: base?.darkVibrant,
      muted: base?.muted,
      lightMuted: base?.lightMuted,
      darkMuted: base?.darkMuted,
      // Pick manual → el theme respeta los roles tal cual (sin re-orden
      // por luminancia). Ver [AlbumPalette.isUserPick].
      isUserPick: true,
    );
  }

  /// Atajo legacy: cambia AMBOS slots al mismo color (comportamiento
  /// del primer flujo del picker, ahora "Aleatorio" lo usa cuando el
  /// usuario quiere reset rápido).
  @Deprecated('Use buildOverride(dominant: c, accent: c) directly')
  AlbumPalette buildOverrideFromColor(Color picked) =>
      buildOverride(dominant: picked, accent: picked);

  void updateArtworkOnly(Uint8List? bytes, {String? url}) {
    _artworkBytes = bytes;
    _artworkUrl = url;
    // IMPORTANTE: Forzamos notificación para que el fondo se entere al instante
    notifyListeners();
  }

  /// Función de amortiguación para el count: `sqrt` evita que el swatch
  /// dominante (que tiene mil veces más pixels que cualquier vibrante)
  /// gane simplemente por volumen. Con sqrt, doblar el count solo multiplica
  /// el peso por 1.41 — suficiente para preferir colores prevalentes sin
  /// aplastar a los minoritarios saturados.
  static double _amortizedCount(int population) {
    return math.sqrt(population <= 0 ? 1.0 : population.toDouble());
  }

  void clear() {
    if (_palette == null && _artworkBytes == null && _artworkUrl == null) {
      return;
    }
    _palette = null;
    _artworkBytes = null;
    _artworkUrl = null;
    _lastBytesHash = null;
    // El user override se ata a la canción/album anterior — al cambiar
    // de track se reinicia para que el algoritmo decida desde cero. El
    // usuario puede reabrir el panel si quiere overridear de nuevo.
    _userOverride = null;
    notifyListeners();
  }
}
