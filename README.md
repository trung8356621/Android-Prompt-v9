# Android-Prompt-v9

Experimental true-headless control: Windows physical keyboard/mouse hooks → scrcpy-server 4.1 control protocol → Android UHID → Fcitx5 + UniKey VNI. No scrcpy control window, overlay, or foreground-focus dependency is used.

## Portable Windows package

Build with `powershell -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Portable.ps1`. The reproducible output is `dist\Android-Prompt-v9-Portable.zip`.

To use it, extract the complete archive to any writable folder and double-click `AndroidPrompt.exe`. Keep `src`, `tools`, `assets`, and `config.json` beside the EXE. The launcher is a Windows GUI executable and starts the existing PowerShell STA host without a console window. Windows PowerShell 5.1, included with Windows 10/11, is required; scrcpy 4.1, ADB, and their DLLs are bundled.

Logs are written under the extracted package's `logs` directory. If Windows blocks a downloaded ZIP, open its Properties, select **Unblock**, then extract it again.

## Run

1. Connect one authorized Android device by USB.
2. Install scrcpy 4.1 if `tools` is absent: `powershell -ExecutionPolicy Bypass -File .\install.ps1 -ScrcpyDirectory C:\path\to\scrcpy-win64-v4.1`.
3. Install the optional image clipboard helper: `powershell -ExecutionPolicy Bypass -File .\install-clipboard-helper.ps1`.
4. Run `Android-Prompt-v9.bat`.

Controls:

- `Alt+1`: wake Android and route keyboard/mouse to it.
- `RightAlt` or `Alt+2`: release Android routing and immediately restore Windows input.
- `Alt+3`: transfer the current Windows clipboard image into the Android clipboard; then use Ctrl+V in an app that supports image paste.
- `PrtScr`: copy the physical Android screen to the Windows clipboard only while Android routing is active.
- `Alt+4`: explicit Android screenshot fallback.
- Tray `Exit`: restore Windows input and stop only the scrcpy process owned by v9.

Repeated transitions are idempotent. Middle click, secondary buttons, and scrolling are forwarded as UHID reports; there is no chatbox or ADBKeyboard. A separate input-disabled `scrcpy --no-window` session preserves Unicode text clipboard synchronization.

## Quick physical verification

Test with Windows UniKey both OFF and ON. After `Alt+1`, type `a1 a2 o7 d9 ky2 tie61ng` in an Android text field and expect `á à ơ đ kỳ tiếng`. Check left/right/middle click and scroll, then press `RightAlt` and confirm Windows receives input normally. Verify Ctrl+Shift before and after several transitions, and test `PrtScr` once in each mode. These observations cannot be certified by static tests.

## Rollback

Stop v9 from the tray, then run `git switch hotfix/alt2-extra-screenshot` to return to the exact pre-experiment baseline. No Android APK is added by this branch.
