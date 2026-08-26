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

  // Caso típico moderno: `c=SDa[0](c)` con `var SDa=[Yma,...]`.
  final arrRef = RegExp(r'[a-zA-Z0-9$_]=([a-zA-Z0-9$_]+)\[0\]\([a-zA-Z0-9$_]\)')
      .firstMatch(js);
  if (arrRef != null) {
    final arrName = RegExp.escape(arrRef.group(1)!);
    final am = RegExp('var $arrName=\\[([a-zA-Z0-9\$_]+)').firstMatch(js);
    nName = am?.group(1);
  }

  // Fallback: función grande con split/join (la de `n` suele pasar de 800b).
  nName ??= () {
    for (final m
        in RegExp(r'([a-zA-Z0-9_$]{2,})=function\([a-zA-Z0-9_$]\)\{').allMatches(js)) {
      final cand = m.group(1)!;
      final fn = _funcFrom(js, '$cand=function');
      if (fn != null &&
          RegExp(r'=[a-z]\.split\(""\)').hasMatch(fn) &&
          fn.contains('.join("")') &&
          fn.length > 800) {
        return cand;
      }
    }
    return null;
  }();
  if (nName == null) return null;

  var nFunc = _funcFrom(js, '$nName=function');
  if (nFunc == null) return null;
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

int _matchBrace(String src, int from) {
  var depth = 0;
  String? str;
  var esc = false;
  for (var i = from; i < src.length; i++) {
    final c = src[i];
    if (str != null) {
      if (esc) {
        esc = false;
        continue;
      }
      if (c == r'\') {
        esc = true;
        continue;
      }
      if (c == str) str = null;
      continue;
    }
    if (c == '"' || c == "'" || c == '`') {
      str = c;
      continue;
    }
    if (c == '/') {
      final n = i + 1 < src.length ? src[i + 1] : '';
      if (n == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        continue;
      }
      if (n == '*') {
        i += 2;
        while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i++;
        continue;
      }
      // ¿regex literal? Heurística: mirar el último char no-espacio previo.
      var j = i - 1;
      while (j >= 0 && _isSpace(src[j])) {
        j--;
      }
      final prev = j >= 0 ? src[j] : '';
      if (prev.isEmpty || '(,=:[!&|?{};'.contains(prev)) {
        i++;
        var inClass = false;
        for (; i < src.length; i++) {
          final rc = src[i];
          if (esc) {
            esc = false;
            continue;
          }
          if (rc == r'\') {
            esc = true;
            continue;
          }
          if (rc == '[') {
            inClass = true;
          } else if (rc == ']') {
            inClass = false;
          } else if (rc == '/' && !inClass) {
            break;
          }
        }
        continue;
      }
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
