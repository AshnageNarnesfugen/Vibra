import 'package:flutter/material.dart';

/// Wrapper sobre `BackdropGroup` que **cachea** el `BackdropKey` en su
/// `State`. Sin esto, cada rebuild del widget que retorna `BackdropGroup(...)`
/// genera una key nueva, lo cual invalida la capa compartida del grupo y
/// los `BackdropFilter.grouped` aguas abajo pierden su sample.
///
/// Nota: con la arquitectura actual (cards usan `FrostedSamplerPainter` +
/// `BlurredBackgroundService`, no `BackdropFilter`), este wrapper es solo
/// relevante para elementos estáticos que sí usan `BackdropFilter` —
/// barra inferior, barras de navegación, etc. La búsqueda y las cards no
/// dependen de él pero tampoco daña tenerlo.
class StableBackdropGroup extends StatefulWidget {
  const StableBackdropGroup({super.key, required this.child});

  final Widget child;

  @override
  State<StableBackdropGroup> createState() => _StableBackdropGroupState();
}

class _StableBackdropGroupState extends State<StableBackdropGroup> {
  late final BackdropKey _backdropKey = BackdropKey();

  @override
  Widget build(BuildContext context) {
    return BackdropGroup(
      backdropKey: _backdropKey,
      child: widget.child,
    );
  }
}
