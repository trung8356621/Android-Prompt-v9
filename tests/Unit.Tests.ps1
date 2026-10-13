$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\AndroidPrompt.Core.psm1') -Force
$failures = [Collections.Generic.List[string]]::new()
$passes = 0
function Assert([bool]$condition, [string]$name) {
    if ($condition) { $script:passes++; Write-Host "PASS $name" }
    else { $script:failures.Add($name); Write-Host "FAIL $name" }
}

$one = Select-AdbDevice @([pscustomobject]@{Serial='abc';State='device'}) ''
Assert ($one.Serial -eq 'abc') 'selects sole authorized device'
$chosen = Select-AdbDevice @([pscustomobject]@{Serial='a';State='device'},[pscustomobject]@{Serial='b';State='device'}) 'b'
Assert ($chosen.Serial -eq 'b') 'selects configured serial'
try { Select-AdbDevice @([pscustomobject]@{Serial='a';State='offline'}) ''; Assert $false 'rejects offline device' } catch { Assert $true 'rejects offline device' }
try { Select-AdbDevice @() ''; Assert $false 'reports no connected device clearly' } catch { Assert ($_.Exception.Message -eq 'No authorized Android device detected.') 'reports no connected device clearly' }
try { Select-AdbDevice @([pscustomobject]@{Serial='a';State='device'},[pscustomobject]@{Serial='b';State='device'}) ''; Assert $false 'rejects ambiguous devices' } catch { Assert $true 'rejects ambiguous devices' }
Assert ((Get-SafeImageExtension 'jpeg') -eq '.jpg') 'maps jpeg extension'
Assert ((Get-SafeImageExtension 'anything') -eq '.png') 'defaults to png extension'
$config = Get-Content -Raw (Join-Path $root 'config.json') | ConvertFrom-Json
Assert ($config.scrcpyArguments -contains '--keyboard=uhid') 'UHID keyboard configured'
Assert ($config.scrcpyArguments -contains '--mouse=uhid') 'UHID mouse configured'
Assert ($config.scrcpyArguments -contains '--no-video') 'video disabled'
Assert (-not ($config.scrcpyArguments -match 'adbkeyboard|legacy-paste')) 'no ADBKeyboard bridge'
$fixture = 'mSubtypeNameOverride=Unikey mPkLanguageTag= mSubtypeId=-840535185 mSubtypeMode=keyboard'
Assert ((Get-FcitxUniKeySubtypeIdFromDump $fixture) -eq -840535185) 'parses explicit UniKey subtype id'
try { Get-FcitxUniKeySubtypeIdFromDump 'mSubtypeNameOverride=English mSubtypeId=1'; Assert $false 'rejects missing UniKey subtype' } catch { Assert $true 'rejects missing UniKey subtype' }
$native = Get-Content -Raw (Join-Path $root 'src\NativeWindow.cs')
$headless = Get-Content -Raw (Join-Path $root 'src\HeadlessInputBridge.cs')
$imageWorker = Get-Content -Raw (Join-Path $root 'src\ImageTransferWorker.cs')
$launcher = Get-Content -Raw (Join-Path $root 'src\Start-AndroidPrompt.ps1')
$batch = Get-Content -Raw (Join-Path $root 'Android-Prompt-v9.bat')
$scrcpyPatch = Get-Content -Raw (Join-Path $root 'patches\scrcpy-4.1-ignore-printscreen.patch')
Assert ($headless -match 'VK_SNAPSHOT' -and $headless -match 'state != RoutingState.Android') 'PrtScr is scoped to Android routing state'
Assert ($headless -match 'CaptureAndroid' -and $headless -match 'return new IntPtr\(1\)') 'Android PrtScr is consumed before Windows capture'
Assert ($scrcpyPatch -match 'sdl_keycode == SDLK_PRINTSCREEN' -and $scrcpyPatch -match '\+        return;') 'custom scrcpy prevents PrintScreen from reaching Android through UHID'
Assert ($launcher -match 'exec-out screencap -p') 'screenshot streams directly from Android'
Assert ($headless -match 'WM_MBUTTONDOWN' -and $headless -match 'mouseButtons \|= 4') 'middle mouse is forwarded over UHID'
Assert ($headless -match 'ProcessRawInput' -and $headless -match 'GetRawInputData' -and $headless -notmatch 'SetCursorPos|warpPending') 'mouse motion uses raw relative deltas without cursor recentering'
Assert ($launcher -notmatch 'input-bridge|ADB_INPUT|AdbIME|TextBox') 'no legacy chatbox or ADBKeyboard input'
Assert ($config.scrcpyArguments -contains '--mouse-bind=++++:++++') 'middle click forwards normally to Android'
Assert ($native -match 'Register\(EXIT_ANDROID, 0x32\)') 'Alt+2 return hotkey registered'
Assert ($headless -match 'state != RoutingState.Windows' -and $headless -match 'state == RoutingState.Android') 'repeated Alt+1 preserves Android routing'
Assert ($headless -match 'if \(state == RoutingState.Windows\) return') 'repeated return preserves Windows routing'
Assert ($native -match 'Register\(SEND_IMAGE, 0x33\)' -and $launcher -match 'Send-WindowsImageToAndroid') 'Alt+3 sends the current Windows clipboard image on demand'
Assert ($imageWorker -match '/sdcard/Pictures/AndroidPrompt' -and $imageWorker -match 'scan_file' -and $launcher -match 'TryStart') 'Alt+3 asynchronously saves and indexes Pictures/AndroidPrompt'
Assert ($imageWorker -match 'CompareExchange' -and $imageWorker -match 'TimeoutMs|timeoutMs' -and $launcher -notmatch 'Share-LastAndroidImage') 'image worker prevents overlap, bounds ADB calls and removes unreliable Share'
Assert ($launcher -match 'function Log[^{]+\{ try \{ \[void\]\(Write-V9Log' -and $launcher -notmatch 'Write-Host') 'runtime logging cannot block on console selection'
Assert ($launcher -notmatch 'add_Clipboard|WM_CLIPBOARDUPDATE') 'image transfer does not add continuous clipboard synchronization'
Assert ($native -notmatch 'WM_PASTE_IMAGE|imageClipboardArmed|VK_V' -and $launcher -notmatch 'Paste-ArmedAndroidImage|add_PasteImage') 'image transfer does not intercept Ctrl+V'
Assert ($launcher -match 'Start-ClipboardSession' -and $launcher -match "'--no-window'" -and $launcher -match "'--keyboard=disabled'" -and $launcher -match "'--mouse=disabled'") 'text clipboard autosync runs in a no-window non-input session'
Assert ($launcher -notmatch '--always-on-top|windowWidth|windowHeight|SetForegroundWindow') 'no visible or topmost control window configured'
Assert ($batch -match 'start "" powershell\.exe' -and $batch -match '-WindowStyle Hidden') 'batch launcher detaches into a hidden background process'
Assert ($launcher -match "KEYCODE_WAKEUP") 'Android is awakened on entry'
Assert ($launcher -match 'finally[\s\S]*IsAndroidActive[\s\S]*Return-Windows') 'shutdown restores Windows routing before cleanup'
Assert ($headless -match 'VK_RMENU' -and $headless -match 'EmergencyReturn') 'RightAlt is an emergency return path'
Assert ($headless -match 'RoutingState\.EnteringAndroid' -and $headless -match 'RoutingState\.ReturningWindows' -and $headless -match 'RoutingState\.Disconnected') 'explicit routing transition states are implemented'
Assert ($headless -match 'SendCreate\(KEYBOARD_ID' -and $headless -match 'SendCreate\(MOUSE_ID') 'headless bridge creates keyboard and mouse UHID devices'
Assert ($headless -match 'data\.vkCode' -and $headless -notmatch 'ToUnicode|keybd_event') 'keyboard routing uses physical key events rather than composed Windows text'
Assert ($headless -match 'UnhookWindowsHookEx' -and $headless -match 'ReleaseAll\(\)' -and $launcher -match '\$inputBridge\.Dispose\(\)') 'shutdown releases UHID state and global hooks'
Assert ($launcher -notmatch 'GetForegroundWindow|SetForegroundWindow|MainWindowHandle') 'routing has no foreground-window dependency'
$core = Get-Content -Raw (Join-Path $root 'src\AndroidPrompt.Core.psm1')
Assert ($core.IndexOf("'ime','set'") -lt $core.IndexOf("'settings','put','secure','selected_input_method_subtype'")) 'UniKey subtype is selected after Android IME switch'

if ($failures.Count) { throw "$($failures.Count) unit test(s) failed: $($failures -join ', ')" }
Write-Host "PASS: $passes unit tests"
