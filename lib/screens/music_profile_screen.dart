import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/settings/settings_controller.dart';
import '../core/theme/layout_tokens.dart';
import '../services/ai_brief_service.dart';
import '../services/play_stats_service.dart';
import '../services/ratings_service.dart';
import '../services/streaming/streaming_service.dart';
import '../services/taste_profile.dart';
import '../services/yt_stats_importer.dart';
import '../widgets/glass_card.dart';
import '../widgets/song_thumbnail.dart';
import '../widgets/star_rating.dart';
import '../widgets/stable_backdrop_group.dart';

/// Perfil de personalidad musical: tablas y gráficas calculadas desde las
/// estadísticas de escucha + calificaciones (ver [TasteProfile] para el
/// score que NO depende del conteo bruto de reproducciones), y un brief
/// generado por la IA que el usuario elija con su propia API key.
class MusicProfileScreen extends StatefulWidget {
  const MusicProfileScreen({super.key});

  @override
  State<MusicProfileScreen> createState() => _MusicProfileScreenState();
}

class _MusicProfileScreenState extends State<MusicProfileScreen> {
  final _briefSvc = AiBriefService();
  YtStatsImporter? _importer;
  bool _ytSyncing = false;

  @override
  void initState() {
    super.initState();
    // Sincronizar señales de YT Music al abrir (cooldown 1h dentro del
    // importer). Fusiona historial + "Vuelve a escucharlo" + likes con
    // las estadísticas locales.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncYt());
  }

  Future<void> _syncYt({bool force = false}) async {
    final stats = context.read<PlayStatsService?>();
    if (stats == null) return;
    _importer ??= YtStatsImporter(
      streaming: context.read<StreamingService>(),
      stats: stats,
    );
    setState(() => _ytSyncing = true);
    await _importer!.sync(force: force);
    if (mounted) setState(() => _ytSyncing = false);
  }

  final _customPrompt = TextEditingController();
  String? _briefResult;
  String? _briefError;
  bool _briefLoading = false;

  static const _templates = <String>[
    'Describe mi personalidad musical de forma personal y profunda.',
    '¿Qué dice mi música sobre cómo manejo mis emociones?',
    '¿Qué canción es mi "canción espiritual" y por qué?',
    'Recomiéndame 5 artistas nuevos basándote en mis patrones reales.',
  ];

  @override
  void dispose() {
    _customPrompt.dispose();
    super.dispose();
  }

