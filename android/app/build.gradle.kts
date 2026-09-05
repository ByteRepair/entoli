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
    namespace = "io.byterepair.entoli"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // sherpa-onnx is desktop-only. Android's voice mode is the system's own
    // `TextToSpeech` and `SpeechRecognizer`, so nothing here ever loads these —
    // and they are 75 MB across the three ABIs, more than the rest of the APK
    // put together.
    //
    // Excluded at packaging rather than removed from the dependency graph,
    // because they are not ours to remove: `sherpa_onnx` declares all ten of
    // its per-platform packages itself, and pub resolves what a package asks
    // for. `dependency_overrides` is the only other lever, and it replaces a
    // package on *every* platform — see the `sherpa_onnx_web` stub, which is
    // worth that risk only because it is one package rather than four.
    packaging {
        jniLibs {
            // Extracted rather than mapped from inside the APK: the bundled
            // tools are executables, and an app may only exec a real file in
            // its native library directory. APK-wide rather than per library —
            // AGP has no finer lever — so every other `.so` is stored
            // compressed and unpacked at install too. See "Bundled tools" in
            // CLAUDE.md.
            useLegacyPackaging = true

            excludes += setOf(
                "**/libonnxruntime.so",
                "**/libsherpa-onnx-c-api.so",
                "**/libsherpa-onnx-cxx-api.so",
            )
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.byterepair.entoli"
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
            // The name and artwork that go with this suffix are in
            // src/debug/res/.
            applicationIdSuffix = ".debug"
        }
        release {
            // Keeps `flutter run --release` working without a keystore.
            // release-build.yml refuses to ship what that produces.
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
