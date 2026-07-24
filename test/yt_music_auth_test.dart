import 'package:flutter_test/flutter_test.dart';

import 'package:vibra/services/streaming/yt_auth.dart';

void main() {
  group('YtMusicAuth parsing de cookies', () {
    test('parsea nombre=valor con trim de espacios', () {
      const auth = YtMusicAuth(
        cookie: ' SAPISID = abc123 ; HSID=x1; __Secure-3PSID=s3 ',
      );
      final p = auth.parsedCookies;
      // Trim de nombre Y valor — un paste manual con espacios producía
      // SAPISIDHASH inválido → 401 silencioso.
      expect(p['SAPISID'], 'abc123');
      expect(p['HSID'], 'x1');
      expect(p['__Secure-3PSID'], 's3');
    });

    test('ignora fragmentos sin = o vacíos', () {
      const auth = YtMusicAuth(cookie: 'foo; =bar; ; SAPISID=ok');
      expect(auth.parsedCookies.length, 1);
      expect(auth.sapisid, 'ok');
    });

    test('sapisid cae a las variantes __Secure cuando falta el clásico', () {
      const auth = YtMusicAuth(cookie: '__Secure-3PAPISID=tres');
      expect(auth.sapisid, 'tres');
    });
  });

  group('YtMusicAuth estado de sesión', () {
    test('sesión completa requiere SAPISID + cookie de sesión (SID)', () {
      const soloSapisid = YtMusicAuth(cookie: 'SAPISID=abc');
      expect(soloSapisid.isUsable, isTrue);
      // SAPISID solo firma — sin SID el server no reconoce la sesión.
      expect(soloSapisid.isCompleteCookieSession, isFalse);
      expect(
        soloSapisid.missingEssentialCookies,
        contains('__Secure-3PSID (o SID/__Secure-1PSID)'),
      );

      const completa = YtMusicAuth(cookie: 'SAPISID=abc; __Secure-3PSID=s');
      expect(completa.isCompleteCookieSession, isTrue);
      expect(completa.missingEssentialCookies, isEmpty);
    });

    test('cookie vacía no es usable ni completa', () {
      const vacia = YtMusicAuth();
      expect(vacia.isUsable, isFalse);
      expect(vacia.isCompleteCookieSession, isFalse);
    });

    test('bearer vigente con margen de 60s', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final vigente = YtMusicAuth(
        accessToken: 'tok',
        tokenExpiryEpochMs: now + 120000, // +2 min → vigente
      );
      expect(vigente.hasValidBearer, isTrue);

      final porExpirar = YtMusicAuth(
        accessToken: 'tok',
        tokenExpiryEpochMs: now + 30000, // +30s < margen de 60s → expirado
      );
      expect(porExpirar.hasValidBearer, isFalse);
    });

    test('sapisidVariants expone todas las variantes con su prefijo', () {
      const auth = YtMusicAuth(
        cookie: 'SAPISID=a; __Secure-1PAPISID=b; __Secure-3PAPISID=c',
      );
      final variants = auth.sapisidVariants.toList();
      expect(variants.length, 3);
      expect(variants[0].prefix, 'SAPISIDHASH');
      expect(variants[0].value, 'a');
      expect(variants[1].prefix, 'SAPISID1PHASH');
      expect(variants[2].prefix, 'SAPISID3PHASH');
    });
  });
}
