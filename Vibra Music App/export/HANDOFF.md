# Vibra — Handoff de marca / logo

Logo de la app **Vibra**. Dirección elegida: **A · Eco** (ecualizador en forma de V) · colorway **Solar**.

---

## 1. Colores de marca

| Token             | HEX        | Uso                                  |
|-------------------|------------|--------------------------------------|
| `solar-1` naranja | `#FB923C`  | Inicio del degradado (0%)            |
| `solar-2` rosa    | `#F43F5E`  | Centro del degradado (52%) · color sólido principal |
| `solar-3` magenta | `#C026D3`  | Fin del degradado (100%)             |
| `noche`           | `#0A0618`  | Fondo oscuro / splash                |
| símbolo           | `#FFFFFF`  | Las barras sobre el degradado        |

**Degradado Solar** = lineal a **135°** (esquina superior-izquierda → inferior-derecha), 3 paradas: `#FB923C 0%` → `#F43F5E 52%` → `#C026D3 100%`.

### Flutter — degradado
```dart
const solarGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFFB923C), Color(0xFFF43F5E), Color(0xFFC026D3)],
  stops: [0.0, 0.52, 1.0],
);
```

---

## 2. Inventario de archivos

```
export/
├─ icons/                       App icons (cuadrados, full-bleed, sin transparencia)
│  ├─ vibra-icon.svg            ← vectorial (degradado + barras). Fuente de verdad.
│  ├─ vibra-icon-1024.png       ← master para flutter_launcher_icons / App Store
│  ├─ vibra-icon-1024-rounded.png   (solo preview con esquinas iOS)
│  └─ vibra-icon-{512,256,192,180,167,152,120,80,60,40}.png
├─ symbol/                      Símbolo solo (transparente, para headers / nav)
│  ├─ vibra-symbol.svg          ← usa fill="currentColor" (lo coloreas por código)
│  ├─ vibra-symbol-white.png
│  ├─ vibra-symbol-dark.png     (#1B1B1F)
│  └─ vibra-symbol-solar.png    (barras con degradado Solar)
├─ android/                     Íconos adaptativos de Android
│  ├─ ic_foreground.png         (símbolo en zona segura, 432px)
│  └─ ic_background.png         (degradado Solar full-bleed, 432px)
├─ flutter_launcher_icons.yaml  Config lista para generar todos los íconos
└─ flutter_native_splash.yaml   Config base del splash
```

---

## 3. Generar los íconos (recomendado)

No copies los PNG a mano a las carpetas de Android/iOS — deja que el paquete los genere:

```bash
# 1. Copia export/ dentro de tu app, p.ej. assets/branding/
# 2. Íconos de app:
flutter pub add dev:flutter_launcher_icons
dart run flutter_launcher_icons        # usa flutter_launcher_icons.yaml

# 3. Splash:
flutter pub add dev:flutter_native_splash
dart run flutter_native_splash:create  # usa flutter_native_splash.yaml
```

(Ajusta las rutas `image_path` de los .yaml si usas otra carpeta.)

---

## 4. Splash con degradado Solar (Flutter)

`flutter_native_splash` solo permite color sólido. Para el look Solar completo, deja un
splash nativo neutro y muestra esta pantalla en Flutter al arrancar:

```dart
class VibraSplash extends StatelessWidget {
  const VibraSplash({super.key});
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: solarGradient),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // vibra-symbol.svg con flutter_svg, coloreado de blanco:
            SvgPicture.asset('assets/branding/symbol/vibra-symbol.svg',
                width: 96, colorFilter:
                const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
            const SizedBox(height: 22),
            const Text('vibra',
                style: TextStyle(color: Colors.white, fontSize: 30,
                    fontWeight: FontWeight.w600, letterSpacing: 3.6)),
          ],
        ),
      ),
    );
  }
}
```

---

## 5. Notas

- El símbolo **dentro** del cuadrado ocupa ~60% (deja aire para la máscara del SO).
- Los PNG cuadrados **no tienen canal alfa** → válidos para iOS (`remove_alpha_ios` ya está en true por seguridad).
- Para íconos en la UI (nav bar, tabs) usa `vibra-symbol.svg` con `currentColor`.
- La fuente del wordmark "vibra" en los mockups es **Space Grotesk** (peso 600). Aún no es un wordmark definitivo — pídelo cuando quieras.
