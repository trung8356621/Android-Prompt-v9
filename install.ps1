[CmdletBinding()]
param([string]$ScrcpyDirectory = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$target = Join-Path $root 'tools'
[IO.Directory]::CreateDirectory($target) | Out-Null

if (-not $ScrcpyDirectory) {
    throw 'Provide the extracted official scrcpy Windows directory: .\install.ps1 -ScrcpyDirectory C:\path\to\scrcpy-win64-v4.1'
}
foreach ($required in @('scrcpy.exe','adb.exe','scrcpy-server','SDL3.dll','AdbWinApi.dll','AdbWinUsbApi.dll')) {
    $source = Join-Path $ScrcpyDirectory $required
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing $required in $ScrcpyDirectory" }
}
Get-ChildItem -LiteralPath $ScrcpyDirectory -File | Where-Object {
    $_.Extension -in @('.exe','.dll') -or $_.Name -eq 'scrcpy-server'
} | Copy-Item -Destination $target -Force
Write-Host "PASS: scrcpy runtime installed in $target"
Write-Host 'Next: install/select Fcitx5 + UniKey plugin on Android, choose VNI, then run Android-Prompt-v9.bat.'
