/// Extractor de las funciones de descifrado (`sig` y `n`) del `base.js` de
/// YouTube, al estilo NewPipe: en vez de PARSEAR los ~2.9 MB (inviable en
/// móvil), se localizan por regex las funciones PEQUEÑAS y se arma un script
/// mínimo (~5 KB) que un motor JS corre en milisegundos.
///
/// IMPORTANTE: usar la variante **`player_ias_tce`** del base.js — es la que
/// conserva la ofuscación clásica (`split("")`/`join("")` + objeto helper con
/// notación de punto) que estas regex reconocen. Validado contra el solver de
/// yt-dlp: produce exactamente la misma firma y el mismo `n`.
library;

/// Resultado: script JS que define `__sig(s)` y `__n(n)`, o null si la
/// extracción falló (base.js con formato inesperado).
String? buildDeobfuscator(String js) {
  final sig = _extractSig(js);
  if (sig == null) return null;
  final n = _extractN(js);
  if (n == null) return null;
  // Ambas funciones + wrappers estables `__sig` / `__n`.
  return '$sig\n$n\n';
}

// ───────────────────────── firma (sig) ─────────────────────────
String? _extractSig(String js) {
  // Nombre de la función de firma: `X=function(a){a=a.split("")...`
  final nameRe = RegExp(
    r'(?:\b|[^a-zA-Z0-9$])([a-zA-Z0-9$]{2,})\s*=\s*function\(\s*a\s*\)\s*'
    r'\{\s*a\s*=\s*a\.split\(\s*""\s*\)',
  );
  final nm = nameRe.firstMatch(js)?.group(1);
  if (nm == null) return null;
  final sigFunc = _funcFrom(js, '$nm=function');
  if (sigFunc == null) return null;

  // Objeto helper referenciado con notación de punto: `dO.S5(a,17)` → `dO`.
  final helperName =
      RegExp(r'([a-zA-Z0-9_$]{2,})\.[a-zA-Z0-9_$]{2,}\(').firstMatch(sigFunc)?.group(1);
  if (helperName == null) return null;
  final helperObj = _funcFrom(js, 'var $helperName=');
  if (helperObj == null) return null;

  // Array global de deobfuscación, si esta versión lo usa (opcional).
  final globalVar = RegExp(
    '''(var [A-Za-z0-9_\$]+\\s*=\\s*'(?:[^'\\\\]|\\\\.)*'\\.split\\("[;{]"\\))''',
  ).firstMatch(js)?.group(1);

  final buf = StringBuffer();
  if (globalVar != null) buf.write('$globalVar;');
  buf.write('var ${helperObj.substring(4)};'); // "var dO={...}"
  buf.write('var $sigFunc;'); // "var VHa=function..."
  buf.write('function __sig(a){return $nm(a);}');
  return buf.toString();
}

// ───────────────────────── throttling (n) ─────────────────────────
String? _extractN(String js) {
  String? nName;
  String? nFunc;

  // Caso típico moderno: `c=SDa[0](c)` con `var SDa=[Yma,...]`.
  final arrRef = RegExp(r'[a-zA-Z0-9$_]=([a-zA-Z0-9$_]+)\[0\]\([a-zA-Z0-9$_]\)')
      .firstMatch(js);
  if (arrRef != null) {
    final arrName = RegExp.escape(arrRef.group(1)!);
    final am = RegExp('var $arrName=\\[([a-zA-Z0-9\$_]+)').firstMatch(js);
    if (am != null) {
      nName = am.group(1);
      nFunc = _funcFrom(js, '$nName=function');
    }
  }

  // Fallback: función grande con split/join (la de `n` suele pasar de 800b).
  // Iteramos desde la POSICIÓN de cada match (brace-match O(tamaño-función)),
  // sin `indexOf` por candidato — eso era O(n²) y colgaba en móvil.
  if (nFunc == null) {
    final splitJoin = RegExp(r'=[a-z]\.split\(""\)');
    for (final m in RegExp(r'([a-zA-Z0-9_$]{2,})=function\([a-zA-Z0-9_$]\)\{')
        .allMatches(js)) {
      final open = m.end - 1; // la '{' es el último char del match
      final end = _matchBrace(js, open);
      if (end < 0) continue;
      final fn = js.substring(m.start, end + 1);
      if (fn.length > 800 &&
          fn.contains('.join("")') &&
          splitJoin.hasMatch(fn)) {
        nName = m.group(1);
        nFunc = fn;
        break;
      }
    }
  }
  if (nName == null || nFunc == null) return null;

  // Quitar el guard de early-return `;if(typeof X==="undefined")return X;`
  // que cortocircuitaría la deobfuscación devolviendo la `n` sin transformar.
  nFunc = nFunc.replaceFirst(
    RegExp(
      r';\s*if\s*\(\s*typeof\s+[a-zA-Z0-9$_]+\s*===?\s*(["'
      "'"
      r'])undefined\1\s*\)\s*return\s+[a-zA-Z0-9$_]+;',
    ),
    ';',
  );
  return 'var $nFunc;function __n(a){return $nName(a);}';
}

