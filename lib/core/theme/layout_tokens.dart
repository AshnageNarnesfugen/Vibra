import 'package:flutter/material.dart';

import '../settings/ui_settings.dart';

/// Tokens de layout derivados del [UiSettings] del usuario.
///
/// Nada de hardcodear `EdgeInsets.all(16)` por la app — todo pasa por aquí
/// para que el slider de espaciado y el slider de border-radius tengan efecto
/// global e inmediato.
@immutable
class LayoutTokens {
  const LayoutTokens({
    required this.scale,
    required this.cornerRadius,
  });

  factory LayoutTokens.fromSettings(UiSettings s) =>
      LayoutTokens(scale: s.spacingScale, cornerRadius: s.cornerRadius);

  final double scale;
  final double cornerRadius;

  double space(double base) => base * scale;

  EdgeInsets pagePadding() => EdgeInsets.symmetric(
        horizontal: space(20),
        vertical: space(12),
      );

  EdgeInsets cardPadding() => EdgeInsets.all(space(16));
  EdgeInsets tilePadding() => EdgeInsets.symmetric(
        horizontal: space(16),
        vertical: space(10),
      );

  double get gap => space(12);
  double get gapSm => space(8);
  double get gapLg => space(20);

  BorderRadius get radius => BorderRadius.circular(cornerRadius);
  BorderRadius get radiusSm =>
      BorderRadius.circular((cornerRadius * 0.6).clamp(0, 24));
  BorderRadius get radiusLg =>
      BorderRadius.circular((cornerRadius * 1.4).clamp(0, 40));

  ShapeBorder get shape => RoundedRectangleBorder(borderRadius: radius);
}

/// Acceso ergonómico desde cualquier widget: `LayoutTokens.of(context)`.
class LayoutTokensScope extends InheritedWidget {
  const LayoutTokensScope({
    super.key,
    required this.tokens,
    required super.child,
  });

  final LayoutTokens tokens;

  static LayoutTokens of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<LayoutTokensScope>();
    assert(scope != null, 'LayoutTokensScope no encontrado.');
    return scope!.tokens;
  }

  @override
  bool updateShouldNotify(LayoutTokensScope oldWidget) =>
      tokens.scale != oldWidget.tokens.scale ||
      tokens.cornerRadius != oldWidget.tokens.cornerRadius;
}
