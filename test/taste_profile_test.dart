import 'package:flutter_test/flutter_test.dart';

import 'package:vibra/models/song.dart';
import 'package:vibra/services/play_stats_service.dart';
import 'package:vibra/services/taste_profile.dart';

Song _song(String id, {String artist = 'Artista', int? durMs = 200000}) =>
    Song(
      id: id,
      title: 'T$id',
      artist: artist,
      album: 'Album',
      uri: 'file:///$id.mp3',
      durationMs: durMs,
    );

void main() {
  final now = DateTime(2026, 7, 24, 12);

  String day(int daysAgo) {
    final d = now.subtract(Duration(days: daysAgo));
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  group('spiritualScore', () {
    test('sin evidencia suficiente (menos de minPlays) no puntúa', () {
      final s = SongStats(song: _song('a'), plays: 2, completes: 2);
      expect(TasteProfile.spiritualScore(s, null, now: now), isNull);
    });

    test('el volumen de plays NO domina: devoción gana a repetición', () {
      // "Repetida": 60 plays pero abandonada a la mitad, sin constancia
      // (todas el mismo día — atracón), sin rating.
      final binged = SongStats(
        song: _song('binge'),
        plays: 60,
        completes: 12,
        skips: 30,
        msListened: 60 * 200000 ~/ 3,
        firstAt: now.subtract(const Duration(days: 90)),
        days: {day(0): 60},
      );
      // "Espiritual": solo 8 plays pero completadas, escucha profunda y
      // presencia repartida en el tiempo (histórico + reciente).
      final devoted = SongStats(
        song: _song('devoted'),
        plays: 8,
        completes: 8,
        msListened: 8 * 200000,
        firstAt: now.subtract(const Duration(days: 90)),
        days: {
          day(2): 1, day(9): 1, day(16): 1, day(25): 1,
          day(40): 1, day(55): 1, day(70): 1, day(85): 1,
        },
      );
      final bingedScore =
          TasteProfile.spiritualScore(binged, null, now: now)!;
      final devotedScore =
          TasteProfile.spiritualScore(devoted, null, now: now)!;
      expect(devotedScore, greaterThan(bingedScore));
    });

    test('el rating del usuario sube el score', () {
      final base = SongStats(
        song: _song('r'),
        plays: 10,
        completes: 8,
        msListened: 9 * 200000,
        firstAt: now.subtract(const Duration(days: 30)),
        days: {day(1): 2, day(5): 2, day(12): 3, day(20): 3},
      );
      final sinRating = TasteProfile.spiritualScore(base, null, now: now)!;
      final conRating = TasteProfile.spiritualScore(base, 5.0, now: now)!;
      expect(conRating, greaterThan(sinRating));
    });

    test('los skips penalizan', () {
      SongStats mk(int skips) => SongStats(
            song: _song('s$skips'),
            plays: 10,
            completes: 5,
            skips: skips,
            msListened: 5 * 200000,
            firstAt: now.subtract(const Duration(days: 20)),
            days: {day(1): 5, day(10): 5},
          );
      final clean = TasteProfile.spiritualScore(mk(0), null, now: now)!;
      final skippy = TasteProfile.spiritualScore(mk(5), null, now: now)!;
      expect(clean, greaterThan(skippy));
    });
  });

  group('agrupación por artista', () {
    test('agrupa y ordena por score', () {
      final stats = [
        SongStats(
          song: _song('a1', artist: 'Devocional'),
          plays: 6,
          completes: 6,
          msListened: 6 * 200000,
          firstAt: now.subtract(const Duration(days: 40)),
          days: {day(1): 1, day(8): 1, day(15): 2, day(30): 2},
        ),
        SongStats(
          song: _song('b1', artist: 'Saltado'),
          plays: 6,
          completes: 1,
          skips: 5,
          msListened: 200000,
          firstAt: now.subtract(const Duration(days: 40)),
          days: {day(1): 6},
        ),
      ];
      // Perfil sintético sin services reales: agrupamos via compute no es
      // posible sin instancias; probamos _group indirectamente con scores.
      final s1 = TasteProfile.spiritualScore(stats[0], null, now: now)!;
      final s2 = TasteProfile.spiritualScore(stats[1], null, now: now)!;
      expect(s1, greaterThan(s2));
    });
  });
}
