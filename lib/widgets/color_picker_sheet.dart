import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Selector de color completo: cuadrado HSV + slider de matiz + slider de
/// alpha + inputs sincronizados en HEX, RGBA y HSL.
///
/// Live preview: el callback `onChanged` se dispara en cada interacción. La
/// pantalla padre actualiza el setting inmediatamente — no hay botones
/// "aplicar/cancelar" porque el flujo es "arrastra hasta que te guste, luego
/// cierra el sheet".
///
/// Los inputs de texto son bidireccionales: editar HEX actualiza RGBA/HSL y
/// el picker visual; arrastrar el picker actualiza los inputs (excepto el
/// que tiene foco — para no pelearle al usuario mientras escribe).
Future<void> showColorPickerSheet(
  BuildContext context, {
  required Color initialColor,
  required ValueChanged<Color> onChanged,
  bool allowAlpha = true,
  String title = 'Elegir color',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ColorPickerSheet(
      initialColor: initialColor,
      onChanged: onChanged,
      allowAlpha: allowAlpha,
      title: title,
    ),
  );
}

class _ColorPickerSheet extends StatefulWidget {
  const _ColorPickerSheet({
    required this.initialColor,
    required this.onChanged,
    required this.allowAlpha,
    required this.title,
  });

  final Color initialColor;
  final ValueChanged<Color> onChanged;
  final bool allowAlpha;
  final String title;

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
  }

  Color get _color => _hsv.toColor();

  void _setHsv(HSVColor next) {
    if (next == _hsv) return;
    setState(() => _hsv = next);
    widget.onChanged(_color);
  }

  void _setColor(Color c) {
    final next = HSVColor.fromColor(c);
    // HSV conserva alpha aparte; respetamos el alpha del color entrante.
    final adjusted = next.withAlpha(c.a);
    _setHsv(adjusted);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);

    return Padding(
      // El padding bottom respeta el teclado cuando alguno de los inputs
      // tiene foco — sino los TextFields quedaban tapados por el IME.
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _grabber(scheme),
                const SizedBox(height: 8),
                _header(context),
                const SizedBox(height: 16),
                _preview(),
                const SizedBox(height: 16),
                // HSV square con altura controlada para que quepa con el
                // resto en pantallas pequeñas (Retroid Pocket).
                SizedBox(
                  height: 180,
                  child: _SaturationValueBox(
                    hsv: _hsv,
                    onChanged: (s, v) =>
                        _setHsv(_hsv.withSaturation(s).withValue(v)),
                  ),
                ),
                const SizedBox(height: 16),
                _HueSlider(
                  hue: _hsv.hue,
                  onChanged: (h) => _setHsv(_hsv.withHue(h)),
                ),
                if (widget.allowAlpha) ...[
                  const SizedBox(height: 14),
                  _AlphaSlider(
                    color: _color,
                    alpha: _hsv.alpha,
                    onChanged: (a) => _setHsv(_hsv.withAlpha(a)),
                  ),
                ],
                const SizedBox(height: 18),
                _HexInput(color: _color, onChanged: _setColor),
                const SizedBox(height: 12),
                _RgbaInputs(
                  color: _color,
                  allowAlpha: widget.allowAlpha,
                  onChanged: _setColor,
                ),
                const SizedBox(height: 12),
                _HslInputs(color: _color, onChanged: _setColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _grabber(ColorScheme scheme) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _header(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check_rounded),
            tooltip: 'Listo',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      );

  Widget _preview() {
    return Row(
      children: [
        _SwatchTile(label: 'Original', color: widget.initialColor),
        const SizedBox(width: 8),
        _SwatchTile(label: 'Nuevo', color: _color),
      ],
    );
  }
}

