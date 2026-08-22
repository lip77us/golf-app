import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase (push)
    id("com.google.gms.google-services")
}

// Release signing. The keystore and its passwords live OUTSIDE the repo:
// android/key.properties (gitignored) points at a .jks under ~/.
// Missing file = release builds fall back to debug signing, which builds fine
// locally but is rejected by Play — so the fallback is loud in the build log.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
} else {
    logger.warn("WARNING: android/key.properties not found — release builds " +
        "will be signed with the DEBUG key and Play will reject them.")
}

android {
    namespace = "golf.halved.app"
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
        // Permanent once the first bundle is published to Play — it can never
        // be changed afterwards. Chosen 2026-08-21, replacing the Flutter
        // template's com.lipkin.us.golf_mobile.
        applicationId = "golf.halved.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasReleaseSigning) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}
