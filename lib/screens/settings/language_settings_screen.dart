import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/theme/layout_tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

/// Selector de idioma: seguir al sistema (default) o forzar es/en solo
/// dentro de la app. El cambio aplica al instante — MaterialApp.locale
/// se recalcula con el rebuild del settings watch.
class LanguageSettingsScreen extends StatelessWidget {
  const LanguageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final tokens = LayoutTokensScope.of(context);
    final t = AppLocalizations.of(context);

    // null = sistema. Los códigos coinciden con supportedLocales.
    final options = <(String?, String)>[
      (null, t.languageSystem),
      ('es', 'Español'),
      ('en', 'English'),
    ];

    return StableBackdropGroup(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(t.settingsLanguageTitle)),
        body: ListView(
          padding: tokens.pagePadding(),
          children: [
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.languageScreenHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SizedBox(height: tokens.gapSm),
                  RadioGroup<String?>(
                    groupValue: s.appLanguageCode,
                    onChanged: (code) {
                      ctrl.update((p) => code == null
                          ? p.copyWith(clearAppLanguageCode: true)
                          : p.copyWith(appLanguageCode: code));
                    },
                    child: Column(
                      children: [
                        for (final (code, label) in options)
                          RadioListTile<String?>(
                            value: code,
                            contentPadding: EdgeInsets.zero,
                            title: Text(label),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
