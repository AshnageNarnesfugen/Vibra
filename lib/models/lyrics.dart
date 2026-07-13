/// Representa la letra de una canción.
///
/// `synced=true` significa que cada [LyricLine.time] está poblado con el
/// timestamp real de cuando esa línea suena. `synced=false` es plain text
/// (líneas con `time=Duration.zero`) — el panel las muestra estáticas sin
/// highlight de línea activa.
class Lyrics {
  const Lyrics({required this.lines, required this.synced});

  final List<LyricLine> lines;
  final bool synced;

  bool get isEmpty => lines.isEmpty;
}

class LyricLine {
  const LyricLine({required this.time, required this.text});

  final Duration time;
  final String text;
}

/// Parser de formato LRC (LyRiCs). Acepta:
///   - `[mm:ss.xx]Texto`
///   - `[mm:ss:xx]Texto` (separador ":" en milisegundos — algunas fuentes)
///   - `[mm:ss]Texto` (sin milisegundos)
///   - Multi-tag en la misma línea: `[00:12.00][00:24.00]Texto repetido`.
///   - Tags de metadata `[ar:...]`, `[ti:...]`, `[length:...]` — se ignoran.
class LrcParser {
  LrcParser._();

  static final _tag = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );

  static List<LyricLine> parse(String raw) {
    final out = <LyricLine>[];
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      final matches = _tag.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line.substring(matches.last.end).trim();
      // Líneas vacías con timestamp suelen ser "instrumental gap" — los
      // dejamos vacíos para que el panel reserve espacio pero no muestre
      // texto, lo que da un ritmo natural en intros/puentes.
      for (final m in matches) {
        final min = int.tryParse(m.group(1) ?? '0') ?? 0;
        final sec = int.tryParse(m.group(2) ?? '0') ?? 0;
        // Normaliza ms: '5' → 500, '50' → 500, '500' → 500.
        final rawMs = m.group(3) ?? '0';
        final ms = _normalizeMs(rawMs);
        out.add(LyricLine(
          time: Duration(
            minutes: min,
            seconds: sec,
            milliseconds: ms,
          ),
          text: text,
        ));
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  static int _normalizeMs(String raw) {
    if (raw.isEmpty) return 0;
    if (raw.length == 1) return int.parse(raw) * 100;
    if (raw.length == 2) return int.parse(raw) * 10;
    return int.parse(raw.substring(0, 3));
  }
}