  Future<void> _generate(TasteProfile profile, String prompt) async {
    final s = context.read<SettingsController>().value;
    final key = s.aiApiKey;
    if (key == null || key.trim().isEmpty) {
      setState(() => _briefError =
          'Configura tu API key abajo (se guarda solo en este dispositivo).');
      return;
    }
    final provider = AiProvider.values.firstWhere(
      (p) => p.name == s.aiProvider,
      orElse: () => AiProvider.anthropic,
    );
    setState(() {
      _briefLoading = true;
      _briefError = null;
      _briefResult = null;
    });
    try {
      final result = await _briefSvc.generate(
        provider: provider,
        apiKey: key.trim(),
        model: s.aiModel,
        prompt: prompt,
        dataSummary: AiBriefService.buildDataSummary(profile),
      );
      if (!mounted) return;
      setState(() {
        _briefResult = result;
        _briefLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _briefError = e.toString();
        _briefLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final stats = context.watch<PlayStatsService?>();
    final ratings = context.watch<RatingsService?>();

    if (stats == null || ratings == null) {
      return StableBackdropGroup(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Perfil musical')),
          body: const Center(child: Text('Servicio no disponible.')),
        ),
      );
    }

    final profile = TasteProfile.compute(stats, ratings);
    final hasData = profile.songs.isNotEmpty;

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Perfil musical'),
          actions: [
            IconButton(
              tooltip: 'Sincronizar con YouTube Music',
              onPressed: _ytSyncing ? null : () => _syncYt(force: true),
              icon: _ytSyncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            _SummaryCard(profile: profile),
            SizedBox(height: tokens.gap),
            if (!hasData)
              GlassCard(
                child: Text(
                  'Aún no hay suficiente historial. El perfil se construye '
                  'mientras escuchas y se FUSIONA con tu historial, likes y '
                  '"Vuelve a escucharlo" de YouTube Music (botón de sync '
                  'arriba — requiere sesión). Cada canción necesita '
                  '${TasteProfile.minPlays}+ señales para puntuar; las '
                  'calificaciones (menú ⋮ → Calificar) también cuentan.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else ...[
              _SpiritualSongsCard(profile: profile),
              SizedBox(height: tokens.gap),
              if (profile.artists.isNotEmpty) ...[
                _GroupCard(
                  title: 'Tus artistas',
                  subtitle: 'Promedio de devoción de sus mejores canciones '
                      '+ amplitud — no el que más suena, el que más vuelve.',
                  groups: profile.artists.take(8).toList(),
                ),
                SizedBox(height: tokens.gap),
              ],
              if (profile.albums.isNotEmpty) ...[
                _GroupCard(
                  title: 'Tus álbumes',
                  subtitle: 'Álbumes con más devoción sostenida.',
                  groups: profile.albums.take(6).toList(),
                ),
                SizedBox(height: tokens.gap),
              ],
              _HoursCard(histogram: profile.hourHistogram),
              SizedBox(height: tokens.gap),
            ],
            _AiBriefCard(
              enabled: hasData,
              loading: _briefLoading,
              result: _briefResult,
              error: _briefError,
              templates: _templates,
              customPrompt: _customPrompt,
              onGenerate: (prompt) => _generate(profile, prompt),
            ),
            SizedBox(
              height: 200 + MediaQuery.viewPaddingOf(context).bottom,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── Resumen ───────────────────────────

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.profile});
  final TasteProfile profile;

  @override
  Widget build(BuildContext context) {
    final hours = profile.totalMsListened / 3.6e6;
    Widget stat(String value, String label) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.primary)),
              Text(label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
    return GlassCard(
      child: Row(
        children: [
          stat('${profile.totalPlays}', 'reproducciones'),
          stat(hours >= 10 ? hours.round().toString() : hours.toStringAsFixed(1),
              'horas oídas'),
          stat('${profile.trackedSongs}', 'canciones\ncon historial'),
          stat('${profile.ratedSongs}', 'calificadas'),
        ],
      ),
    );
  }
}

// ─────────────────── Canciones espirituales ───────────────────

class _SpiritualSongsCard extends StatelessWidget {
  const _SpiritualSongsCard({required this.profile});
  final TasteProfile profile;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tus canciones espirituales',
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.gapSm),
          Text(
            'Score de devoción — constancia en el tiempo, terminar la '
            'canción, profundidad de escucha y tu calificación. El número '
            'de reproducciones NO entra al cálculo.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: tokens.gap),
          for (final (i, s) in profile.songs.take(10).indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: scheme.primary)),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SongThumbnail(song: s.stats.song, size: 38),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.stats.song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(s.stats.song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color:
                                  scheme.onSurface.withValues(alpha: 0.6))),
                      const SizedBox(height: 3),
                      _ScoreBar(score: s.score),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${(s.score * 100).round()}',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: scheme.primary)),
                    if (s.rating != null)
                      StarRatingBar(rating: s.rating!, size: 10),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              Container(color: scheme.onSurface.withValues(alpha: 0.10)),
              Container(
                width: c.maxWidth * score.clamp(0.0, 1.0),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    scheme.primary.withValues(alpha: 0.65),
                    scheme.primary,
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────── Artistas / Álbumes ───────────────────

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.title,
    required this.subtitle,
    required this.groups,
  });

  final String title;
  final String subtitle;
  final List<ScoredGroup> groups;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.gapSm),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          SizedBox(height: tokens.gap),
          for (final (i, g) in groups.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: scheme.primary)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.subtitle == null
                            ? g.label
                            : '${g.label} — ${g.subtitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      _ScoreBar(score: g.score),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${g.songCount} canc.',
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────── Hábitos por hora ───────────────────

class _HoursCard extends StatelessWidget {
  const _HoursCard({required this.histogram});
  final List<int> histogram;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final maxV = histogram.fold<int>(0, (a, b) => a > b ? a : b);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('¿A qué horas escuchas?',
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.gap),
          SizedBox(
            height: 72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var h = 0; h < 24; h++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        height: maxV == 0
                            ? 2
                            : 2 + 66 * (histogram[h] / maxV),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: histogram[h] == maxV && maxV > 0
                              ? scheme.primary
                              : scheme.primary.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final label in const ['0h', '6h', '12h', '18h', '23h'])
                Text(label,
                    style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurface.withValues(alpha: 0.5))),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────── Brief de IA ───────────────────

class _AiBriefCard extends StatelessWidget {
  const _AiBriefCard({
    required this.enabled,
    required this.loading,
    required this.result,
    required this.error,
    required this.templates,
    required this.customPrompt,
    required this.onGenerate,
  });

