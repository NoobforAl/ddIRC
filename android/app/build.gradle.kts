import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release keystore. `make keystore` writes it, and the four values below,
// to android/ddirc-release.jks and android/key.properties — both gitignored,
// both inside the repo rather than somewhere global, so this key can never be
// confused with an unrelated one already sitting in a machine-wide keystore
// directory. CI has no key.properties, so it sets the same four names as env
// vars instead, decoded from repo secrets in release.yml. Neither present —
// a fresh checkout nobody has run `make keystore` on yet — leaves storeFile
// null, and buildTypes.release below falls back to the debug key so
// `flutter run --release` still works.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun signingProp(propertyName: String, envName: String): String? =
    keystoreProperties.getProperty(propertyName) ?: System.getenv(envName)

android {
    namespace = "dev.ddirc.ddirc"
    // Pinned above flutter.compileSdkVersion, which is 36 in this Flutter.
    // flutter_secure_storage — where profile passwords live — is built against
    // 37, and a dependency compiled against a newer SDK than the app is a hard
    // build failure rather than a warning. Compiling against a newer SDK is
    // backward compatible and changes no runtime behaviour; that is targetSdk's
    // job, and it is left alone.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.ddirc.ddirc"
        // API 29, Android 10, pinned rather than left to flutter.minSdkVersion,
        // which is whatever the installed Flutter happens to default to and so
        // moves under the project without a commit.
        //
        // 29 because two things this app relies on begin there:
        //
        //  - `android:foregroundServiceType`, which ConnectionService declares
        //    in the manifest, is an API 29 attribute. Older Android ignores it,
        //    which means staying connected in the background — the entire point
        //    of that service — is not something this app can honestly claim to
        //    support below 29.
        //  - TLS 1.3 is enabled by default from Android 10. Every connection
        //    this client is meant to make is a TLS one, and the platform's own
        //    stack is what makes it.
        //
        // Raising it again wants the same treatment: a reason, written here,
        // that someone can weigh against the devices it excludes.
        //
        // `rust_builder/android/build.gradle` sets the same floor for the
        // native library. The two have to agree.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val path = signingProp("storeFile", "ANDROID_KEYSTORE_PATH")
            if (path != null) {
                storeFile = rootProject.file(path)
                storePassword = signingProp("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingProp("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingProp("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // The real key once one exists (see the comment above); the debug
            // key otherwise, so a fresh checkout can still build.
            signingConfig = if (signingConfigs.getByName("release").storeFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
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
