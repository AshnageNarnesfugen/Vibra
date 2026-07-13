import 'package:wakelock_plus/wakelock_plus.dart';

import '../providers/playback_controller.dart';
import '../core/dev_log.dart';

/// Activa/desactiva el wakelock (pantalla encendida) según el estado de
/// `PlaybackController.isPlaying`. La app se vuelve "pantalla siempre
/// activa mientras suena música" — útil para dejar el dispositivo en el
/// escritorio mirando la portada o los lyrics sin que se apague.
///
/// Cuando pausas o paras la cola, el wakelock se libera → el sistema
/// vuelve a su comportamiento normal de timeout.
class WakelockController {
  WakelockController({required this.playback}) {
    playback.addListener(_evaluate);
    _evaluate();
  }

  final PlaybackController playback;
  bool _wakelockOn = false;

  void _evaluate() {
    final shouldHold = playback.isPlaying;
    if (shouldHold == _wakelockOn) return;
    _wakelockOn = shouldHold;
    _apply(shouldHold);
  }

  Future<void> _apply(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      // En desktop sin implementación nativa o si algo falla, no es crítico.
      devLog('WakelockController _apply($on) failed: $e');
    }
  }

  void dispose() {
    playback.removeListener(_evaluate);
    // Asegura que no quede una sesión con wakelock activo si la app se
    // cierra de forma rara durante reproducción.
    if (_wakelockOn) {
      _apply(false);
      _wakelockOn = false;
    }
  }
}
