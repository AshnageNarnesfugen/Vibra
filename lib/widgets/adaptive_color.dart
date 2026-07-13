import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/adaptive_luminance_service.dart';

/// Envuelve un child y le pasa un color dinámico que contrasta con lo que
/// hay DETRÁS del widget en pantalla.
///
/// Lee el rect global del child via `localToGlobal` después del layout, lo
/// normaliza contra el tamaño de pantalla y consulta el [LuminanceMap] del
/// [AdaptiveLuminanceService].
///
/// **Decisión por contraste real (no por threshold)**: para cada candidato
/// ([light] y [dark]) se computa el ratio de contraste WCAG contra la
/// luminancia del área y gana el de mayor ratio. Esto corrige el caso de
/// fondos de luminancia media (portadas blureadas grisáceas) donde el
/// threshold binario elegía blanco con ratio ~2:1 (ilegible).
///
/// **Histéresis anti-flicker**: una vez elegido un color, solo se cambia
/// si el otro candidato lo supera por >15% de ratio. Sin esto, fondos
/// animados (ambient video) que oscilan alrededor del punto de equilibrio
/// hacían parpadear los iconos entre blanco y negro.
///
/// **Halo de protección automático**: cuando ni el mejor candidato alcanza
/// ratio 4.5:1 (fondo de luminancia media) o el área es MIXTA (mitad
/// clara/mitad oscura, detectado por el rango min–max del LuminanceMap),
/// se añade una sombra suave del color opuesto detrás del texto/icono —
/// la misma técnica que usan los subtítulos para ser legibles sobre
/// cualquier video. El halo solo aparece cuando hace falta; sobre fondos
/// claramente oscuros o claros no hay sombra.
///
/// Uso típico:
/// ```dart
/// AdaptiveColor(
///   builder: (context, color) => Icon(Icons.arrow_back, color: color),
/// )
/// ```
class AdaptiveColor extends StatefulWidget {
  const AdaptiveColor({
    super.key,
    required this.builder,
    this.light = Colors.white,
    this.dark = Colors.black,
    this.duration = const Duration(milliseconds: 250),
  });

  /// Color a usar cuando el bg es oscuro.
  final Color light;

  /// Color a usar cuando el bg es claro.
  final Color dark;

  /// Duración de la animación entre cambios de color.
  final Duration duration;

  /// Builder del child. Recibe el color elegido para que lo aplique como
  /// quiera (Icon.color, TextStyle.color, IconButton.color, etc.).
  final Widget Function(BuildContext context, Color color) builder;

  @override
  State<AdaptiveColor> createState() => _AdaptiveColorState();
}

class _AdaptiveColorState extends State<AdaptiveColor> {
  Color? _color;
  bool _needsHalo = false;
  bool? _pickedLight;
  AdaptiveLuminanceService? _service;
  Timer? _debounce;

  /// Debounce de re-sampleo. El bg (ambient video) actualiza el mapa de
  /// luminancia hasta 4×/seg; con 14 instancias de AdaptiveColor en
  /// pantalla eso son 56 queries de layout/seg (findRenderObject +
  /// localToGlobal). Coalescemos ráfagas en una sola muestra cada 90ms —
  /// imperceptible para el ojo y corta el trabajo a ~1/3.
  void _onMapChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 90), _scheduleSample);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<AdaptiveLuminanceService>();
    if (_service != next) {
      _service?.removeListener(_onMapChanged);
      _service = next;
      next.addListener(_onMapChanged);
    }
    // Primer sample inmediato (sin debounce) para que el color correcto
    // aparezca al montar, no 90ms después.
    _scheduleSample();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _service?.removeListener(_onMapChanged);
    super.dispose();
  }

  /// Ratio de contraste WCAG entre dos luminancias LINEALES.
  static double _ratio(double a, double b) {
    final hi = a > b ? a : b;
    final lo = a > b ? b : a;
    return (hi + 0.05) / (lo + 0.05);
  }

  void _scheduleSample() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final service = _service;
      if (service == null) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      final media = MediaQuery.maybeSizeOf(context);
      if (media == null || media.width <= 0 || media.height <= 0) return;
      final origin = box.localToGlobal(Offset.zero);
      final normRect = Rect.fromLTWH(
        origin.dx / media.width,
        origin.dy / media.height,
        box.size.width / media.width,
        box.size.height / media.height,
      );
      final stats = service.map.statsInNormRect(normRect);

      // El map guarda luma GAMMA (perceptual). Para el ratio WCAG hay que
      // convertir a luminancia LINEAL: aproximación estándar sRGB ^2.2.
      final bgLinear = math.pow(stats.avg, 2.2).toDouble();
      final ratioLight =
          _ratio(widget.light.computeLuminance(), bgLinear);
      final ratioDark = _ratio(widget.dark.computeLuminance(), bgLinear);

      // Elección con histéresis: el color "retador" debe superar al
      // actual por >15% para destronarlo. Primera muestra → gana el mejor.
      bool pickLight;
      final prev = _pickedLight;
      if (prev == null) {
        pickLight = ratioLight >= ratioDark;
      } else if (prev) {
        pickLight = ratioDark <= ratioLight * 1.15;
      } else {
        pickLight = ratioLight > ratioDark * 1.15;
      }

      final bestRatio = pickLight ? ratioLight : ratioDark;
      // Fondo mixto: el rango de luma dentro del área supera 0.45 → hay
      // zonas claras Y oscuras detrás del mismo widget. El promedio
      // miente y ningún color único funciona en toda el área.
      final mixed = (stats.max - stats.min) > 0.45;
      // 3.0 como piso para el halo (no 4.5): el texto/iconos del player
      // son grandes (>18px bold equivalente) donde WCAG acepta 3:1. Pedir
      // 4.5 metía halo en fondos donde la tinta ya se leía bien.
      final needsHalo = bestRatio < 3.0 || mixed;

      final newColor = pickLight ? widget.light : widget.dark;
      if (_color != newColor ||
          _needsHalo != needsHalo ||
          _pickedLight != pickLight) {
        setState(() {
          _color = newColor;
          _needsHalo = needsHalo;
          _pickedLight = pickLight;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Color inicial: usamos el blanco por defecto antes de la primera
    // medición. AnimatedDefaultTextStyle anima la transición cuando llegue
    // la primera muestra real.
    final color = _color ?? widget.light;
    // Halo del color OPUESTO a la tinta: tinta clara → halo oscuro y
    // viceversa. blurRadius 7 difumina lo suficiente para no verse como
    // "borde duro" pero sí separar la tinta del fondo problemático.
    final haloColor = (_pickedLight ?? true) ? Colors.black : Colors.white;
    final shadows = _needsHalo
        ? <Shadow>[
            Shadow(
              color: haloColor.withValues(alpha: 0.55),
              blurRadius: 7,
            ),
          ]
        : const <Shadow>[];
    return AnimatedDefaultTextStyle(
      duration: widget.duration,
      curve: Curves.easeOutCubic,
      style: TextStyle(color: color, shadows: shadows),
      child: IconTheme(
        // Mismo color + halo para iconos descendientes — así `Icon` sin
        // color explícito hereda tanto la tinta como la sombra.
        data: IconThemeData(color: color, shadows: shadows),
        child: widget.builder(context, color),
      ),
    );
  }
}
