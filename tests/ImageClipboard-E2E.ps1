[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $root 'tools\adb.exe'
$serials = @(& $adb devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { $Matches[1] })
if ($serials.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
$serial = $serials[0]; $package = 'com.androidprompt.clipboard'
$remoteRoot = "/sdcard/Android/data/$package/files"; $tempFiles = [Collections.Generic.List[string]]::new()

function Send-TestImage([Drawing.Color]$color) {
    $name = "clip-$([guid]::NewGuid().ToString('N')).png"; $local = Join-Path $env:TEMP $name; $tempFiles.Add($local)
    $bitmap = [Drawing.Bitmap]::new(64,64)
    try { $graphics = [Drawing.Graphics]::FromImage($bitmap); try { $graphics.Clear($color) } finally { $graphics.Dispose() }; $bitmap.Save($local,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    & $adb -s $serial shell mkdir -p "$remoteRoot/incoming" | Out-Null
    & $adb -s $serial push $local "$remoteRoot/incoming/$name" | Out-Null
    & $adb -s $serial shell am start -n "$package/.BootstrapActivity" | Out-Null
    $result = (& $adb -s $serial shell am broadcast --receiver-include-background -n "$package/.ImageClipboardReceiver" -a "$package.SET_IMAGE" --es filename $name --es mime image/png | Out-String)
    if ($result -notmatch 'result=1') { throw "Receiver rejected $name`: $result" }
    $expected = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    $actual = (& $adb -s $serial shell cat "$remoteRoot/status/$name.ok" | Out-String).Trim()
    if ($actual -ne $expected) { throw "Integrity mismatch for $name" }
    & $adb -s $serial shell rm -f "$remoteRoot/status/$name.ok" | Out-Null
    Write-Host "PASS image transfer sha256=$expected"
    return $expected
}

try {
    $first = Send-TestImage ([Drawing.Color]::Red)
    $second = Send-TestImage ([Drawing.Color]::Blue)
    if ($first -eq $second) { throw 'Sequential images unexpectedly have identical hashes.' }
    $current = (& $adb -s $serial shell run-as $package sha256sum cache/clipboard/current.png | Out-String).Split(' ')[0].Trim()
    if ($current -ne $second) { throw 'The latest image did not replace the previous image.' }
    Write-Host 'PASS sequential images keep only the newest clipboard payload'
    $invalid = (& $adb -s $serial shell am broadcast --receiver-include-background -n "$package/.ImageClipboardReceiver" -a "$package.SET_IMAGE" --es filename ../invalid.png --es mime image/png | Out-String)
    if ($invalid -notmatch 'result=2') { throw 'Invalid filename was not rejected.' }
    Write-Host 'PASS invalid/absent image rejected'
} finally {
    foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
