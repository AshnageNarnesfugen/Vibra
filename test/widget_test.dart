import 'package:flutter_test/flutter_test.dart';

import 'package:vibra/core/settings/ui_settings.dart';

void main() {
  test('UiSettings round-trips through JSON', () {
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
}
