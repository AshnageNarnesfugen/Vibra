# Vibra

Reproductor de música para Android con personalización profunda de la UI —
biblioteca local + streaming de YouTube Music, fondos animados por shader,
carátulas holográficas reactivas al giroscopio, ecualizador, modo Hi-Fi,
mini reproductor flotante y más.

> Proyecto personal / experimental. Usa APIs internas de YouTube Music
> (InnerTube) no oficiales — úsalo bajo tu propia responsabilidad.

## Características

- **Biblioteca local** con escaneo de carpetas, agrupación por álbum/artista.
- **Streaming de YouTube Music** (búsqueda, home personalizado, biblioteca,
  radio automática). Login por cookie del navegador.
- **Descargas offline** en `Android/media/<pkg>/Vibra Music/` — visibles en
  el explorador de archivos y otras apps de música, con metadata incrustada.
- **Personalización visual**: fondos (color, imagen ajustable, shaders
  animados palette-aware), blur, ruido, parallax al inclinar, formas de
  carátula (cuadrada / disco girando / holográfica con tilt 3D).
- **Audio**: ecualizador con presets, modo bit-perfect / Hi-Fi, velocidad y
  pitch independientes, fade in/out, decodificación DSD → PCM, badges de
  formato (FLAC / Hi-Res / bitrate).
- **Extras**: letras sincronizadas, mini reproductor flotante estilo Dynamic
  Island (Android), cola con drag & drop.

## Build local

Requiere Flutter (canal stable) y JDK 21.

```bash
flutter pub get
flutter run                 # debug en device conectado
flutter build apk --release # APK en build/app/outputs/flutter-apk/Vibra-<version>.apk
```

> **JDK**: AGP/Kotlin no compilan con JDK 26. Si tu sistema usa JDK 26,
> apunta Gradle a un JDK 21 vía `~/.gradle/gradle.properties`:
> `org.gradle.java.home=/ruta/a/jdk21`.

## Releases automáticos

Empujar un tag `v*` dispara el workflow de GitHub Actions que compila el
APK y crea un Release con el archivo adjunto:

```bash
# subir la versión en pubspec.yaml primero (version: X.Y.Z+N), luego:
git tag v1.0.9
git push origin v1.0.9
```

El APK sale nombrado `Vibra-<version>.apk`.

## Licencia

Sin licencia explícita — todos los derechos reservados por el autor.
