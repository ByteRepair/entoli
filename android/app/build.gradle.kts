import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The environment before android/key.properties, so a stray properties file
// cannot change what CI signs with and a password with a backslash in it is
// not read as an escape. See "Releasing" in CLAUDE.md.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingSetting(variable: String, property: String): String? =
    System.getenv(variable) ?: keystoreProperties.getProperty(property)

val keystorePath = signingSetting("ANDROID_KEYSTORE_FILE", "storeFile")
val keystorePassword = signingSetting("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val keystoreAlias = signingSetting("ANDROID_KEY_ALIAS", "keyAlias")
val keystoreAliasPassword = signingSetting("ANDROID_KEY_PASSWORD", "keyPassword")

android {
    namespace = "io.github.yiannis128.agent_chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.yiannis128.agent_chat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 26, not flutter.minSdkVersion (24): adaptive icons start here, and
        // below it every icon needs a second set of rasters.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // All four or none: a fresh clone has none, and a half-filled
        // key.properties would otherwise build a config with null members and
        // fail deep inside AGP rather than falling back below.
        if (keystorePath != null && keystorePassword != null &&
            keystoreAlias != null && keystoreAliasPassword != null
        ) {
            create("release") {
                // An absolute path — what CI passes — resolves unchanged, and a
                // relative one against android/, where key.properties lives.
                storeFile = rootProject.file(keystorePath)
                storePassword = keystorePassword
                keyAlias = keystoreAlias
                keyPassword = keystoreAliasPassword
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            // Keeps `flutter run --release` working without a keystore.
            // release.yml refuses to publish what that produces.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
