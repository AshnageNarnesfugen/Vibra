import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/dev_log.dart';

/// Wrapper que envuelve la portada en forma de disco con orificio central
/// (estilo iPod nano / vinilo digital). Gira lento mientras [spinning] es
/// true, pausa al instante cuando false. La rotación es física (no
/// snappy): al activarse retoma desde el ángulo donde estaba.
///
/// Aspecto cuadrado preservado — el caller debe envolverlo en un
/// AspectRatio(1) si quiere disco circular perfecto.
class CdCoverWrapper extends StatefulWidget {
  const CdCoverWrapper({
    super.key,
    required this.child,
    required this.spinning,
    this.rpm = 10,
    this.holeFraction = 0.16,
  });

  /// La carátula a renderizar dentro del disco.
  final Widget child;

  /// Si true → la rotación avanza. Si false → se pausa en el ángulo
  /// actual sin reset.
  final bool spinning;

  /// Revoluciones por minuto. Default 10 RPM = una vuelta cada 6s, ritmo
  /// "vinilo de 33⅓" amortiguado. A 33⅓ se sentiría mareante en pantalla
  /// pequeña.
  final double rpm;

  /// Tamaño del orificio del disco como fracción del lado total. 0.16 →
  /// hueco realista de single de 7".
  final double holeFraction;

  @override
  State<CdCoverWrapper> createState() => _CdCoverWrapperState();
}

