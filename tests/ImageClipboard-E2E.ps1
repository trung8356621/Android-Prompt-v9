[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $root 'tools\adb.exe'
$serials = @(& $adb devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { $Matches[1] })
if ($serials.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
$serial = $serials[0]; $directory = '/sdcard/Pictures/AndroidPrompt'
$tempFiles = [Collections.Generic.List[string]]::new(); $remoteFiles = [Collections.Generic.List[string]]::new(); $mediaUris = [Collections.Generic.List[string]]::new()

function Send-TestImage([Drawing.Color]$color) {
    $name = "AndroidPrompt-test-$([guid]::NewGuid().ToString('N')).png"; $local = Join-Path $env:TEMP $name; $tempFiles.Add($local); $remote = "$directory/$name"; $remoteFiles.Add($remote)
    $bitmap = [Drawing.Bitmap]::new(64,64)
    try { $graphics = [Drawing.Graphics]::FromImage($bitmap); try { $graphics.Clear($color) } finally { $graphics.Dispose() }; $bitmap.Save($local,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    & $adb -s $serial shell mkdir -p $directory | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create direct Pictures destination.' }
    & $adb -s $serial push $local $remote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not push $name" }
    $expected = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    $actual = ((& $adb -s $serial shell sha256sum $remote | Out-String).Split(' ')[0]).Trim()
    if ($actual -ne $expected) { throw "Integrity mismatch for $name" }
    & $adb -s $serial shell content call --uri content://media --method scan_file --arg $remote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Media scan failed for $name" }
    $rows = (& $adb -s $serial shell content query --uri content://media/external/images/media --projection '_id:_display_name:relative_path:mime_type:_size' | Out-String)
    $row = ($rows -split "`r?`n" | Where-Object { $_ -match [regex]::Escape("_display_name=$name,") } | Select-Object -First 1)
    if (-not $row -or $row -notmatch 'relative_path=Pictures/AndroidPrompt/' -or $row -notmatch 'mime_type=image/png') { throw "MediaStore row is not picker-visible: $row" }
    $idMatch = [regex]::Match($row, '_id=(\d+)'); if (-not $idMatch.Success) { throw "MediaStore id missing: $row" }
    $uri = "content://media/external/images/media/$($idMatch.Groups[1].Value)"; $mediaUris.Add($uri)
    Write-Host "PASS direct image name=$name uri=$uri sha256=$expected"
    return [pscustomobject]@{ Hash=$expected; Uri=$uri; Name=$name }
}

try {
    $first = Send-TestImage ([Drawing.Color]::Red)
    $second = Send-TestImage ([Drawing.Color]::Blue)
    if ($first.Hash -eq $second.Hash -or $first.Uri -eq $second.Uri -or $first.Name -eq $second.Name) { throw 'Sequential images were not stored uniquely.' }
    Write-Host 'PASS direct transfers create unique persistent MediaStore items'
} finally {
    foreach ($remote in $remoteFiles) { & $adb -s $serial shell rm -f $remote | Out-Null }
    foreach ($uri in $mediaUris) { & $adb -s $serial shell content delete --uri $uri | Out-Null }
    foreach ($file in $tempFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
