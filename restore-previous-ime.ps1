$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$adb = Join-Path $root 'tools\adb.exe'
$state = Join-Path $root 'logs\previous-ime.txt'
if (-not (Test-Path -LiteralPath $state)) { throw 'No saved previous IME state was found.' }
$previous = (Get-Content -Raw -LiteralPath $state).Trim()
if (-not $previous) { throw 'Saved previous IME is empty.' }
$devices = @(& $adb devices | Where-Object { $_ -match '^(\S+)\s+device$' } | ForEach-Object { $Matches[1] })
if ($devices.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
& $adb -s $devices[0] shell ime enable $previous
if ($LASTEXITCODE -ne 0) { throw 'Could not enable the previous IME.' }
& $adb -s $devices[0] shell ime set $previous
if ($LASTEXITCODE -ne 0) { throw 'Could not restore the previous IME.' }
$actual = (& $adb -s $devices[0] shell settings get secure default_input_method | Out-String).Trim()
if ($actual -ne $previous) { throw "Restore verification failed: expected=$previous actual=$actual" }
Write-Host "PASS: restored $previous"