// ───────────────────────── utilidades ─────────────────────────

/// Extrae `<decl>{...}` completo, contando llaves de forma consciente de
/// strings, template literals, regex y comentarios (para no cortar en una
/// llave que viva dentro de un string).
String? _funcFrom(String src, String decl) {
  final start = src.indexOf(decl);
  if (start < 0) return null;
  final open = src.indexOf('{', start);
  if (open < 0) return null;
  final end = _matchBrace(src, open);
  if (end < 0) return null;
  return src.substring(start, end + 1);
}

// Códigos de carácter (evitan asignar Strings de 1 char por índice — en
// Dart `src[i]` asigna, `src.codeUnitAt(i)` devuelve un int).
const int _quote = 0x22; // "
const int _apos = 0x27; // '
const int _btick = 0x60; // `
const int _bslash = 0x5C; // \
const int _slash = 0x2F; // /
const int _star = 0x2A; // *
const int _nl = 0x0A; // \n
const int _lbrace = 0x7B; // {
const int _rbrace = 0x7D; // }
const int _lbrack = 0x5B; // [
const int _rbrack = 0x5D; // ]

int _matchBrace(String src, int from) {
  final len = src.length;
  var depth = 0;
  var str = 0; // 0 = fuera de string; si no, el code unit de la comilla
  var esc = false;
  for (var i = from; i < len; i++) {
    final c = src.codeUnitAt(i);
    if (str != 0) {
      if (esc) {
        esc = false;
      } else if (c == _bslash) {
        esc = true;
      } else if (c == str) {
        str = 0;
      }
      continue;
    }
    if (c == _quote || c == _apos || c == _btick) {
      str = c;
      continue;
    }
    if (c == _slash) {
      final n = i + 1 < len ? src.codeUnitAt(i + 1) : 0;
      if (n == _slash) {
        while (i < len && src.codeUnitAt(i) != _nl) {
          i++;
        }
        continue;
      }
      if (n == _star) {
        i += 2;
        while (i + 1 < len &&
            !(src.codeUnitAt(i) == _star && src.codeUnitAt(i + 1) == _slash)) {
          i++;
        }
        i++;
        continue;
      }
      // ¿regex literal? Heurística: último char no-espacio previo.
      var j = i - 1;
      while (j >= 0 && _isSpaceCode(src.codeUnitAt(j))) {
        j--;
      }
      final prev = j >= 0 ? src.codeUnitAt(j) : 0;
      if (prev == 0 || _regexPrev(prev)) {
        i++;
        var inClass = false;
        var rEsc = false;
        for (; i < len; i++) {
          final rc = src.codeUnitAt(i);
          if (rEsc) {
            rEsc = false;
          } else if (rc == _bslash) {
            rEsc = true;
          } else if (rc == _lbrack) {
            inClass = true;
          } else if (rc == _rbrack) {
            inClass = false;
          } else if (rc == _slash && !inClass) {
            break;
          }
        }
        continue;
      }
      continue;
    }
    if (c == _lbrace) {
      depth++;
    } else if (c == _rbrace) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool _isSpaceCode(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

// Chars tras los que un `/` inicia un literal regex: ( , = : [ ! & | ? { } ;
bool _regexPrev(int c) =>
    c == 0x28 ||
    c == 0x2C ||
    c == 0x3D ||
    c == 0x3A ||
    c == _lbrack ||
    c == 0x21 ||
    c == 0x26 ||
    c == 0x7C ||
    c == 0x3F ||
    c == _lbrace ||
    c == _rbrace ||
    c == 0x3B;