class _SwatchTile extends StatelessWidget {
  const _SwatchTile({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _CheckerBackground(),
            ColoredBox(color: color),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                child: Text(
                  label,
                  style: TextStyle(
                    color: _idealOnColor(color),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cuadrado HSV: X = saturación, Y = value invertido (top = más brillo).
class _SaturationValueBox extends StatelessWidget {
  const _SaturationValueBox({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final void Function(double saturation, double value) onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        void update(Offset local) {
          final s = (local.dx / w).clamp(0.0, 1.0);
          final v = 1.0 - (local.dy / h).clamp(0.0, 1.0);
          onChanged(s, v);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => update(d.localPosition),
            onPanStart: (d) => update(d.localPosition),
            onPanUpdate: (d) => update(d.localPosition),
            child: CustomPaint(
              size: Size(w, h),
              painter: _SVPainter(hsv),
            ),
          ),
        );
      },
    );
  }
}

class _SVPainter extends CustomPainter {
  _SVPainter(this.hsv);
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pure = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();

    // Capa 1: white → hue puro (saturation).
    final p1 = Paint()
      ..shader = LinearGradient(
        colors: [Colors.white, pure],
      ).createShader(rect);
    canvas.drawRect(rect, p1);

    // Capa 2: transparent → black (value).
    final p2 = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
      ).createShader(rect);
    canvas.drawRect(rect, p2);

    // Indicador del thumb.
    final cx = hsv.saturation * size.width;
    final cy = (1.0 - hsv.value) * size.height;
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white
      ..strokeWidth = 3;
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    canvas.drawCircle(Offset(cx, cy), 10, outer);
    canvas.drawCircle(Offset(cx, cy), 11, inner);
  }

  @override
  bool shouldRepaint(_SVPainter old) => old.hsv != hsv;
}

class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onChanged});
  final double hue;
  final ValueChanged<double> onChanged;

  static const _stops = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        void update(Offset local) {
          final h = (local.dx / w).clamp(0.0, 1.0) * 360.0;
          onChanged(h);
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => update(d.localPosition),
          onPanStart: (d) => update(d.localPosition),
          onPanUpdate: (d) => update(d.localPosition),
          child: CustomPaint(
            size: Size(w, 26),
            painter: _HuePainter(hue: hue, stops: _stops),
          ),
        );
      },
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter({required this.hue, required this.stops});
  final double hue;
  final List<Color> stops;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2));
    final p = Paint()
      ..shader = LinearGradient(colors: stops).createShader(rect);
    canvas.drawRRect(rrect, p);

    final x = (hue / 360.0) * size.width;
    _drawThumb(canvas, Offset(x.clamp(2, size.width - 2), size.height / 2),
        size.height);
  }

  static void _drawThumb(Canvas canvas, Offset c, double trackHeight) {
    final r = trackHeight / 2 + 3;
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(c, r, white);
    final stroke = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(c, r, stroke);
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}

