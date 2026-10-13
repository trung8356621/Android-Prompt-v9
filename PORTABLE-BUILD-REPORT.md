# Portable build report

- Source baseline: `experiment/headless` at `0ceedb3`.
- Packaging branch: `experiment/portable-exe`.
- Architecture: x64 .NET Framework Windows GUI launcher starts the existing Windows PowerShell 5.1 STA application host using executable-relative paths. No input-routing or Android IME logic is duplicated in the launcher.
- Icon: original project SVG plus a generated seven-size ICO (16, 24, 32, 48, 64, 128, 256); embedded in the EXE and loaded by the tray icon.
- Runtime: audited scrcpy 4.1 bundle already used by this repository, including ADB, SDL3, FFmpeg and libusb DLLs; Android clipboard helper APK included.

## Verification

- PASS: clean reproducible build and ZIP creation.
- PASS: 41 host unit/static tests.
- PASS: PE GUI subsystem and embedded application icon.
- PASS: tray source uses the custom ICO.
- PASS: launcher executed from a Unicode path containing spaces on another drive using relative resources.
- PASS: required runtime/package inventory.
- BLOCKED: live tray appearance, duplicate-instance UI, physical Android VNI, Windows UniKey ON/OFF, mouse/click/scroll, clipboard/image, USB disconnect and long-running cleanup were not retested during packaging because an existing user session was not disrupted.

## Known limitation

The EXE is a GUI launcher, not a single-file rewrite. The extracted `src`, `tools`, `assets`, configuration and runtime DLL files are required. Windows PowerShell 5.1 and .NET Framework 4.x are expected components of supported Windows 10/11 systems.
