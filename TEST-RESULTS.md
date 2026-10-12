# Test results — 2026-10-12 (Asia/Saigon)

## PASS

- PowerShell syntax: 6 files parsed with zero errors.
- Native interop: `NativeWindow.cs` compiled under Windows PowerShell 5.1.
- Unit tests: 12/12 (including explicit UniKey subtype parsing and fail-closed behavior when it is absent).
- Runtime: official scrcpy 4.1 binary and required dependencies load.
- Device discovery: ADB-authorized Nubia/MyOS device `324452025957` detected.
- Android prerequisites: arm64 Fcitx5 0.1.3 and UniKey plugin installed successfully; Fcitx IME enabled and selected.
- Device smoke: PNG screenshot pulled successfully (1,337,186 bytes during the run).
- UHID smoke: exact v9 scrcpy keyboard/mouse arguments started and remained alive for 3 seconds; owned process then terminated cleanly.
- Automated device checks: 6/6, including selected UniKey subtype; evidence in `logs/device-e2e.json`.
- Vietnamese UHID device verification: PASS in ChatGPT and Chrome; `a1 o7 d9 ky2 tie61ng` read back as `á ơ đ kỳ tiếng` in both fields. See `HOTFIX-VNI-REPORT.md`.

## BLOCKED — physical observation required

- VNI English/Vietnamese, tones, circumflex/special characters, correction and long text.
- Enter / Shift+Enter / Ctrl+Enter behavior in each target Android app.
- UniKey Windows non-interference and no double accents.
- Alt+1 / RightAlt routing, Antigravity focus, Android chat focus, 100 cycles, no duplicate input or stuck modifiers/capture.
- Left/right/middle buttons and scrolling.
- Unicode clipboard in both directions and no synchronization loop.
- Windows PNG/JPEG/Snipping Tool → Gallery → target-app attachment.
- Lock/unlock, USB disconnect/reconnect, helper restart, abrupt exit/restart and orphan-process inspection.
- 30-minute continuous-use soak.

These are not reported as PASS because this Work session can issue ADB commands but cannot see or physically operate the separate phone display or wait for human confirmation.

## FAIL / incomplete

- No automated/manual failure was observed.
- Production readiness is intentionally **not claimed** until all BLOCKED checks are completed.
- GitHub repository creation was unavailable because `gh auth status` reported no authenticated host. The independent source and runnable package are delivered locally.
