# Acceptance report

## Implemented architecture

Windows owns lifecycle, explicit entry hotkey, logging, image transfer and recovery. Official scrcpy 4.1 provides UHID keyboard/mouse and Unicode text clipboard transport. Android Fcitx5 + UniKey owns Vietnamese VNI composition. V9 never selects ADBKeyboard, transforms Vietnamese text on Windows, or changes persistent Android input settings.

This replaces v8's WinForms prompt, 35 ms middle-button polling, broadcast text injection, blind RightAlt `SendInput`, and forced IME mutation. V8 was cloned only to `work/Android-Prompt-v8-readonly` for audit and was not modified.

## Feature status

| Area | Status | Evidence / limit |
|---|---|---|
| Direct English/VNI input architecture | IMPLEMENTED, DEVICE BLOCKED | Fcitx project documents VNI and physical-keyboard support; target handset required |
| Explicit Windows → Android route | IMPLEMENTED | Alt+1 focuses supervised UHID session |
| Android → Windows release | IMPLEMENTED | Native scrcpy RightAlt capture release; Alt+Tab changes app |
| No duplicate Windows composition | IMPLEMENTED | No text bridge; raw UHID only |
| Unicode text clipboard | IMPLEMENTED, DEVICE BLOCKED | scrcpy native text synchronization |
| Windows image → Android | IMPLEMENTED | PNG import into Gallery; app attachment remains app-specific |
| Android image → Windows | IMPLEMENTED | Lossless physical-screen PNG capture |
| Arbitrary Android clipboard image → Windows | NOT AVAILABLE | Android/scrcpy clipboard is plain text; screenshot is the reliable fallback |
| Disconnect/process recovery | IMPLEMENTED | supervised restart limit and owned-child cleanup |
| Edge switching | NOT IMPLEMENTED | hotkey/release is less error-prone than edge polling |

## Test status

Host static/unit/package results are recorded in `TEST-RESULTS.md`. Device `324452025957` was exposed through the bundled ADB: Fcitx5 0.1.3 and its UniKey plugin were installed from the official GitHub release, Fcitx was enabled/selected, screenshot transfer passed, and a scrcpy 4.1 UHID session stayed alive. Tests that require watching or physically operating the phone remain **BLOCKED**; run the manual checklist for VNI, app focus, 100 switching cycles, buttons/scroll, disconnects and the 30-minute soak.

## Rollback

Stop v9 from the tray (or unplug USB). The runtime makes no IME changes. Because acceptance setup selected Fcitx, `restore-previous-ime.ps1` restores the saved former IME (`com.preff.kb.zx/com.preff.kb.LatinIME`) with read-back verification.
