# Android Prompt Clipboard helper

This helper receives one image at a time over the existing ADB connection and places a `content://` URI in the Android system clipboard. It does not read or synchronize text and does not use the network.

Build with JDK 17, Android SDK 35 and Gradle 8.9:

```powershell
gradle --no-daemon :app:assembleDebug
```

Install `app/build/outputs/apk/debug/app-debug.apk` with `adb install -r`. The v9 launcher uses Alt+3 to transfer the current Windows clipboard image. If an Android app does not support image paste, use the tray command **Share last Android image**.
