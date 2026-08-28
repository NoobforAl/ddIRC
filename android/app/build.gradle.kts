plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
