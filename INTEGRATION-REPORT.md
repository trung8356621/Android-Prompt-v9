# V8 feature integration report — 2026-10-12

## Architecture retained from v9

| Function | Implementation |
|---|---|
| Vietnamese input | Fcitx5 + UniKey VNI on Android; explicit verified UniKey subtype |
| Keyboard/mouse transport | scrcpy 4.1 UHID, no video/audio |
| Unicode text clipboard | Existing scrcpy clipboard protocol; no second synchronizer |
| Lifecycle | Single launcher/mutex, one supervised scrcpy child, bounded restart, tray Exit |
| Routing | Alt+1 enters Android; RightAlt releases UHID and restores the saved Windows foreground window |

## V8 behavior transferred

| V8 behavior | V9 integration |
|---|---|
| Android screenshot to Windows clipboard | Reused the proven ADB screencap/pull/clipboard approach, with clipboard retry/read-back |
| Contextual physical PrtScr | Reimplemented as a state-bound hotkey: registered only while routing is Android, unregistered on return/disconnect |
| Cleanup on disconnect | V9 now returns focus/input to Windows before restarting its scrcpy child |
| Release stuck local input before switch | One bounded event-time release check covers Ctrl/Alt/Shift and five mouse buttons; no continuous polling |

## Legacy components excluded

- `input-bridge.ps1`, hidden WinForms TextBox and Enter-to-send buffer.
- 35 ms middle-button polling/hook, recording beeps and legacy timers.
- ADBKeyboard selection and `ADB_INPUT_B64`/`ADB_INPUT_CODE` broadcasts.
- Blind synthetic RightAlt toggles.
- v8 tray/screenshot helper processes; functionality lives in the single v9 supervisor.

Middle click is forwarded unchanged by scrcpy (`--mouse-bind=++++:++++`) and has no v9 hook.

## Verification status

| Test | Status | Evidence |
|---|---|---|
| Static/native compilation | PASS | Windows PowerShell 5.1 |
| Unit/regression suite | PASS | 16/16 |
| VNI laptop → UHID → Fcitx | PASS | ChatGPT UI read-back: `á à ơ đ kỳ tiếng` |
| Second Android field VNI | PASS | Chrome address field: `á ơ đ kỳ tiếng` |
| Stateful Windows ↔ Android switches | PASS | 10/10 Android and Windows route events logged |
| scrcpy unexpected exit | PASS | Windows route restored before supervised restart; PID changed |
| No legacy helpers | PASS | Runtime process inventory contained only v9 launcher + its scrcpy child |
| No ADBKeyboard takeover | PASS | Fcitx component + UniKey subtype read back; source regression guard |
| Middle button unchanged | PASS (configuration) | no middle hook; all secondary buttons forwarded |
| Screenshot capture pipeline | PASS | device screencap/pull PNG automated check |
| Physical PrtScr routing/clipboard | BLOCKED | requires one real PrtScr press; synthetic Windows events do not reproduce this hardware key reliably |
| Unicode clipboard shortcut | BLOCKED | synthetic RightAlt+V did not provide a reliable foreground-input test; existing scrcpy path was not modified |
| Physical mouse button behavior | BLOCKED | requires observing the phone and Windows pointer |

## Run and rollback

Run `Android-Prompt-v9.bat`. Use Alt+1, RightAlt and Android-context PrtScr as documented in `README.md`. To roll back code, unpack the pre-integration checkpoint from the workspace `work` folder. To restore the Android IME saved during initial setup, run `restore-previous-ime.ps1`; routine v9 Exit does not replace Fcitx with another IME.
