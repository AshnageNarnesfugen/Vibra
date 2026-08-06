import 'dart:convert';

import 'package:http/http.dart' as http;

import 'taste_profile.dart';

/// Proveedor de IA para el brief del perfil musical. El usuario trae su
/// propia API key (se guarda solo en el dispositivo, en settings).
enum AiProvider { anthropic, openai, gemini }

extension AiProviderInfo on AiProvider {
  String get label => switch (this) {
        AiProvider.anthropic => 'Claude (Anthropic)',
        AiProvider.openai => 'ChatGPT (OpenAI)',
        AiProvider.gemini => 'Gemini (Google)',
      };

  /// Modelo por defecto si el usuario no especifica uno.
  String get defaultModel => switch (this) {
        AiProvider.anthropic => 'claude-opus-5',
        AiProvider.openai => 'gpt-4o-mini',
        AiProvider.gemini => 'gemini-2.5-flash',
      };

  String get keyHint => switch (this) {
        AiProvider.anthropic => 'sk-ant-…',
        AiProvider.openai => 'sk-…',
        AiProvider.gemini => 'AIza…',
      };
}

class AiBriefException implements Exception {
  const AiBriefException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Genera un brief de personalidad musical llamando a la API del proveedor
/// elegido con la API key DEL USUARIO. Dart no tiene SDK oficial de estos
/// proveedores, así que es HTTP directo contra cada API pública.
class AiBriefService {
  AiBriefService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  static const _timeout = Duration(seconds: 120);

  /// Prompt de sistema compartido: el rol y las reglas del brief.
  static const _system =
      'Eres un analista musical cálido y perceptivo. Recibirás métricas '
      'reales de escucha de una persona (scores de devoción por canción, '
      'artistas, álbumes, hábitos horarios y calificaciones). Los scores NO '
      'son conteos de reproducciones: miden constancia, atención (terminar '
      'las canciones), profundidad de escucha y calificación personal. '
      'Escribe en el idioma de la pregunta del usuario, en segunda persona, '
      'personal y profundo pero sin inventar datos que no estén en las '
      'métricas. Sé específico: cita canciones/artistas de los datos.';

  /// Construye el resumen compacto de datos que se manda al modelo.
  static String buildDataSummary(TasteProfile p) {
    final b = StringBuffer();
    b.writeln('== Datos de escucha ==');
    b.writeln('Canciones con historial: ${p.trackedSongs} · '
        'reproducciones totales: ${p.totalPlays} · '
        'horas escuchadas: ${(p.totalMsListened / 3.6e6).toStringAsFixed(1)}');
    if (p.averageRating != null) {
      b.writeln('Calificadas: ${p.ratedSongs} '
          '(promedio ${p.averageRating!.toStringAsFixed(2)}/5)');
    }
    b.writeln('\n== Canciones "espirituales" (score devoción 0-1, '
        'NO por número de plays) ==');
    for (final s in p.songs.take(12)) {
      b.writeln('- ${s.stats.song.title} — ${s.stats.song.artist} · '
          'score ${s.score.toStringAsFixed(2)} · '
          'completadas ${s.stats.completes}/${s.stats.plays}'
          '${s.rating != null ? ' · rating ${s.rating}' : ''}');
    }
    b.writeln('\n== Artistas ==');
    for (final a in p.artists.take(8)) {
      b.writeln('- ${a.label} · score ${a.score.toStringAsFixed(2)} · '
          '${a.songCount} canciones con historial');
    }
    if (p.albums.isNotEmpty) {
      b.writeln('\n== Álbumes ==');
      for (final a in p.albums.take(6)) {
        b.writeln('- ${a.label} (${a.subtitle ?? ''}) · '
            'score ${a.score.toStringAsFixed(2)}');
      }
    }
    final peak = _peakHours(p.hourHistogram);
    if (peak != null) b.writeln('\nHoras pico de escucha: $peak');
    return b.toString();
  }

  static String? _peakHours(List<int> hist) {
    final total = hist.fold<int>(0, (a, b) => a + b);
    if (total == 0) return null;
    final indexed = List.generate(24, (i) => MapEntry(i, hist[i]))
      ..sort((a, b) => b.value.compareTo(a.value));
    return indexed
        .take(3)
        .where((e) => e.value > 0)
        .map((e) => '${e.key}:00')
        .join(', ');
  }

  Future<String> generate({
    required AiProvider provider,
    required String apiKey,
    required String prompt,
    required String dataSummary,
    String? model,
  }) async {
    final m = (model == null || model.trim().isEmpty)
        ? provider.defaultModel
        : model.trim();
    final user = '$dataSummary\n\n== Pregunta ==\n$prompt';
    switch (provider) {
      case AiProvider.anthropic:
        return _anthropic(apiKey, m, user);
      case AiProvider.openai:
        return _openai(apiKey, m, user);
      case AiProvider.gemini:
        return _gemini(apiKey, m, user);
    }
  }

  /// Claude Messages API (POST /v1/messages). En Claude Opus 5 el thinking
  /// viene activo por defecto — max_tokens cubre thinking + respuesta, por
  /// eso 4096. Un `stop_reason: refusal` llega como HTTP 200: se chequea
  /// antes de leer content.
  Future<String> _anthropic(String key, String model, String user) async {
    final res = await _http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'content-type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': model,
            'max_tokens': 4096,
            'system': _system,
            'messages': [
              {'role': 'user', 'content': user},
            ],
          }),
        )
        .timeout(_timeout);
    final json = _decode(res);
    if (json['stop_reason'] == 'refusal') {
      throw const AiBriefException('El modelo declinó la petición.');
    }
    final content = json['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          return (block['text'] as String).trim();
        }
      }
    }
    throw const AiBriefException('Respuesta sin texto.');
  }

  /// OpenAI Chat Completions.
  Future<String> _openai(String key, String model, String user) async {
    final res = await _http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': _system},
              {'role': 'user', 'content': user},
            ],
          }),
        )
        .timeout(_timeout);
    final json = _decode(res);
    final text =
        json['choices']?[0]?['message']?['content'] as String?;
    if (text == null || text.isEmpty) {
      throw const AiBriefException('Respuesta sin texto.');
    }
    return text.trim();
  }

  /// Google Gemini generateContent.
  Future<String> _gemini(String key, String model, String user) async {
    final res = await _http
        .post(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/'
              '$model:generateContent'),
          headers: {
            'content-type': 'application/json',
            'x-goog-api-key': key,
          },
          body: jsonEncode({
            'system_instruction': {
              'parts': [
                {'text': _system},
              ],
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': user},
                ],
              },
            ],
          }),
        )
        .timeout(_timeout);
    final json = _decode(res);
    final text = json['candidates']?[0]?['content']?['parts']?[0]?['text']
        as String?;
    if (text == null || text.isEmpty) {
      throw const AiBriefException('Respuesta sin texto.');
    }
    return text.trim();
  }

  Map<String, dynamic> _decode(http.Response res) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const AiBriefException(
          'API key inválida o sin permisos (401/403).');
    }
    if (res.statusCode == 429) {
      throw const AiBriefException(
          'Límite de uso alcanzado (429) — espera un momento.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = json?['error']?['message'] ??
          json?['error']?['type'] ??
          'HTTP ${res.statusCode}';
      throw AiBriefException('Error del proveedor: $msg');
    }
    if (json == null) {
      throw const AiBriefException('Respuesta inválida del proveedor.');
    }
    return json;
  }
}
