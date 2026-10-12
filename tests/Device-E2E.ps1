[CmdletBinding()]
param([int]$SwitchIterations = 100, [int]$StabilityMinutes = 30)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$adb = Join-Path $root 'tools\adb.exe'
$report = Join-Path $root 'logs\device-e2e.json'
if (-not (Test-Path $adb)) { throw 'Install scrcpy runtime first.' }
$deviceLines = & $adb devices
$serials = @($deviceLines | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object { $Matches[1] })
if ($serials.Count -ne 1) { throw 'Exactly one authorized Android device is required.' }
$serial = $serials[0]

$result = [ordered]@{ started=(Get-Date).ToString('o'); serial=$serial; automated=@(); manual=@(); blocked=@() }
function Check([string]$name, [scriptblock]$action) {
    try { & $action; $result.automated += @{name=$name;status='PASS'}; Write-Host "PASS $name" }
    catch { $result.automated += @{name=$name;status='FAIL';evidence=$_.Exception.Message}; Write-Host "FAIL $name :: $($_.Exception.Message)" }
}
Check 'ADB authorized' { if ((& $adb -s $serial get-state).Trim() -ne 'device') { throw 'not device' } }
Check 'Fcitx installed' { if (-not ((& $adb -s $serial shell pm list packages org.fcitx.fcitx5.android) -match 'org.fcitx.fcitx5.android')) { throw 'missing' } }
Check 'UniKey plugin installed' { if (-not ((& $adb -s $serial shell pm list packages org.fcitx.fcitx5.android.plugin.unikey) -match 'unikey')) { throw 'missing' } }
Check 'Fcitx selected' { if (-not ((& $adb -s $serial shell settings get secure default_input_method) -match 'fcitx')) { throw 'not selected' } }
Check 'Fcitx UniKey subtype selected' {
    $dump = (& $adb -s $serial shell dumpsys input_method | Out-String)
    $match = [regex]::Match($dump, 'mSubtypeNameOverride=Unikey\b[^\r\n]*?mSubtypeId=(-?\d+)', 'IgnoreCase')
    if (-not $match.Success) { throw 'UniKey subtype is not registered' }
    $selected = (& $adb -s $serial shell settings get secure selected_input_method_subtype | Out-String).Trim()
    if ($selected -ne $match.Groups[1].Value) { throw "expected=$($match.Groups[1].Value) actual=$selected" }
}
Check 'screen capture PNG' {
    $remote='/data/local/tmp/apv9-e2e.png'; & $adb -s $serial shell screencap -p $remote | Out-Null
    $local=Join-Path $env:TEMP 'apv9-e2e.png'; & $adb -s $serial pull $remote $local | Out-Null
    try { if ((Get-Item $local).Length -lt 1024) { throw 'PNG too small' } } finally { Remove-Item $local -Force -ErrorAction SilentlyContinue; & $adb -s $serial shell rm -f $remote | Out-Null }
}

$result.manual = @(
    @{name='VNI: English/Vietnamese/tones/circumflex/specials/delete/long text';status='REQUIRES_HUMAN_OBSERVATION'},
    @{name='Enter, Shift+Enter, Ctrl+Enter in target apps';status='REQUIRES_HUMAN_OBSERVATION'},
    @{name="routing switch x$SwitchIterations; Antigravity focus; chat focus; no duplicate/stuck modifiers";status='REQUIRES_HUMAN_OBSERVATION'},
    @{name='left/right/middle click and scroll';status='REQUIRES_HUMAN_OBSERVATION'},
    @{name='Unicode clipboard both directions and no loop';status='REQUIRES_HUMAN_OBSERVATION'},
    @{name='Android PrtScr to Windows clipboard, plus normal Windows PrtScr';status='REQUIRES_HUMAN_OBSERVATION'},
    @{name='lock/unlock, USB disconnect/reconnect, helper restart, abrupt exit';status='REQUIRES_HUMAN_OBSERVATION'},
    @{name="continuous use ${StabilityMinutes} minutes";status='REQUIRES_HUMAN_OBSERVATION'}
)
$result.finished=(Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Report: $report"
if ($result.automated.status -contains 'FAIL') { exit 1 }
