import 'package:flutter_test/flutter_test.dart';

import 'package:vibra/services/streaming/yt_auth.dart';
import 'package:vibra/services/streaming/yt_music_client.dart';

void main() {
  group('YtMusicClient.orderedPlayerClients', () {
    test('sin sesión conserva el orden estático (VR anónimos primero)', () {
      final c = YtMusicClient();
      // Invitado: los ANDROID_VR sin auth van primero — son los que Google
      // sirve sin PoToken y con URL directa.
      expect(c.orderedPlayerClients(), YtMusicClient.playerClientsCascade);
      expect(
        c.orderedPlayerClients().first,
        PlayerClientId.androidVr,
      );
    });

    test('con cookie completa, los clients que autentican van PRIMERO', () {
      final c = YtMusicClient()
        ..auth = const YtMusicAuth(
          cookie: 'SAPISID=abc; __Secure-3PSID=s',
        );
      final ordered = c.orderedPlayerClients();

      // El primero ya no puede ser un VR sin auth: con sesión activa esos
      // reciben cookie que no soportan → ERROR / LOGIN_REQUIRED. Deben ir
      // primero los loginSupported (ANDROID, ANDROID_MUSIC).
      expect(ordered.first, isNot(PlayerClientId.androidVr));
      expect(
        ordered.first,
        anyOf(PlayerClientId.android, PlayerClientId.androidMusic),
      );

      // Ningún client se pierde ni se duplica en el reordenamiento.
      expect(
        ordered.toSet(),
        YtMusicClient.playerClientsCascade.toSet(),
      );
      expect(ordered.length, YtMusicClient.playerClientsCascade.length);

      // Todos los login-supporting quedan antes que cualquier no-login.
      final firstAnonIdx = ordered.indexWhere(_isAnonymous);
      final lastLoginIdx = ordered.lastIndexWhere((id) => !_isAnonymous(id));
      expect(lastLoginIdx, lessThan(firstAnonIdx));
    });

    test('con Bearer OAuth vigente también reordena', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final c = YtMusicClient()
        ..auth = YtMusicAuth(
          accessToken: 'tok',
          tokenExpiryEpochMs: now + 120000,
        );
      expect(c.orderedPlayerClients().first, isNot(PlayerClientId.androidVr));
    });
  });
}

// Los VR y los iOS van como visitante puro (loginSupported=false).
bool _isAnonymous(PlayerClientId id) => switch (id) {
      PlayerClientId.androidVr ||
      PlayerClientId.androidVr43 ||
      PlayerClientId.androidVrNoAuth ||
      PlayerClientId.ios ||
      PlayerClientId.iosMusic =>
        true,
      _ => false,
    };
