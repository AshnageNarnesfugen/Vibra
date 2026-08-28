import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Generador de "cold-start" PoToken (Proof-of-Origin) — port del
/// `PoTokenGenerator` de OpenTune. Construye un token protobuf-like de forma
/// PURAMENTE algorítmica (sin BotGuard/WebView): XOR del identificador con una
/// clave aleatoria + timestamp, en base64url.
///
/// YouTube exige cada vez más un `pot=` en las URLs de media (googlevideo
/// devuelve 403 con cuerpo vacío sin él). Este token sintético lo aceptan
/// algunos endpoints; si Google exige el token real de BotGuard, no basta.
class PoTokenGenerator {
  static const int _tokenVersion = 0x22;
  static const int _magicHeader = 0x0A;
  static const int _innerTag = 0x38;
  static const int _timestampTag = 0x02;

  static final _rand = Random.secure();

  /// [identifier] = visitorData (o dataSyncId con sesión). [clientState] suele
  /// ser "" (GVS/media) o "player".
  static String generate(String identifier, {String clientState = ''}) {
    final idBytes = utf8.encode(identifier);
    final stateBytes = utf8.encode(clientState);

    final key = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      key[i] = _rand.nextInt(256);
    }

    final enc = Uint8List(idBytes.length);
    for (var i = 0; i < idBytes.length; i++) {
      enc[i] = idBytes[i] ^ key[i % key.length];
    }

    final tsBytes = _encodeLong(DateTime.now().millisecondsSinceEpoch);

    final inner = BytesBuilder()
      ..addByte(_innerTag)
      ..add(_varInt(stateBytes.length))
      ..add(stateBytes)
      ..addByte(_timestampTag)
      ..add(_varInt(tsBytes.length))
      ..add(tsBytes);

    final payload = BytesBuilder()
      ..addByte(_magicHeader)
      ..add(_varInt(key.length))
      ..add(key)
      ..addByte(_tokenVersion)
      ..add(_varInt(enc.length))
      ..add(enc)
      ..add(inner.toBytes());

    return base64Url.encode(payload.toBytes()).replaceAll('=', '');
  }

  static Uint8List _encodeLong(int value) {
    final buf = Uint8List(8);
    var v = value;
    for (var i = 0; i < 8; i++) {
      buf[i] = v & 0xFF;
      v >>= 8;
    }
    var len = 8;
    while (len > 1 && buf[len - 1] == 0) {
      len--;
    }
    return Uint8List.sublistView(buf, 0, len);
  }

  static List<int> _varInt(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v | 0x80) & 0xFF);
      v >>= 7;
    }
    out.add(v & 0xFF);
    return out;
  }
}
