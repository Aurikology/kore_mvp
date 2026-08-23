plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aurikology.kore"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aurikology.kore"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The same C++ the Windows bundle builds, compiled for the phone.
    //
    // `cpp/CMakeLists.txt` was written for this: its `if(ANDROID)` branch is
    // where `-fPIC` and the libc++ link live, kept out of the MSVC path
    // because cl.exe rejects both. `NativeDspEngine` already resolves
    // `libkore_signal.so` on the non-Windows path.
    //
    // Not a blocker for the APK. `createDspEngine()` falls back to the Dart
    // reference implementation when the library is missing, and the Dart path
    // is the one the tests validate - so this is a speed-up, not a dependency.
    //
    // No abiFilters. Flutter's release build already targets armeabi-v7a,
    // arm64-v8a and x86_64, and CMake follows it, so `libkore_signal.so` ships
    // for each - about 35 KB apiece against a 44 MB APK. Narrowing it would
    // save nothing measurable and would cost the emulator.
    externalNativeBuild {
        cmake {
            path = file("../../cpp/CMakeLists.txt")
            version = "3.22.1"
        }
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
