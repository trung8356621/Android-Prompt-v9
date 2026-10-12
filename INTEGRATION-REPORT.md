# V8 experience + V9 VNI repair report — 2026-10-12

## Root causes and repairs

| Area | Root cause | Repair |
|---|---|---|
| Routing | V9 equated focus/internal state with scrcpy capture and exposed RightAlt | Alt+1/Alt+2 now drive a tracked scrcpy capture transition; duplicate transitions are ignored and prior Windows focus is restored |
| Screenshot | PrtScr depended on the possibly-wrong internal route flag | Physical PrtScr is consumed only when the actual scrcpy control window is foreground; capture streams `adb exec-out screencap -p` directly to the Windows clipboard |
| Window | Compact v8 placement was missing | Restored 180×120, top-right, always-on-top control window |
| Cleanup | Exit could terminate while Android capture remained active | Exit/disconnect restores Windows routing before disposing owned resources |
| Scope leak | Experimental Windows-image push remained | Removed Alt+3, its menu/config entry, and implementation |

## Architecture retained from V9

- Android Fcitx5 + UniKey owns VNI composition; dynamic UniKey subtype selection and verification are unchanged.
- scrcpy 4.1 UHID carries raw keyboard/mouse events (`--keyboard=uhid`, `--mouse=uhid`).
- Single mutex/launcher/tray supervisor, bounded scrcpy restart, and native Unicode text clipboard behavior.

## V8 behavior reused

- Alt+1 enter, Alt+2 return, compact control window, foreground-scoped PrtScr, direct ADB screenshot stream, and previous-app focus restoration.
- V8 stayed read-only; no history merge or legacy helper process was introduced.

## Legacy excluded

- Middle-button polling/hook, WinForms input box, beep/timer input workflow, ADBKeyboard broadcasts, Alt+3 image push, and separate v8 tray/screenshot/input helpers.

## Verification

| Test | Status | Evidence / limit |
|---|---|---|
| Static parse + native compile | PASS | Windows PowerShell 5.1 |
| Host regression | PASS | 25/25 unit assertions |
| ADB authorized, Fcitx/UniKey read-back and screenshot PNG | PASS | 6/6 device checks after launcher preflight |
| Android 15 subtype overwrite regression | PASS | reproduced, then fixed by selecting UniKey after `ime set`; preflight read-back passed |
| Earlier VNI laptop → UHID → Fcitx | PASS | ChatGPT and Chrome read-back; see `HOTFIX-VNI-REPORT.md` |
| Current build routing, physical mouse, PrtScr clipboard, disconnect/reconnect, 20-cycle switching | BLOCKED | requires live user observation; API success is not counted |

Branch: `fix/v8-experience-v9-vni`. Phase commits: `17e5510`, `3612770`, `284cf5e`. Production readiness is not claimed until the BLOCKED checks pass.
