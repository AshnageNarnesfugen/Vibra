plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
                val legacy = file(
                    "${flutterApkDir.path}/app-${variant.buildType.name}.apk"
                )
                if (!legacy.exists()) return@doLast
                val branded = file(
                    "${flutterApkDir.path}/Vibra-${versionName}" +
                        "${if (variant.buildType.name == "release") "" else "-${variant.buildType.name}"}.apk"
                )
                if (branded.exists()) branded.delete()
                legacy.copyTo(branded, overwrite = true)
                println("Vibra: APK con nombre de marca → ${branded.name}")
            }
        }
    }
}

flutter {
    source = "../.."
}
