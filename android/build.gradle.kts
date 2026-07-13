group = "com.dreadashes.vibra"
version = "1.0-SNAPSHOT"

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.layout.buildDirectory.value(rootProject.layout.projectDirectory.dir("../build"))

subprojects {
    project.layout.buildDirectory.value(rootProject.layout.buildDirectory.dir(project.name))
}

subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    val configureAndroid = {
        val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (android != null) {
            // Fix: AGP 8+ requiere 'namespace'. Si un plugin antiguo no lo tiene,
            // lo generamos dinámicamente basándonos en su nombre.
            if (android.namespace == null) {
                val name = project.name.replace("-", ".").replace("_", ".")
                android.namespace = "com.vibra.generated.$name"
            }

            // Fix: AGP 8.x+ prohíbe el atributo 'package' en el AndroidManifest.xml
            // de las librerías si se usa namespace. Como no podemos editar el 
            // .pub-cache a mano fácilmente, lo limpiamos por script.
            if (project != rootProject) {
                val manifestFile = project.file("src/main/AndroidManifest.xml")
                if (manifestFile.exists()) {
                    val content = manifestFile.readText()
                    if (content.contains("package=")) {
                        val newContent = content.replace(Regex("package=\"[^\"]*\""), "")
                        manifestFile.writeText(newContent)
                    }
                }
            }

            // Sync JVM Target (Kotlin) con Java
            project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                val javaVersion = android.compileOptions.targetCompatibility
                compilerOptions {
                    when (javaVersion) {
                        JavaVersion.VERSION_1_8 -> jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
                        JavaVersion.VERSION_11 -> jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
                        JavaVersion.VERSION_17 -> jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                        else -> jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
                    }
                }
            }
        }
    }

    if (project.state.executed) {
        configureAndroid()
    } else {
        project.afterEvaluate {
            configureAndroid()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
