# Android Prompt Clipboard helper

This helper receives images over the existing ADB connection and saves each one as a unique PNG in Android MediaStore under `Pictures/AndroidPrompt`. It does not read or synchronize clipboard text and does not use the network.

Build with JDK 17, Android SDK 35 and Gradle 8.9:

```powershell
gradle --no-daemon :app:assembleDebug
```

Install `app/build/outputs/apk/debug/app-debug.apk` with `adb install -r`. Alt+3 saves the current Windows clipboard image without opening or focusing an Android app. In Zalo, use Attach/Image and select it from Photos. The tray command **Share last Android image** remains an optional shortcut.
