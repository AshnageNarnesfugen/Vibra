import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_controller.dart';
import '../../core/theme/layout_tokens.dart';
import '../../services/floating_controls_service.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/stable_backdrop_group.dart';

/// Pantalla de ajustes para el mini reproductor flotante tipo Dynamic
/// Island. Maneja:
///   - Indicador de plataforma (no-Android = "no disponible").
///   - Estado del permiso `SYSTEM_ALERT_WINDOW`.
///   - Toggle del setting persistente + botón para abrir ajustes del
///     sistema si el permiso no está concedido.
///
/// Cuando el toggle se activa Y hay permiso, el `FloatingControlsService`
/// arranca el foreground service nativo que monta la overlay.
class FloatingMiniSettingsScreen extends StatefulWidget {
  const FloatingMiniSettingsScreen({super.key});

  @override
  State<FloatingMiniSettingsScreen> createState() =>
      _FloatingMiniSettingsScreenState();
}

class _FloatingMiniSettingsScreenState
    extends State<FloatingMiniSettingsScreen> with WidgetsBindingObserver {
  bool _checkingPermission = false;
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Cuando el usuario vuelve de los ajustes del sistema (donde le
    // mandamos para conceder el permiso), refrescamos el estado.
    if (state == AppLifecycleState.resumed) {
      _refreshPermission();
    }
  }

  Future<void> _refreshPermission() async {
    if (!_supported) return;
    if (_checkingPermission) return;
    setState(() => _checkingPermission = true);
    try {
      final svc = context.read<FloatingControlsService>();
      final v = await svc.hasOverlayPermission();
      if (!mounted) return;
      setState(() => _hasPermission = v);
    } finally {
      if (mounted) setState(() => _checkingPermission = false);
    }
  }

  bool get _supported => !kIsWeb && Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<SettingsController>();
    final s = ctrl.value;
    final float = context.watch<FloatingControlsService>();
    final tokens = LayoutTokensScope.of(context);

    return StableBackdropGroup(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Mini flotante')),
      body: ListView(
        padding: tokens.pagePadding(),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mini reproductor sobre el sistema',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SizedBox(height: tokens.gapSm),
                Text(
                  'Muestra un pill flotante con la portada y controles '
                  'cuando sales de la app. Tap para expandir / colapsar.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: tokens.gap),
                if (!_supported)
                  _Info(
                    icon: Icons.block_rounded,
                    color: Theme.of(context).colorScheme.error,
                    text: 'Solo disponible en Android. iOS y escritorio '
                        'no permiten widgets flotantes de apps de terceros.',
                  )
                else ...[
                  _Info(
                    icon: _hasPermission
                        ? Icons.check_circle_rounded
                        : Icons.warning_amber_rounded,
                    color: _hasPermission
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                    text: _hasPermission
                        ? 'Permiso de overlay concedido.'
                        : 'Necesita permiso "Mostrar sobre otras apps". '
                            'Tócalo abajo para abrir los ajustes del sistema.',
                  ),
                  SizedBox(height: tokens.gap),
                  if (!_hasPermission)
                    FilledButton.icon(
                      icon: const Icon(Icons.settings_rounded),
                      label: const Text('Abrir ajustes del sistema'),
                      onPressed: () async {
                        await float.requestOverlayPermission();
                      },
                    ),
                  SizedBox(height: tokens.gap),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Activar mini flotante'),
                    subtitle: Text(
                      _hasPermission
                          ? 'Aparecerá automáticamente al salir de la app.'
                          : 'Concede el permiso primero.',
                    ),
                    value: s.floatingMiniEnabled && _hasPermission,
                    onChanged: !_hasPermission
                        ? null
                        : (v) async {
                            ctrl.update(
                                (p) => p.copyWith(floatingMiniEnabled: v));
                            await float.setEnabled(v);
                          },
                  ),
                  SizedBox(height: tokens.gap),
                  // Botón de diagnóstico: muestra el overlay durante 8s
                  // con datos placeholder rojos. Si aparece → pipeline
                  // OK. Si no → ejecutar `adb logcat -s VibraFloating`
                  // para ver el error real del lado nativo.
                  OutlinedButton.icon(
                    onPressed: !_hasPermission
                        ? null
                        : () => float.testFlash(),
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Probar overlay (8s)'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
