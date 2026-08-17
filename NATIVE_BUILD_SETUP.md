# Android Native Build Setup

## Steps to Configure Android NDK Build

### 1. Generate Android Project
```bash
flutter create --platforms android .
```

### 2. Update `android/app/build.gradle`

Add this inside the `android` block (after `compileSdkVersion`):

```gradle
externalNativeBuild {
    cmake {
        path "../../cpp/CMakeLists.txt"
        version "3.18.1"
    }
}
```

And in the `defaultConfig` block, add:

```gradle
externalNativeBuild {
    cmake {
        cppFlags "-std=c++17"
        arguments "-DCMAKE_BUILD_TYPE=Release"
    }
}

ndk {
    abiFilters 'arm64-v8a', 'armeabi-v7a'
}
```

### 3. Configure BLE Permissions

Edit `android/app/src/main/AndroidManifest.xml` and add these permissions:

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

Also add in the `<application>` tag if targeting Android 12+:
```xml
android:usesCleartextTraffic="false"
```

### 4. Build APK

```bash
flutter build apk --release
```

The native library will be automatically compiled and included as `libkore_signal.so` in the APK.

### 5. Verify Native Library

```bash
unzip build/app/outputs/flutter-apk/app-release.apk
unzip -l lib/arm64-v8a/libkore_signal.so
```

## Troubleshooting

**CMake not found**: Install Android NDK from Android Studio > SDK Manager > SDK Tools

**Library load failed**: Check `flutter run -v` logs for FFI errors

**BLE scanning fails**: Ensure runtime permissions are requested (flutter_reactive_ble handles this)
