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
$launcher = Get-Content -Raw (Join-Path $root 'src\Start-AndroidPrompt.ps1')
Assert ($native -match 'VK_SNAPSHOT' -and $native -match 'GetForegroundWindow\(\) == controlWindow') 'PrtScr is scoped to foreground Android control window'
Assert ($native -match 'return new IntPtr\(1\)') 'Android PrtScr is consumed before Windows capture'
Assert ($launcher -match 'exec-out screencap -p') 'screenshot streams directly from Android'
Assert ($native -notmatch 'VK_MBUTTON|WH_MOUSE') 'no middle-mouse input hook'
Assert ($launcher -notmatch 'input-bridge|ADB_INPUT|AdbIME|TextBox') 'no legacy chatbox or ADBKeyboard input'
Assert ($config.scrcpyArguments -contains '--mouse-bind=++++:++++') 'middle click forwards normally to Android'
Assert ($native -match 'Register\(EXIT_ANDROID, 0x32\)') 'Alt+2 return hotkey registered'
Assert ($launcher -match 'route-enter result=ANDROID_FOREGROUND' -and $launcher -match 'reason=already-foreground') 'repeated Alt+1 does not toggle capture'
Assert ($launcher -match 'route-exit result=WINDOWS_VERIFIED' -and $launcher -match 'control-not-foreground') 'repeated Alt+2 verifies observable Windows state'
Assert ($native -match 'Register\(SEND_IMAGE, 0x33\)' -and $launcher -match 'Send-WindowsImageToAndroid') 'Alt+3 sends the current Windows clipboard image on demand'
Assert ($launcher -match 'Pictures/AndroidPrompt' -and $launcher -match 'Share-LastAndroidImage') 'Alt+3 saves to Pictures and keeps explicit Share fallback'
Assert ($launcher -notmatch 'add_Clipboard|WM_CLIPBOARDUPDATE') 'image transfer does not add continuous clipboard synchronization'
Assert ($native -notmatch 'WM_PASTE_IMAGE|imageClipboardArmed|VK_V' -and $launcher -notmatch 'Paste-ArmedAndroidImage|add_PasteImage') 'image transfer does not intercept Ctrl+V'
Assert ($config.scrcpyArguments -notcontains '--no-clipboard-autosync') 'normal scrcpy text clipboard autosync remains enabled'
Assert ($launcher -match '--always-on-top' -and $launcher -match 'windowWidth = 180' -and $launcher -match 'windowHeight = 120') 'compact always-on-top control window configured'
Assert ($launcher -match "KEYCODE_WAKEUP") 'Android is awakened on entry'
Assert ($launcher -match 'finally[\s\S]*IsAndroidActive[\s\S]*Return-Windows') 'shutdown restores Windows routing before cleanup'
Assert ($launcher -notmatch 'function Return-Windows[\s\S]*?ToggleScrcpyCapture') 'Alt+2 releases capture by focus loss without RightAlt toggle'
Assert ($native -notmatch 'ToggleScrcpyCapture|keybd_event' -and $native -match 'CaptureScrcpyFromReleasedState') 'Alt+1 uses released-state click capture without blind RightAlt toggle'
Assert ($native -match 'first click while released' -and $launcher -match 'FOCUS_LOST') 'Alt+1 follows scrcpy released-state capture semantics'
Assert ($launcher -match 'startup routing observation[\s\S]*action=NONE') 'startup observes routing without changing focus or capture'
Assert ($launcher -match 'Get-WindowsFocusTarget' -and $launcher -match 'candidate -ne \$control') 'scrcpy control is never saved as Windows focus target'
Assert ($native -match 'FocusAndVerify' -and $launcher -match 'Could not verify Windows focus') 'routing verifies foreground transitions'
$core = Get-Content -Raw (Join-Path $root 'src\AndroidPrompt.Core.psm1')
Assert ($core.IndexOf("'ime','set'") -lt $core.IndexOf("'settings','put','secure','selected_input_method_subtype'")) 'UniKey subtype is selected after Android IME switch'

if ($failures.Count) { throw "$($failures.Count) unit test(s) failed: $($failures -join ', ')" }
Write-Host "PASS: $passes unit tests"
