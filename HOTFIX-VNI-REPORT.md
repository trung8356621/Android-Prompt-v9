# V9 Vietnamese UHID hotfix — 2026-10-12

## Root cause

Two independently observable input-selection states were wrong:

1. Android's actual default IME was `com.preff.kb.zx/com.preff.kb.LatinIME`, despite the Fcitx UniKey settings screen showing VNI/Unicode. V9 only logged a warning and continued.
2. After selecting Fcitx, its active Android 15 dynamic subtype was **English** (`283797060`), not **Unikey** (`-840535185`). Opening/configuring the UniKey plugin does not activate that input method. With English active, UHID `a1 o7 d9 ky2 tie61ng` correctly arrived as key events but was intentionally emitted unchanged.

The scrcpy transport was not defective. `dumpsys input` showed `scrcpy` as `KEYBOARD | ALPHAKEY` with `Generic.kl`; logcat recorded the expected down/up keycodes and scan codes, including digits 1/2/6/7/9. Upstream `FcitxInputMethodService.forwardKeyEvent()` converts these Android `KeyEvent`s and sends down/up events to fcitx as designed.

## Minimal fix

At startup, v9 now:

- finds the registered Android subtype whose name is `Unikey` from `dumpsys input_method`;
- enables/selects Fcitx;
- explicitly writes that exact subtype ID and rebinds Fcitx;
- reads back both default IME and subtype, failing startup if either selection did not stick.

This is explicit state management, not a blind Ctrl+Space toggle. No ADBKeyboard, WinForms text bridge, clipboard typing or text conversion was added.

## Device evidence

Device: Nubia `Z2461`, MyOS/Android 15, serial `324452025957`.

| Test | Result | Read-back evidence |
|---|---|---|
| Baseline, Fcitx active but English subtype | FAIL reproduced | `a1 o7 d9 ky2 tie61ng` |
| Hotfix startup selection | PASS | IME `org.fcitx.fcitx5.android/.input.FcitxInputMethodService`; subtype `-840535185` (`Unikey`) |
| ChatGPT input field through v9 scrcpy UHID | PASS | `á ơ đ kỳ tiếng` |
| Chrome address field through v9 scrcpy UHID | PASS | `á ơ đ kỳ tiếng` |
| Android InputReader key path | PASS | letters/digits observed with matching Down/Up and scan codes |
| Static/native compile | PASS | Windows PowerShell 5.1 |
| Unit tests | PASS | 12/12 |

The exact displayed Unicode strings were retrieved from Android UI hierarchy after input; ASCII transport alone was not counted as success.

## Files changed

- `src/AndroidPrompt.Core.psm1`
- `src/Start-AndroidPrompt.ps1`
- `tests/Unit.Tests.ps1`
- `tests/Device-E2E.ps1`

No v8 file was changed.
