Set-StrictMode -Version Latest

function Write-V9Log {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','PASS','WARN','FAIL')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    return $line
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 15000
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = (($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' } else { $_ }
    }) -join ' ')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "Could not start $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill($true) } catch {}
            throw "Process timeout after ${TimeoutMs}ms: $FilePath"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

function Get-AdbDevices {
    param([Parameter(Mandatory)][string]$AdbPath)
    $result = Invoke-ProcessCapture -FilePath $AdbPath -Arguments @('devices','-l')
    if ($result.ExitCode -ne 0) { throw "adb devices failed: $($result.StdErr.Trim())" }
    $devices = @()
    foreach ($line in ($result.StdOut -split "`r?`n" | Select-Object -Skip 1)) {
        if ($line -match '^(\S+)\s+(device|offline|unauthorized)(?:\s+(.*))?$') {
            $devices += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2]; Details = $Matches[3] }
        }
    }
    return @($devices)
}

function Select-AdbDevice {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Devices, [string]$RequestedSerial)
    $Devices = @($Devices)
    if ($RequestedSerial) {
        $match = @($Devices | Where-Object Serial -eq $RequestedSerial)
        if ($match.Count -ne 1) { throw "Configured Android device not found: $RequestedSerial" }
        if ($match[0].State -ne 'device') { throw "Android device $RequestedSerial is $($match[0].State)" }
        return $match[0]
    }
    $ready = @($Devices | Where-Object State -eq 'device')
    if ($ready.Count -eq 0) { throw 'No authorized Android device detected.' }
    if ($ready.Count -gt 1) { throw 'Multiple Android devices detected; set deviceSerial in config.json.' }
    return $ready[0]
}

function Get-AndroidImeState {
    param([Parameter(Mandatory)][string]$AdbPath, [Parameter(Mandatory)][string]$Serial)
    $current = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','settings','get','secure','default_input_method')
    $installed = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','pm','list','packages','org.fcitx.fcitx5.android')
    $plugin = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','pm','list','packages','org.fcitx.fcitx5.android.plugin.unikey')
    return [pscustomobject]@{
        Current = $current.StdOut.Trim()
        FcitxInstalled = $installed.StdOut -match 'org\.fcitx\.fcitx5\.android'
        UniKeyInstalled = $plugin.StdOut -match 'org\.fcitx\.fcitx5\.android\.plugin\.unikey'
        IsFcitxSelected = $current.StdOut -match 'org\.fcitx\.fcitx5\.android'
    }
}

function Get-FcitxUniKeySubtypeIdFromDump {
    param([Parameter(Mandatory)][string]$Dump)
    $match = [regex]::Match(
        $Dump,
        'mSubtypeNameOverride=Unikey\b[^\r\n]*?mSubtypeId=(-?\d+)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) { throw 'Fcitx UniKey subtype is not registered in Android InputMethodManager.' }
    return [int]$match.Groups[1].Value
}

function Set-AndroidFcitxUniKey {
    param([Parameter(Mandatory)][string]$AdbPath, [Parameter(Mandatory)][string]$Serial)
    $component = 'org.fcitx.fcitx5.android/.input.FcitxInputMethodService'
    $dump = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','dumpsys','input_method')
    if ($dump.ExitCode -ne 0) { throw "Could not inspect Android input methods: $($dump.StdErr.Trim())" }
    $subtypeId = Get-FcitxUniKeySubtypeIdFromDump $dump.StdOut

    $enable = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','ime','enable',$component)
    if ($enable.ExitCode -ne 0) { throw "Could not enable Fcitx5: $($enable.StdErr.Trim())" }
    $selectIme = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','ime','set',$component)
    if ($selectIme.ExitCode -ne 0) { throw "Could not select Fcitx5: $($selectIme.StdErr.Trim())" }
    # Android 15 may choose Fcitx's last-used subtype during `ime set`, so write UniKey after it.
    $selectSubtype = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','settings','put','secure','selected_input_method_subtype',([string]$subtypeId))
    if ($selectSubtype.ExitCode -ne 0) { throw "Could not select Fcitx UniKey subtype: $($selectSubtype.StdErr.Trim())" }

    $actualIme = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','settings','get','secure','default_input_method')
    $actualSubtype = Invoke-ProcessCapture $AdbPath @('-s',$Serial,'shell','settings','get','secure','selected_input_method_subtype')
    if ($actualIme.StdOut.Trim() -ne $component) { throw "Fcitx5 selection was not retained: $($actualIme.StdOut.Trim())" }
    if ($actualSubtype.StdOut.Trim() -ne [string]$subtypeId) { throw "UniKey subtype selection was not retained: expected=$subtypeId actual=$($actualSubtype.StdOut.Trim())" }
    return [pscustomobject]@{ Component = $component; SubtypeId = $subtypeId }
}

function Get-SafeImageExtension {
    param([Parameter(Mandatory)][string]$RawFormat)
    switch -Regex ($RawFormat.ToLowerInvariant()) {
        'jpeg|jpg' { return '.jpg' }
        default { return '.png' }
    }
}

Export-ModuleMember -Function Write-V9Log,Invoke-ProcessCapture,Get-AdbDevices,Select-AdbDevice,Get-AndroidImeState,Get-FcitxUniKeySubtypeIdFromDump,Set-AndroidFcitxUniKey,Get-SafeImageExtension
