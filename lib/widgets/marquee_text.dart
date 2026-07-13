import 'package:flutter/material.dart';

/// Texto que **solo anima si no cabe** en el ancho disponible. Hace ping-pong
/// (va al final, espera, vuelve al inicio, espera) en vez de auto-scroll
/// infinito con repetición — es menos distractivo y más legible que un
/// marquee tradicional.
///
/// Si el texto cabe completo, se renderiza como un `Text` normal sin fade.
/// Si no, scrolls suavemente con `Curves.easeInOut`.
///
/// **Fade direccional**: el degradado lateral indica que hay más texto en
/// esa dirección. Al inicio, fade solo a la derecha; mientras anima, fade
/// en ambos lados; al llegar al final, fade solo a la izquierda. Sin fade
/// si el texto cabe completo.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
    this.maxLines = 1,
    this.speedPxPerSec = 30.0,
    this.pauseAtEdges = const Duration(milliseconds: 1500),
    this.gradientFade = true,
  });

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final int maxLines;

  /// Velocidad de desplazamiento del marquee. 30 px/s ≈ lectura cómoda.
  final double speedPxPerSec;

  /// Tiempo de pausa al llegar al inicio y al final (ping-pong).
  final Duration pauseAtEdges;

  /// Si `true`, los bordes laterales se desvanecen con un gradient cuando
  /// hay texto oculto en esa dirección (no aparece si el texto cabe).
  final bool gradientFade;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  late final ScrollController _scroll = ScrollController();

  /// Posición del scroll normalizada (0..1). Alimenta el shader del fade
  /// para decidir qué lado tiene texto oculto.
  final ValueNotifier<double> _scrollNorm = ValueNotifier<double>(0.0);
  bool _needsScroll = false;
  bool _animating = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _disposed = true;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _scrollNorm.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) {
      _scrollNorm.value = 0;
      return;
    }
    _scrollNorm.value = (_scroll.offset / max).clamp(0.0, 1.0);
  }

  /// Mide si el texto excede el ancho disponible. Si sí, arranca el bucle
  /// de animación (idempotente — si ya está corriendo, no relanza).
  void _maybeStart(double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: widget.maxLines,
      textDirection: TextDirection.ltr,
    )..layout();
    final overflows = tp.width > maxWidth;
    if (overflows != _needsScroll) {
      _needsScroll = overflows;
      // No setState aquí — corremos dentro de un build vía LayoutBuilder.
      // El cambio se reflejará en el próximo frame implícitamente porque
      // el LayoutBuilder se llama post-layout y nuestro build decide el
      // wrapping según _needsScroll.
    }
    if (overflows && !_animating) {
      _animating = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runLoop());
    } else if (!overflows && _animating) {
      _animating = false;
    }
  }

  Future<void> _runLoop() async {
    while (!_disposed && _animating && _scroll.hasClients) {
      // Esperamos al inicio.
      await Future.delayed(widget.pauseAtEdges);
      if (_disposed || !_scroll.hasClients) return;
      final maxScroll = _scroll.position.maxScrollExtent;
      if (maxScroll <= 0) {
        _animating = false;
        return;
      }
      // Ida.
      final dur = Duration(
          milliseconds: (maxScroll / widget.speedPxPerSec * 1000).round());
      await _scroll.animateTo(
        maxScroll,
        duration: dur,
        curve: Curves.easeInOut,
      );
      if (_disposed || !_scroll.hasClients) return;
      // Pausa al final.
      await Future.delayed(widget.pauseAtEdges);
      if (_disposed || !_scroll.hasClients) return;
      // Vuelta al inicio.
      await _scroll.animateTo(
        0,
        duration: dur,
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maybeStart(constraints.maxWidth);
        final base = SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Text(
            widget.text,
            style: widget.style,
            maxLines: widget.maxLines,
            softWrap: false,
            overflow: TextOverflow.visible,
            textAlign: widget.textAlign,
          ),
        );
        // Texto que cabe: sin ShaderMask. Sin esto, textos cortos se
        // veían con fade en los bordes aunque no tuvieran nada oculto.
        if (!widget.gradientFade || !_needsScroll) return base;

        return ValueListenableBuilder<double>(
          valueListenable: _scrollNorm,
          builder: (context, norm, _) {
            return _DirectionalFade(
              scrollNorm: norm,
              child: base,
            );
          },
        );
      },
    );
  }
}

/// Aplica un fade lateral dinámico al child. `scrollNorm` (0..1) controla
/// la dirección: 0 = fade solo a la derecha (estamos al inicio), 1 = fade
/// solo a la izquierda (estamos al final), valores intermedios = fade en
/// ambos lados.
///
/// La transición no es binaria: usamos un `tail` de 5% para que el fade
/// se vea suave cuando estás cerca de un extremo (sino haría un salto
/// duro al iniciar/terminar la animación).
class _DirectionalFade extends StatelessWidget {
  const _DirectionalFade({required this.scrollNorm, required this.child});

  final double scrollNorm;
  final Widget child;

  /// Porcentaje del scroll cerca de los extremos donde el fade transiciona.
  static const double _tail = 0.05;

  /// Ancho del fade en pixeles a cada lado.
  static const double _fadeWidth = 16.0;

  @override
  Widget build(BuildContext context) {
    // leftActive: 0 cuando estamos al inicio (no hay texto cortado a la
    // izquierda), 1 cuando hay texto oculto a la izquierda.
    final leftActive = (scrollNorm / _tail).clamp(0.0, 1.0);
    // rightActive: 1 al inicio (hay texto oculto a la derecha), 0 al final.
    final rightActive = ((1.0 - scrollNorm) / _tail).clamp(0.0, 1.0);
    return ShaderMask(
      shaderCallback: (rect) {
        final w = rect.width;
        if (w <= 0) {
          return const LinearGradient(colors: [Colors.black, Colors.black])
              .createShader(rect);
        }
        final t = (_fadeWidth / w).clamp(0.0, 0.45);
        // Color.lerp entre black (no fade) y transparent (fade). Si
        // leftActive=0 → black sólido (no fade); si 1 → transparent (fade
        // completo). Ídem rightActive.
        final leftColor =
            Color.lerp(Colors.black, Colors.transparent, leftActive)!;
        final rightColor =
            Color.lerp(Colors.black, Colors.transparent, rightActive)!;
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [leftColor, Colors.black, Colors.black, rightColor],
          stops: [0.0, t, 1.0 - t, 1.0],
        ).createShader(rect);
      },
      blendMode: BlendMode.dstIn,
      child: child,
    );
  }
}
