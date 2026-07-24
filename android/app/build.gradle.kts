import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ─── Firma de release ───
// La identidad de firma DEBE ser estable entre builds: Android rechaza
// actualizar una app cuya firma cambió ("conflicto de paquetes" → obliga
// a desinstalar). Antes firmábamos release con la llave debug, que en
// GitHub Actions se regenera en CADA runner → cada release tenía firma
// distinta y ningún update instalaba encima del anterior.
//
// Fuentes de la config, en orden:
//   1. `android/key.properties` (gitignored) — builds locales.
//   2. Variables de entorno VIBRA_KEYSTORE_* — CI (el workflow decodifica
//      el keystore desde el secret KEYSTORE_BASE64).
//   3. Sin ninguna de las dos → fallback a la llave debug (contribuidores
//      sin keystore siguen pudiendo compilar).
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

fun signingValue(propKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propKey)?.takeIf { it.isNotBlank() }
        ?: System.getenv(envKey)?.takeIf { it.isNotBlank() }

android {
    namespace = "com.dreadashes.vibra"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dreadashes.vibra"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // on_audio_query y just_audio piden API ≥ 21; image_picker / permission_handler ≥ 23.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val storePath = signingValue("storeFile", "VIBRA_KEYSTORE_PATH")
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "VIBRA_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "VIBRA_KEY_ALIAS") ?: "vibra"
                keyPassword = signingValue("keyPassword", "VIBRA_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val releaseSigning = signingConfigs.getByName("release")
            signingConfig = if (releaseSigning.storeFile != null) {
                releaseSigning
            } else {
                // Sin keystore configurado: llave debug para que
                // `flutter run --release` siga funcionando out-of-the-box.
                signingConfigs.getByName("debug")
            }
        }
    }

    // Renombrar el APK final para que muestre el nombre real de la app
    // + la versión leída del pubspec (a través de `flutter.versionName`).
    // Antes el output era `app-release.apk` — confuso cuando se lo
    // mandas a beta testers y tienen 3 versiones distintas en el
    // teléfono con el mismo nombre.
    //
    // Resultado: `Vibra-0.1.0.apk` (o `Vibra-0.1.0-arm64-v8a.apk` para
    // splits ABI). El `buildType.name` se anexa solo si es debug porque
    // el release lo da por sentado el contexto (es el APK que mandas).
    applicationVariants.all {
        val variant = this
        val versionName = variant.versionName ?: "unknown"
        outputs.all {
            val output = this
                as com.android.build.gradle.internal.api.BaseVariantOutputImpl
            val flavor = if (variant.buildType.name == "release") {
                ""
            } else {
                "-${variant.buildType.name}"
            }
            // Si el split de ABI está activo, `output.filters` trae el ABI
            // específico (armeabi-v7a, arm64-v8a, x86_64). Lo anexamos al
            // nombre para distinguirlo.
            val abi = output.filters
                .firstOrNull { it.filterType == "ABI" }
                ?.identifier
                ?.let { "-$it" }
                ?: ""
            output.outputFileName = "Vibra-${versionName}${flavor}${abi}.apk"
        }

        // Tras compilar, Flutter copia el APK a `build/app/outputs/flutter-apk/`
        // con su naming legacy (`app-release.apk`, `app-debug.apk`). El
        // copy es del plugin de Flutter, no de AGP, así que `outputFileName`
        // de arriba no lo afecta. Hookeamos un task post-assemble que
        // **duplica** ese archivo con nombre `Vibra-{version}.apk`.
        //
        // ⚠️ COPY no RENAME: si renombramos, `flutter run --release` y
        // `flutter install` rompen porque buscan `app-release.apk` por
        // path fijo. Mantenemos los dos archivos coexistiendo — Flutter
        // tool usa el viejo, tú distribuyes el nuevo.
        val capName = variant.buildType.name
            .replaceFirstChar { it.uppercaseChar() }
        afterEvaluate {
            tasks.findByName("assemble$capName")?.doLast {
                val flutterApkDir = file(
                    "${layout.buildDirectory.get()}/outputs/flutter-apk"
                )
                if (!flutterApkDir.exists()) return@doLast
                val typeName = variant.buildType.name
                val typeSuffix = if (typeName == "release") "" else "-$typeName"
                // Cubre tanto el APK universal (app-release.apk) como los
                // splits por ABI de `--split-per-abi`
                // (app-arm64-v8a-release.apk, etc.) que usa el CI para
                // publicar APKs de ~25MB en lugar del universal de 65MB.
                val pattern = Regex("^app-(?:(.+)-)?$typeName\\.apk$")
                flutterApkDir.listFiles()?.forEach { f ->
                    val m = pattern.find(f.name) ?: return@forEach
                    val abi = m.groupValues[1]
                        .let { if (it.isEmpty()) "" else "-$it" }
                    val branded = file(
                        "${flutterApkDir.path}/Vibra-${versionName}$typeSuffix$abi.apk"
                    )
                    if (branded.exists()) branded.delete()
                    f.copyTo(branded, overwrite = true)
                    println("Vibra: APK con nombre de marca → ${branded.name}")
                }
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // jump3r: port Java completo de LAME 3.98 (encoder MP3). Se usa en
    // Mp3TranscoderPlugin para las descargas "como MP3". Java puro →
    // cero NDK, compila para todos los ABIs. LGPL (linkado dinámico).
    implementation("de.sciss:jump3r:1.0.5")
}
