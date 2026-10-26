import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: signingProperties.getProperty(property)?.takeIf { it.isNotBlank() }
val releaseStore = signingValue("storeFile", "GUOGUO_ANDROID_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "GUOGUO_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "GUOGUO_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "GUOGUO_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStore, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).all { it != null }
// AOT/R8 preview packages stay separate from the fixed-signature public app.
val previewBuild = System.getenv("GUOGUO_ANDROID_PREVIEW") == "true"
if (!hasReleaseSigning && !previewBuild && gradle.startParameter.taskNames.any { it.substringAfterLast(':').endsWith("Release") }) {
    throw GradleException("Android release signing is missing. Configure key.properties or GUOGUO_ANDROID_* signing variables; see docs/android-tv.md.")
}

android {
    namespace = "com.maxduke.guoguo_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.maxduke.guoguo_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // gradle.properties keeps this build number identical for all APK ABIs.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "果果"
        if (project.findProperty("split-per-abi")?.toString() != "true") {
            ndk { abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a", "x86_64")) }
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "果果 测试"
        }
        release {
            if (previewBuild) {
                applicationIdSuffix = ".dev"
                versionNameSuffix = "-dev"
                manifestPlaceholders["appLabel"] = "果果 测试"
                signingConfig = signingConfigs.getByName("debug")
            } else {
                signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