class _AlphaSlider extends StatelessWidget {
  const _AlphaSlider({
    required this.color,
    required this.alpha,
    required this.onChanged,
  });
  final Color color;
  final double alpha;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        void update(Offset local) {
          final a = (local.dx / w).clamp(0.0, 1.0);
          onChanged(a);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: w,
            height: 26,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const _CheckerBackground(squareSize: 8),
                CustomPaint(
                  painter: _AlphaPainter(color: color, alpha: alpha),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => update(d.localPosition),
                  onPanStart: (d) => update(d.localPosition),
                  onPanUpdate: (d) => update(d.localPosition),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AlphaPainter extends CustomPainter {
  _AlphaPainter({required this.color, required this.alpha});
  final Color color;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final opaque = color.withValues(alpha: 1.0);
    final transparent = color.withValues(alpha: 0.0);
    final p = Paint()
      ..shader = LinearGradient(
        colors: [transparent, opaque],
      ).createShader(rect);
    canvas.drawRect(rect, p);
    final x = alpha * size.width;
    _HuePainter._drawThumb(
        canvas, Offset(x.clamp(2, size.width - 2), size.height / 2), size.height);
  }

  @override
  bool shouldRepaint(_AlphaPainter old) =>
      old.color != color || old.alpha != alpha;
}

class _CheckerBackground extends StatelessWidget {
  const _CheckerBackground({this.squareSize = 10});
  final double squareSize;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CheckerPainter(squareSize),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  _CheckerPainter(this.s);
  final double s;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0xFFE0E0E0);
    final dark = Paint()..color = const Color(0xFFB0B0B0);
    canvas.drawRect(Offset.zero & size, light);
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = 0.0; x < size.width; x += s) {
        final isDark = (((x / s).floor() + (y / s).floor()) % 2) == 0;
        if (isDark) {
          canvas.drawRect(Rect.fromLTWH(x, y, s, s), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => old.s != s;
}

// ---------------- Inputs ----------------

/// Base abstracta: TextField cuyo texto se sincroniza con `color` SOLO si
/// el field no tiene foco. Esto evita pelearle al usuario al typear:
/// mientras edita, el padre puede cambiar de color (por el slider), pero el
/// texto del field no se reemplaza hasta que pierda el foco.
abstract class _SyncedField extends StatefulWidget {
  const _SyncedField({required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;
}

mixin _SyncedFieldStateMixin<T extends _SyncedField> on State<T> {
  late final TextEditingController _ctrl =
      TextEditingController(text: format(widget.color));
  final FocusNode _focus = FocusNode();

  String format(Color c);
  Color? parse(String raw);

  @override
  void didUpdateWidget(covariant T old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.color != old.color) {
      final next = format(widget.color);
      if (_ctrl.text != next) _ctrl.text = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void onSubmitText(String raw) {
    final c = parse(raw);
    if (c != null) widget.onChanged(c);
    // Re-formateamos para limpiar input (ej. "abc" → "ABC" en hex).
    _ctrl.text = format(widget.color);
  }

  void onChangeText(String raw) {
    final c = parse(raw);
    if (c != null) widget.onChanged(c);
  }
}

class _HexInput extends _SyncedField {
  const _HexInput({required super.color, required super.onChanged});

  @override
  State<_HexInput> createState() => _HexInputState();
}

class _HexInputState extends State<_HexInput>
    with _SyncedFieldStateMixin<_HexInput> {
  @override
  String format(Color c) {
    final a = (c.a * 255).round();
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    String hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    if (a == 255) return '${hex(r)}${hex(g)}${hex(b)}';
    return '${hex(a)}${hex(r)}${hex(g)}${hex(b)}';
  }

  @override
  Color? parse(String raw) {
    var s = raw.trim().replaceAll('#', '').toUpperCase();
    if (s.length == 3) {
      // Shorthand: F0A → FF00AA.
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return null;
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    return Color(v);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
        LengthLimitingTextInputFormatter(9),
      ],
      decoration: const InputDecoration(
        labelText: 'HEX',
        prefixText: '#',
        isDense: true,
      ),
      onChanged: onChangeText,
      onSubmitted: onSubmitText,
    );
  }
}

class _RgbaInputs extends StatelessWidget {
  const _RgbaInputs({
    required this.color,
    required this.allowAlpha,
    required this.onChanged,
  });
  final Color color;
  final bool allowAlpha;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _IntChannel(
            label: 'R',
            value: (color.r * 255).round(),
            max: 255,
            onChanged: (v) => onChanged(color.withValues(
              red: v / 255,
            )),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _IntChannel(
            label: 'G',
            value: (color.g * 255).round(),
            max: 255,
            onChanged: (v) => onChanged(color.withValues(
              green: v / 255,
            )),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _IntChannel(
            label: 'B',
            value: (color.b * 255).round(),
            max: 255,
            onChanged: (v) => onChanged(color.withValues(
              blue: v / 255,
            )),
          ),
        ),
        if (allowAlpha) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _IntChannel(
              label: 'A%',
              value: (color.a * 100).round(),
              max: 100,
              onChanged: (v) => onChanged(color.withValues(
                alpha: v / 100,
              )),
            ),
          ),
        ],
      ],
    );
  }
}

class _HslInputs extends StatelessWidget {
  const _HslInputs({required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(color);
    return Row(
      children: [
        Expanded(
          child: _IntChannel(
            label: 'H°',
            value: hsl.hue.round(),
            max: 360,
            onChanged: (v) => onChanged(hsl.withHue(v.toDouble()).toColor()),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _IntChannel(
            label: 'S%',
            value: (hsl.saturation * 100).round(),
            max: 100,
            onChanged: (v) =>
                onChanged(hsl.withSaturation(v / 100).toColor()),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _IntChannel(
            label: 'L%',
            value: (hsl.lightness * 100).round(),
            max: 100,
            onChanged: (v) =>
                onChanged(hsl.withLightness(v / 100).toColor()),
          ),
        ),
      ],
    );
  }
}

class _IntChannel extends StatefulWidget {
  const _IntChannel({
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
  });
  final String label;
  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<_IntChannel> createState() => _IntChannelState();
}

class _IntChannelState extends State<_IntChannel> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value.toString());
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _IntChannel old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != old.value) {
      final next = widget.value.toString();
      if (_ctrl.text != next) _ctrl.text = next;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(widget.max.toString().length),
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
      ),
      onChanged: (raw) {
        final v = int.tryParse(raw);
        if (v == null) return;
        widget.onChanged(v.clamp(0, widget.max));
      },
    );
  }
}

/// Devuelve negro o blanco para texto encima del color dado, según contraste.
Color _idealOnColor(Color bg) {
  return bg.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
}