class _CdCoverWrapperState extends State<CdCoverWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    final periodMs = (60000 / widget.rpm).round();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: periodMs),
    );
    if (widget.spinning) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant CdCoverWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.spinning && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipPath(
        clipper: _DiscClipper(holeFraction: widget.holeFraction),
        child: RotationTransition(
          turns: _ctrl,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Clip path: círculo exterior menos círculo interior (orificio del disco).
/// Usa fillType evenOdd para "perforar" el hueco.
class _DiscClipper extends CustomClipper<Path> {
  const _DiscClipper({required this.holeFraction});

  final double holeFraction;

  @override
  Path getClip(Size size) {
    final s = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final outer = Path()
      ..addOval(Rect.fromCircle(center: center, radius: s / 2));
    final inner = Path()
      ..addOval(Rect.fromCircle(center: center, radius: s * holeFraction / 2));
    return Path.combine(PathOperation.difference, outer, inner);
  }

  @override
  bool shouldReclip(covariant _DiscClipper oldClipper) =>
      oldClipper.holeFraction != holeFraction;
}

/// Wrapper "holográfico estilo papel iridiscente" (foil de carta
/// coleccionable). Usa un fragment shader real para generar:
///   - Bandas de espectro RGB que se desplazan con el tilt del
///     giroscopio (efecto físico de "ver desde otro ángulo").
///   - Sparkle de granos brillantes (los "diamantitos" del foil).
///   - Vignette suave para no dominar las esquinas.
///
/// Combinado con un tilt 3D sutil (Matrix4 perspective) → el cover
/// parece una carta holo real flotando.
///
/// Si el dispositivo no tiene giroscopio (desktop, emulador sin
/// sensores), el wrapper se degrada graceful — el shader sigue
/// animando con `u_time` solo, sin shift por tilt.
class HolographicCoverWrapper extends StatefulWidget {
  const HolographicCoverWrapper({
    super.key,
    required this.child,
    required this.color1,
    required this.color2,
    required this.color3,
    this.tiltMaxDegrees = 14,
    this.tiltIntensity = 1.0,
    this.parallaxIntensity = 1.0,
    this.borderRadius,
  });

  final Widget child;

  /// Colores del album que el shader usa para colorear las bandas
  /// iridiscentes. Típicamente `scheme.primary`, `scheme.secondary` y
  /// `scheme.tertiary` o derivados del PaletteSignal.
  final Color color1;
  final Color color2;
  final Color color3;

  /// Tope del tilt 3D en cada eje. 14° (antes 8°) para que el efecto
  /// de inclinación sea NOTORIO — con 8° y device en mano normal
  /// apenas se percibía.
  final double tiltMaxDegrees;

  /// Multiplicador SOLO de la rotación 3D del Matrix4 (rango 0.0–1.0).
  /// 0 → cover plano sin inclinación 3D; 1 → tilt pleno. NO afecta el
  /// shift parallax de las bandas iridiscentes del shader — el shader
  /// sigue respondiendo al giroscopio aunque [tiltIntensity] = 0, así
  /// el movimiento holográfico se preserva cuando el usuario desactiva
  /// la inclinación física (o cuando el queue expandido la suprime).
  final double tiltIntensity;

  /// Multiplicador SOLO del shift parallax del shader (rango 0.0–1.0).
  /// 0 → las bandas iridiscentes no responden al giroscopio (solo animan
  /// por tiempo); 1 → desplazamiento pleno con el viewing angle.
  /// Independiente de [tiltIntensity] — el cover puede tiltear sin que
  /// las bandas se muevan, o las bandas pueden parallaxear sin tilt 3D.
  final double parallaxIntensity;

  /// Border radius del clip (debe matchear el del cover original para que
  /// el overlay holo no se desborde).
  final BorderRadius? borderRadius;

  @override
  State<HolographicCoverWrapper> createState() =>
      _HolographicCoverWrapperState();
}

class _HolographicCoverWrapperState extends State<HolographicCoverWrapper>
    with SingleTickerProviderStateMixin {
  // Cache global del FragmentProgram — `FragmentProgram.fromAsset` es
  // ~50-100ms y síncrono en el plugin nativo. Compartirlo entre instancias
  // evita hiccups si el user toggle rápido entre shapes en settings.
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;

  ui.FragmentProgram? _localProgram;

  // Tilt acumulado del giroscopio (en rad, signado). Va a un
  // ValueNotifier para que solo el CustomPaint repaint, no el subárbol
  // entero del cover.
  final ValueNotifier<Offset> _tilt = ValueNotifier(Offset.zero);
  StreamSubscription<GyroscopeEvent>? _sub;

  // Tiempo de animación a 60Hz (vsync nativo). Antes throttle a 30Hz
  // por miedo a stutters, pero después de cambiar BlendMode.plus →
  // srcOver (que eliminó el saveLayer caro), el shader corre con
  // margen de sobra incluso en Retroid Pocket Flip2 → vale subir
  // visualmente para que se sienta fluido.
  final ValueNotifier<double> _time = ValueNotifier<double>(0.0);
  late final Ticker _ticker;
  Duration _start = Duration.zero;

  // Pausa el sensor cuando la app va a background. El Ticker se silencia
  // solo (el engine deja de pedir frames), pero el STREAM del giroscopio
  // sigue muestreando a 60Hz mientras la subscription esté activa →
  // batería drenada con la app "minimizada". pause/resume del
  // StreamSubscription corta el listener; sensors_plus libera el sensor
  // nativo cuando no hay listeners activos.
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _loadProgram();
    _ticker = createTicker(_onTick);
    _ticker.start();

    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final active = state == AppLifecycleState.resumed;
        if (active && (_sub?.isPaused ?? false)) {
          _sub?.resume();
        } else if (!active && !(_sub?.isPaused ?? true)) {
          _sub?.pause();
        }
      },
    );

    try {
      // samplingPeriod a 16ms (~60Hz) para que el tilt SE SIENTA fluido.
      // El throttle anterior a 30Hz era visible — el holo "saltaba" en
      // movimientos rápidos del device. 60Hz nativo + srcOver (sin
      // saveLayer) corre con margen en mid-range.
      _sub = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: 16),
      ).listen((e) {
        if (!mounted) return;
        final maxRad = widget.tiltMaxDegrees * math.pi / 180;
        final prev = _tilt.value;
        // 0.92 damping (menos agresivo que 0.85): el cover mantiene
        // mejor su inclinación cuando el movimiento es continuo,
        // evitando el "saltito" de volver al centro a media animación.
        // 0.030 sensibilidad (antes 0.025) → respuesta más viva.
        final nx = (prev.dx * 0.92 + e.x * 0.030).clamp(-maxRad, maxRad);
        final ny = (prev.dy * 0.92 + e.y * 0.030).clamp(-maxRad, maxRad);
        // Skip threshold a 0.3% (antes 1%) → reportamos más
        // microcambios, el tilt se siente continuo no escalonado. El
        // costo es despreciable porque el ValueListenableBuilder solo
        // dispara repaint del Transform, no rebuild de la portada.
        if ((nx - prev.dx).abs() < maxRad * 0.003 &&
            (ny - prev.dy).abs() < maxRad * 0.003) {
          return;
        }
        _tilt.value = Offset(nx, ny);
      }, onError: (_) {
        // Sin sensor → silencioso, mantenemos tilt = (0,0); el shader sigue
        // animando con u_time.
      });
    } catch (_) {
      // No-op en plataformas sin sensors_plus.
    }
  }

  Future<void> _loadProgram() async {
    final cached = _program;
    if (cached != null) {
      if (mounted) setState(() => _localProgram = cached);
      return;
    }
    final pending = _loading ??=
        ui.FragmentProgram.fromAsset('assets/shaders/holographic.frag')
            .then((p) {
      _program = p;
      _loading = null;
      return p;
    });
    try {
      final p = await pending;
      if (!mounted) return;
      setState(() => _localProgram = p);
    } catch (e) {
      devLog('Holographic shader load failed: $e');
    }
  }

  void _onTick(Duration elapsed) {
    if (_start == Duration.zero) _start = elapsed;
    // 60Hz nativo del Ticker. Sin throttle: con BlendMode.srcOver (sin
    // saveLayer), el painter es barato y se beneficia de actualizar
    // por cada vsync — la onda del holo se ve continua, no escalonada.
    _time.value = (elapsed - _start).inMicroseconds / 1e6;
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _sub?.cancel();
    _ticker.dispose();
    _tilt.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(16);
    final maxRad = widget.tiltMaxDegrees * math.pi / 180;
    final program = _localProgram;
    // Intensidades clampeadas — el caller puede pasar valores fuera de
    // rango si interpola con curves (overshoot).
    final intensity = widget.tiltIntensity.clamp(0.0, 1.0);
    final parallax = widget.parallaxIntensity.clamp(0.0, 1.0);

    // ⚠️ Orden de capas IMPORTANTE: el ClipRRect va DENTRO del Transform
    // (no afuera). Si está afuera, el clip es un rectángulo plano fijo
    // y cuando la carátula rota en 3D los corners se salen del clip y
    // quedan truncos. Con el clip ADENTRO, las esquinas redondeadas
    // siguen al child y rotan junto con la perspective.
    //
    // AnimatedBuilder con ambos notifiers (_tilt + _time como Listenable.merge):
    // así el shader puede repintar por _time (animación temporal) aunque
    // el _tilt no cambie (caso intensidad=0).
    return RepaintBoundary(
      child: ValueListenableBuilder<Offset>(
        valueListenable: _tilt,
        builder: (context, tilt, _) {
          // 3D del cover: SE multiplica por intensity. En intensity=0
          // el Matrix4 queda identidad y el cover se ve plano. El
          // setting del usuario y el gate del queue actúan acá.
          final effDx = tilt.dx * intensity;
          final effDy = tilt.dy * intensity;
          final transform = Matrix4.identity()
            // perspective más pronunciado (0.0025 vs 0.0015) para que
            // el tilt 3D se sienta como una carta holo real — la
            // diferencia de profundidad entre el borde cercano y el
            // lejano queda visible.
            ..setEntry(3, 2, 0.0025)
            ..rotateX(-effDx)
            ..rotateY(effDy);
          // Shader parallax: el `parallax` multiplica el tilt RAW antes
          // de pasarlo al shader. Independiente del `intensity` del
          // Matrix4 — el usuario puede tener cover plano (intensity=0)
          // con bandas igual desplazándose, o cover tilteado con bandas
          // estáticas (parallax=0). El queue gate vertical multiplica
          // ESTE valor por (1-phase1) si quisiéramos apagar parallax
          // al expandir; actualmente solo apagamos el 3D.
          final normTilt = Offset(
            (tilt.dy * parallax / maxRad).clamp(-1.0, 1.0),
            (tilt.dx * parallax / maxRad).clamp(-1.0, 1.0),
          );
          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.child,
                  // Shader overlay holo. Si el program aún no cargó,
                  // SizedBox.shrink → el cover se ve normal hasta que
                  // carga (cosa de <100ms, imperceptible).
                  if (program != null)
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _HoloShaderPainter(
                          program: program,
                          time: _time,
                          tilt: normTilt,
                          color1: widget.color1,
                          color2: widget.color2,
                          color3: widget.color3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Pinta el shader holográfico encima del child con BlendMode.plus
/// (sumar luz, no reemplazar) → el cover sigue visible, las bandas
/// iridiscentes se proyectan sobre él como reflejos sobre un foil real.
class _HoloShaderPainter extends CustomPainter {
  _HoloShaderPainter({
    required this.program,
    required this.time,
    required this.tilt,
    required this.color1,
    required this.color2,
    required this.color3,
  }) : super(repaint: time);

  final ui.FragmentProgram program;
  final ValueListenable<double> time;
  final Offset tilt;
  final Color color1;
  final Color color2;
  final Color color3;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    // Orden de uniforms igual al .frag:
    //   resolution(2) + time(1) + color1(4) + color2(4) + color3(4) + tilt(2)
    var i = 0;
    shader.setFloat(i++, size.width);
    shader.setFloat(i++, size.height);
    shader.setFloat(i++, time.value);
    i = _writeColor(shader, i, color1);
    i = _writeColor(shader, i, color2);
    i = _writeColor(shader, i, color3);
    shader.setFloat(i++, tilt.dx);
    shader.setFloat(i++, tilt.dy);

    // `srcOver` (default) en vez de `BlendMode.plus` — éste último
    // requiere `saveLayer` para leer el fondo, mezclar y reescribir,
    // que en Snapdragon mid-range come 5-15ms por frame y era la
    // causa principal del stuttering del holo. Con srcOver, el shader
    // ya sale con alpha pre-multiplicado y se compone directo en el
    // framebuffer sin layer auxiliar. El "look" cambia ligeramente
    // (translúcido en vez de aditivo) — el shader compensa con su
    // alpha base 0.55 que igual deja ver el cover por debajo.
    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  static int _writeColor(ui.FragmentShader s, int i, Color c) {
    s.setFloat(i++, c.r);
    s.setFloat(i++, c.g);
    s.setFloat(i++, c.b);
    s.setFloat(i++, c.a);
    return i;
  }

  @override
  bool shouldRepaint(covariant _HoloShaderPainter old) {
    return old.program != program ||
        old.tilt != tilt ||
        old.color1 != color1 ||
        old.color2 != color2 ||
        old.color3 != color3;
  }
}
