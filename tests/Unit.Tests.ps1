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
Assert ($launcher -match 'duplicate Alt\+1 ignored' -and $launcher -match 'duplicate Alt\+2 ignored') 'routing switches are idempotent'
Assert ($native -notmatch 'PUSH_IMAGE|PushImage' -and $launcher -notmatch 'Push-WindowsImage|clipboard image \(Alt\+3\)' -and -not $config.PSObject.Properties['pushImageHotkey']) 'Windows image push removed'
Assert ($launcher -match '--always-on-top' -and $launcher -match 'windowWidth = 180' -and $launcher -match 'windowHeight = 120') 'compact always-on-top control window configured'
Assert ($launcher -match "KEYCODE_WAKEUP") 'Android is awakened on entry'
Assert ($launcher -match 'finally[\s\S]*IsAndroidActive[\s\S]*Return-Windows') 'shutdown restores Windows routing before cleanup'
$core = Get-Content -Raw (Join-Path $root 'src\AndroidPrompt.Core.psm1')
Assert ($core.IndexOf("'ime','set'") -lt $core.IndexOf("'settings','put','secure','selected_input_method_subtype'")) 'UniKey subtype is selected after Android IME switch'

if ($failures.Count) { throw "$($failures.Count) unit test(s) failed: $($failures -join ', ')" }
Write-Host "PASS: $passes unit tests"
