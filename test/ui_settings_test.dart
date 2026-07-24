import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:vibra/core/settings/ui_settings.dart';

void main() {
  group('UiSettings serialización', () {
    test('round-trip básico por JSON', () {
      const original = UiSettings(
        blurEnabled: true,
        blurIntensity: 22,
        noiseIntensity: 0.3,
        cornerRadius: 12,
        spacingScale: 0.9,
        transitionStyle: PageTransitionStyle.slideUp,
        transitionDurationMs: 250,
      );

      final restored = UiSettings.fromJson(original.toJson());

      expect(restored.blurEnabled, original.blurEnabled);
      expect(restored.blurIntensity, original.blurIntensity);
      expect(restored.noiseIntensity, original.noiseIntensity);
      expect(restored.cornerRadius, original.cornerRadius);
      expect(restored.spacingScale, original.spacingScale);
      expect(restored.transitionStyle, original.transitionStyle);
      expect(restored.transitionDurationMs, original.transitionDurationMs);
    });

    test('round-trip de colores nullable (secundario + acento de imagen)', () {
      const withColors = UiSettings(
        fallbackSecondaryColor: Color(0xFF112233),
        backgroundImageAccentColor: Color(0xFF445566),
      );
      final restored = UiSettings.fromJson(withColors.toJson());
      expect(restored.fallbackSecondaryColor, const Color(0xFF112233));
      expect(restored.backgroundImageAccentColor, const Color(0xFF445566));

      // Nulls sobreviven el round-trip como nulls (no como negro/0).
      const withoutColors = UiSettings();
      final restored2 = UiSettings.fromJson(withoutColors.toJson());
      expect(restored2.fallbackSecondaryColor, isNull);
      expect(restored2.backgroundImageAccentColor, isNull);
    });

    test('round-trip de transform de imagen de fondo', () {
      const original = UiSettings(
        backgroundImagePath: '/tmp/x.png',
        backgroundImageTransform: BackgroundImageTransform(
          scale: 2.5,
          offsetX: -0.4,
          offsetY: 1.2,
        ),
      );
      final restored = UiSettings.fromJson(original.toJson());
      expect(restored.backgroundImageTransform.scale, 2.5);
      expect(restored.backgroundImageTransform.offsetX, -0.4);
      expect(restored.backgroundImageTransform.offsetY, 1.2);
    });

    test('round-trip de calidades de audio/video', () {
      const original = UiSettings(
        audioQualityWifi: MediaQuality.low,
        audioQualityCellular: MediaQuality.high,
        videoQualityWifi: MediaQuality.medium,
        videoQualityCellular: MediaQuality.high,
        downloadQuality: MediaQuality.low,
      );
      final restored = UiSettings.fromJson(original.toJson());
      expect(restored.audioQualityWifi, MediaQuality.low);
      expect(restored.audioQualityCellular, MediaQuality.high);
      expect(restored.videoQualityWifi, MediaQuality.medium);
      expect(restored.videoQualityCellular, MediaQuality.high);
      expect(restored.downloadQuality, MediaQuality.low);
    });

    test('fromJson tolera JSON viejo sin los campos nuevos', () {
      // Simula settings guardados por una versión anterior de la app.
      final restored = UiSettings.fromJson('{"blurEnabled": true}');
      expect(restored.blurEnabled, isTrue);
      expect(restored.fallbackSecondaryColor, isNull);
      expect(restored.backgroundImageAccentColor, isNull);
      expect(restored.backgroundImageTransform.scale, 1.0);
    });
  });

  group('UiSettings copyWith', () {
    test('clearFallbackSecondaryColor vuelve a automático', () {
      const s = UiSettings(fallbackSecondaryColor: Color(0xFF112233));
      final cleared = s.copyWith(clearFallbackSecondaryColor: true);
      expect(cleared.fallbackSecondaryColor, isNull);
      // Sin el flag, copyWith preserva el valor.
      expect(s.copyWith().fallbackSecondaryColor, const Color(0xFF112233));
    });

    test('clearBackgroundImagePath también limpia el acento extraído', () {
      const s = UiSettings(
        backgroundImagePath: '/tmp/x.png',
        backgroundImageAccentColor: Color(0xFF445566),
      );
      final cleared = s.copyWith(clearBackgroundImagePath: true);
      expect(cleared.backgroundImagePath, isNull);
      expect(cleared.backgroundImageAccentColor, isNull);
    });
  });

  group('effectiveFallbackAccent', () {
    test('usa el acento de la imagen solo en modo imagen con imagen custom',
        () {
      const base = UiSettings(
        fallbackAccentColor: Color(0xFFAA0000),
        backgroundImageAccentColor: Color(0xFF00AA00),
      );

      // Modo imagen + path + acento extraído → manda el de la imagen.
      final imageMode = base.copyWith(
        backgroundMode: BackgroundMode.image,
        backgroundImagePath: '/tmp/x.png',
      );
      expect(imageMode.effectiveFallbackAccent, const Color(0xFF00AA00));

      // Modo gradiente → manda el acento del usuario aunque haya extraído.
      final gradientMode = base.copyWith(
        backgroundMode: BackgroundMode.animatedGradient,
      );
      expect(gradientMode.effectiveFallbackAccent, const Color(0xFFAA0000));

      // Modo imagen SIN path → acento del usuario.
      final noPath = base.copyWith(backgroundMode: BackgroundMode.image);
      expect(noPath.effectiveFallbackAccent, const Color(0xFFAA0000));
    });
  });
}
