$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root 'build\Build-Portable.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build
if ($LASTEXITCODE -ne 0) { throw 'Portable build failed.' }

$package = Join-Path $root 'dist\Android-Prompt-v9-Portable'
$zip = Join-Path $root 'dist\Android-Prompt-v9-Portable.zip'
$exe = Join-Path $package 'AndroidPrompt.exe'
$required = @(
    'AndroidPrompt.exe','config.json','README.md','PORTABLE-BUILD-REPORT.md','assets\icon.svg','assets\AndroidPrompt.ico',
    'src\Start-AndroidPrompt.ps1','src\HeadlessInputBridge.cs','tools\scrcpy.exe','tools\scrcpy-server',
    'tools\adb.exe','tools\AdbWinApi.dll','tools\AdbWinUsbApi.dll','tools\SDL3.dll',
    'tools\avcodec-62.dll','tools\avformat-62.dll','tools\avutil-60.dll','tools\swresample-6.dll',
    'tools\libusb-1.0.dll','android-helper\dist\AndroidPromptClipboard-debug.apk','licenses\README.md'
)
foreach ($relative in $required) { if (-not (Test-Path -LiteralPath (Join-Path $package $relative))) { throw "Package missing $relative" } }
if (-not (Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).Length -lt 1MB) { throw 'Portable ZIP is missing or unexpectedly small.' }

$bytes = [IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($bytes,0x3c)
$subsystem = [BitConverter]::ToUInt16($bytes,$pe + 4 + 20 + 68)
if ($subsystem -ne 2) { throw "AndroidPrompt.exe is not a Windows GUI executable (subsystem=$subsystem)." }
Add-Type -AssemblyName System.Drawing
$embedded = [Drawing.Icon]::ExtractAssociatedIcon($exe)
if ($null -eq $embedded) { throw 'AndroidPrompt.exe has no embedded icon.' }
try { if ($embedded.Width -lt 16 -or $embedded.Height -lt 16) { throw 'Embedded icon is invalid.' } } finally { $embedded.Dispose() }
$icoBytes = [IO.File]::ReadAllBytes((Join-Path $package 'assets\AndroidPrompt.ico'))
$iconCount = [BitConverter]::ToUInt16($icoBytes,4)
if ($iconCount -ne 7) { throw "ICO does not contain the expected seven sizes (count=$iconCount)." }
$iconSizes = for ($i=0; $i -lt $iconCount; $i++) { $value=$icoBytes[6 + (16*$i)]; if ($value -eq 0) { 256 } else { [int]$value } }
if (($iconSizes -join ',') -ne '16,24,32,48,64,128,256') { throw "Unexpected ICO sizes: $($iconSizes -join ',')" }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Android Prompt ü path ' + [Guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath($testRoot)
try {
    [IO.Directory]::CreateDirectory((Join-Path $testRoot 'src')) | Out-Null
    Copy-Item -LiteralPath $exe -Destination (Join-Path $testRoot 'AndroidPrompt.exe')
    $probe = "Set-Content -LiteralPath (Join-Path (Split-Path `$PSScriptRoot -Parent) 'launched.ok') -Value 'PASS' -Encoding ASCII"
    Set-Content -LiteralPath (Join-Path $testRoot 'src\Start-AndroidPrompt.ps1') -Value $probe -Encoding UTF8
    $launcher = Start-Process -FilePath (Join-Path $testRoot 'AndroidPrompt.exe') -PassThru
    $launcher.WaitForExit(5000) | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath (Join-Path $testRoot 'launched.ok')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'launched.ok'))) { throw 'EXE did not launch its relative script from a Unicode path containing spaces.' }
} finally {
    if ($resolvedTemp.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$traySource = Get-Content -Raw (Join-Path $root 'src\Start-AndroidPrompt.ps1')
if ($traySource -notmatch 'assets\\AndroidPrompt\.ico' -or $traySource -match 'SystemIcons') { throw 'Tray is not configured to use the custom icon.' }
Write-Host "PASS: portable package tests; zipBytes=$((Get-Item -LiteralPath $zip).Length)"
