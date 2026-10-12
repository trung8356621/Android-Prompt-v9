# Android-Prompt-v9

V8 control experience with v9 direct Vietnamese input: Windows keyboard/mouse → scrcpy 4.1 UHID → Android Fcitx5 + UniKey VNI.

## Run

1. Connect one authorized Android device by USB.
2. Install scrcpy 4.1 if `tools` is absent: `powershell -ExecutionPolicy Bypass -File .\install.ps1 -ScrcpyDirectory C:\path\to\scrcpy-win64-v4.1`.
3. Install the optional image clipboard helper: `powershell -ExecutionPolicy Bypass -File .\install-clipboard-helper.ps1`.
4. Run `Android-Prompt-v9.bat`.

Controls:

- `Alt+1`: wake Android and route keyboard/mouse to it.
- `Alt+2`: release Android capture and restore the previous Windows app.
- `Alt+3`: transfer the current Windows clipboard image into the Android clipboard; then use Ctrl+V in an app that supports image paste.
- `PrtScr`: copy the physical Android screen to the Windows clipboard only while the Android control window is foreground.
- `Alt+4`: explicit Android screenshot fallback.
- Tray `Exit`: restore Windows input and stop only the scrcpy process owned by v9.

Repeated `Alt+1` or `Alt+2` is ignored once already in that state. Middle click and the other secondary mouse buttons are forwarded normally; there is no chatbox or ADBKeyboard. If an Android app does not accept image paste, use the tray command **Share last Android image**.

## Quick physical verification

After `Alt+1`, type `a1 a2 o7 d9 ky2 tie61ng` in an Android text field and expect `á à ơ đ kỳ tiếng`. Check left/right/middle click and scroll, then press `Alt+2` and confirm the previous Windows app regains focus. Test `PrtScr` once in Android and once in Windows. These observations cannot be certified by static tests.

## Rollback

Stop v9 from the tray and check out branch `fix/v8-experience-v9-vni` to remove only the image feature. The helper APK may be removed with `adb uninstall com.androidprompt.clipboard`.
