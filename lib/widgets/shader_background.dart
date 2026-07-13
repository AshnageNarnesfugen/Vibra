import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/animations/background_shader.dart';
import '../core/dev_log.dart';

/// Renderea un shader GLSL como fondo a pantalla completa.
///
/// Carga el [FragmentProgram] una sola vez por shader (cache estático), y
/// dispara repaints vía `Ticker` sin rebuildear el widget tree — el [Ticker]
/// alimenta un `ValueNotifier<double>` de tiempo que el [CustomPainter] usa
/// como `repaint` listener.
///
/// Los colores `palette*` son opcionales: si el shader no es `paletteAware`,
/// se ignoran. Si lo es y no se pasan, se usan colores por defecto neutros.
class ShaderBackground extends StatefulWidget {
  const ShaderBackground({
    super.key,
    required this.shader,
    this.palette1,
    this.palette2,
    this.palette3,
    this.speed = 0.4,
  });

  final BackgroundShader shader;
  final Color? palette1;
  final Color? palette2;
  final Color? palette3;

  /// 0..1 — multiplicador de la velocidad de animación (se pasa al uniform
  /// `u_speed` del shader).
  final double speed;

  @override
  State<ShaderBackground> createState() => _ShaderBackgroundState();
}

class _ShaderBackgroundState extends State<ShaderBackground>
    with SingleTickerProviderStateMixin {
  /// Cache global: cargar un FragmentProgram tarda ~50-100ms y es síncrono
  /// en el plugin nativo. Compartirlo entre todas las instancias evita
  /// hiccups al abrir el selector de fondo (4 previews en pantalla).
  static final Map<String, ui.FragmentProgram> _programs = {};
  static final Map<String, Future<ui.FragmentProgram>> _loading = {};

  ui.FragmentProgram? _program;
  final ValueNotifier<double> _time = ValueNotifier<double>(0.0);
  late final Ticker _ticker;
  Duration _start = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _loadShader();
  }

  @override
  void didUpdateWidget(covariant ShaderBackground old) {
    super.didUpdateWidget(old);
    if (old.shader != widget.shader) {
      _program = null;
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    final asset = widget.shader.asset;
    final cached = _programs[asset];
    if (cached != null) {
      if (mounted) {
        setState(() => _program = cached);
        if (!_ticker.isActive) _ticker.start();
      }
      return;
    }
    // Si otro widget ya está cargándolo, esperamos su Future.
    final pending = _loading[asset] ??=
        ui.FragmentProgram.fromAsset(asset).then((p) {
      _programs[asset] = p;
      _loading.remove(asset);
      return p;
    });
    try {
      final program = await pending;
      if (!mounted) return;
      setState(() => _program = program);
      if (!_ticker.isActive) _ticker.start();
    } catch (e) {
      devLog('ShaderBackground load $asset failed: $e');
    }
  }

  void _onTick(Duration elapsed) {
    if (_start == Duration.zero) _start = elapsed;
    _time.value = (elapsed - _start).inMicroseconds / 1e6;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) {
      // Fallback mientras carga — color sólido derivado de palette1/2.
      return ColoredBox(
        color: widget.palette3 ??
            widget.palette2 ??
            widget.palette1 ??
            const Color(0xFF101015),
      );
    }
    return CustomPaint(
      painter: _ShaderPainter(
        program: program,
        time: _time,
        speed: widget.speed,
        color1: _safe(widget.palette1, widget.shader, 0),
        color2: _safe(widget.palette2, widget.shader, 1),
        color3: _safe(widget.palette3, widget.shader, 2),
        paletteAware: widget.shader.paletteAware,
      ),
      size: Size.infinite,
    );
  }

  /// Fallback de colores para cuando el caller no pasa palette pero el shader
  /// SÍ es paletteAware. Tonos neutros oscuros — no llaman la atención.
  static Color _safe(Color? c, BackgroundShader shader, int index) {
    if (c != null) return c;
    if (!shader.paletteAware) return const Color(0xFF000000);
    return switch (index) {
      0 => const Color(0xFF7C5CFF),
      1 => const Color(0xFF21C7A8),
      _ => const Color(0xFF101015),
    };
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter({
    required this.program,
    required this.time,
    required this.speed,
    required this.color1,
    required this.color2,
    required this.color3,
    required this.paletteAware,
  }) : super(repaint: time);

  final ui.FragmentProgram program;
  final ValueListenable<double> time;
  final double speed;
  final Color color1;
  final Color color2;
  final Color color3;
  final bool paletteAware;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    // El ORDEN de setFloat sigue el orden de declaración de uniforms en
    // cada .frag. Importante: shaders NO paletteAware (liquid) NO declaran
    // u_color1/2/3 → solo tienen u_resolution(2) + u_time(1) + u_speed(1)
    // = 4 floats. Si escribimos los 12 floats de colores aunque sea con
    // ceros, RangeError porque el shader no los tiene reservados.
    var i = 0;
    shader.setFloat(i++, size.width);
    shader.setFloat(i++, size.height);
    shader.setFloat(i++, time.value);
    if (paletteAware) {
      i = _writeColor(shader, i, color1);
      i = _writeColor(shader, i, color2);
      i = _writeColor(shader, i, color3);
    }
    shader.setFloat(i++, speed.clamp(0.0, 4.0));

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  static int _writeColor(ui.FragmentShader s, int i, Color c) {
    // dart:ui Color → vec4 normalizado.
    s.setFloat(i++, c.r);
    s.setFloat(i++, c.g);
    s.setFloat(i++, c.b);
    s.setFloat(i++, c.a);
    return i;
  }

  @override
  bool shouldRepaint(covariant _ShaderPainter old) {
    return old.program != program ||
        old.color1 != color1 ||
        old.color2 != color2 ||
        old.color3 != color3 ||
        old.speed != speed ||
        old.paletteAware != paletteAware;
  }
}
