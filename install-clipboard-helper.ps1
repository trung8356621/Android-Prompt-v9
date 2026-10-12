[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$adb = Join-Path $root 'tools\adb.exe'
$apk = Join-Path $root 'android-helper\dist\AndroidPromptClipboard-debug.apk'
if (-not (Test-Path -LiteralPath $adb)) { throw 'Missing tools\adb.exe. Run install.ps1 first.' }
if (-not (Test-Path -LiteralPath $apk)) { throw 'Missing clipboard helper APK.' }
$devices = @(& $adb devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { $Matches[1] })
if ($devices.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
& $adb -s $devices[0] install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'Clipboard helper installation failed.' }
& $adb -s $devices[0] shell am start -n com.androidprompt.clipboard/.BootstrapActivity | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Clipboard helper activation failed.' }
Write-Host 'PASS: Android Prompt Clipboard helper installed.'
