[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $root 'tools\adb.exe'
$serials = @(& $adb devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { $Matches[1] })
if ($serials.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
$serial = $serials[0]; $package = 'com.androidprompt.clipboard'
$remoteRoot = "/sdcard/Android/data/$package/files"; $tempFiles = [Collections.Generic.List[string]]::new(); $testUris = [Collections.Generic.List[string]]::new()

function Send-TestImage([Drawing.Color]$color) {
    $name = "clip-$([guid]::NewGuid().ToString('N')).png"; $local = Join-Path $env:TEMP $name; $tempFiles.Add($local)
    $bitmap = [Drawing.Bitmap]::new(64,64)
    try { $graphics = [Drawing.Graphics]::FromImage($bitmap); try { $graphics.Clear($color) } finally { $graphics.Dispose() }; $bitmap.Save($local,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    & $adb -s $serial shell mkdir -p "$remoteRoot/incoming" | Out-Null
    & $adb -s $serial push $local "$remoteRoot/incoming/$name" | Out-Null
    & $adb -s $serial shell am start -n "$package/.BootstrapActivity" | Out-Null
    $result = (& $adb -s $serial shell am broadcast --receiver-include-background -n "$package/.ImageClipboardReceiver" -a "$package.SET_IMAGE" --es filename $name | Out-String)
    if ($result -notmatch 'result=1') { throw "Receiver rejected $name`: $result" }
    $ack = (& $adb -s $serial shell cat "$remoteRoot/status/$name.ok" | Out-String).Trim().Split('|')
    if ($ack.Count -ne 3) { throw "Invalid helper acknowledgement for $name" }
    $expected = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ack[0] -ne $expected) { throw "Integrity mismatch for $name" }
    $uri = $ack[1]; $displayName = $ack[2]; $testUris.Add($uri)
    $row = (& $adb -s $serial shell content query --uri $uri --projection '_display_name:relative_path:mime_type:_size' | Out-String)
    if ($row -notmatch [regex]::Escape($displayName) -or $row -notmatch 'relative_path=Pictures/AndroidPrompt/' -or $row -notmatch 'mime_type=image/png') { throw "MediaStore row is not gallery-visible: $row" }
    & $adb -s $serial shell rm -f "$remoteRoot/status/$name.ok" | Out-Null
    Write-Host "PASS MediaStore image name=$displayName uri=$uri sha256=$expected"
    return [pscustomobject]@{ Hash=$expected; Uri=$uri; Name=$displayName }
}

try {
    $first = Send-TestImage ([Drawing.Color]::Red)
    $second = Send-TestImage ([Drawing.Color]::Blue)
    if ($first.Hash -eq $second.Hash -or $first.Uri -eq $second.Uri -or $first.Name -eq $second.Name) { throw 'Sequential images were not stored uniquely.' }
    Write-Host 'PASS sequential images create unique persistent MediaStore items'
    $invalid = (& $adb -s $serial shell am broadcast --receiver-include-background -n "$package/.ImageClipboardReceiver" -a "$package.SET_IMAGE" --es filename ../invalid.png | Out-String)
    if ($invalid -notmatch 'result=2') { throw 'Invalid filename was not rejected.' }
    Write-Host 'PASS invalid/absent image rejected'
} finally {
    foreach ($uri in $testUris) {
        & $adb -s $serial shell am broadcast --receiver-include-background -n "$package/.ImageClipboardReceiver" -a "$package.DELETE_TEST" --es uri $uri | Out-Null
    }
    foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