  final bool enabled;
  final bool loading;
  final String? result;
  final String? error;
  final List<String> templates;
  final TextEditingController customPrompt;
  final ValueChanged<String> onGenerate;

  @override
  Widget build(BuildContext context) {
    final tokens = LayoutTokensScope.of(context);
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final provider = AiProvider.values.firstWhere(
      (p) => p.name == s.aiProvider,
      orElse: () => AiProvider.anthropic,
    );

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded,
                  size: 20, color: Theme.of(context).colorScheme.primary),
              SizedBox(width: tokens.gapSm),
              Text('Brief de IA',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          SizedBox(height: tokens.gapSm),
          Text(
            'Un análisis personal escrito por la IA que elijas, alimentado '
            'con tus métricas reales. Usa TU API key — se guarda solo en '
            'este dispositivo y solo se envían las métricas de arriba, '
            'nunca tu cuenta.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: tokens.gap),
          // ─── Config del proveedor ───
          DropdownButtonFormField<AiProvider>(
            initialValue: provider,
            decoration: const InputDecoration(
              labelText: 'Proveedor',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final p in AiProvider.values)
                DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: (p) {
              if (p != null) {
                ctrl.update((prev) => prev.copyWith(aiProvider: p.name));
              }
            },
          ),
          SizedBox(height: tokens.gapSm),
          TextFormField(
            initialValue: s.aiApiKey ?? '',
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'API key (${provider.keyHint})',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => ctrl.update((prev) => v.trim().isEmpty
                ? prev.copyWith(clearAiApiKey: true)
                : prev.copyWith(aiApiKey: v.trim())),
          ),
          SizedBox(height: tokens.gapSm),
          TextFormField(
            initialValue: s.aiModel ?? '',
            decoration: InputDecoration(
              labelText: 'Modelo (vacío = ${provider.defaultModel})',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => ctrl.update((prev) => v.trim().isEmpty
                ? prev.copyWith(clearAiModel: true)
                : prev.copyWith(aiModel: v.trim())),
          ),
          SizedBox(height: tokens.gap),
          // ─── Preguntas template ───
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in templates)
                ActionChip(
                  label: SizedBox(
                    width: 220,
                    child: Text(t,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  onPressed:
                      enabled && !loading ? () => onGenerate(t) : null,
                ),
            ],
          ),
          SizedBox(height: tokens.gap),
          // ─── Prompt custom ───
          TextField(
            controller: customPrompt,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'O pregunta lo que quieras…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          SizedBox(height: tokens.gapSm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: enabled && !loading
                  ? () {
                      final p = customPrompt.text.trim();
                      onGenerate(p.isEmpty ? templates.first : p);
                    }
                  : null,
              icon: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(loading ? 'Generando…' : 'Generar brief'),
            ),
          ),
          if (!enabled) ...[
            SizedBox(height: tokens.gapSm),
            Text(
              'Necesitas historial de escucha para generar el brief.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (error != null) ...[
            SizedBox(height: tokens.gap),
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: Theme.of(context).colorScheme.error),
                SizedBox(width: tokens.gapSm),
                Expanded(
                  child: Text(error!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ],
          if (result != null) ...[
            SizedBox(height: tokens.gap),
            Divider(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.3)),
            SizedBox(height: tokens.gapSm),
            SelectableText(
              result!,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
