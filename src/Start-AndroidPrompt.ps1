[CmdletBinding()]
param([switch]$PreflightOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AndroidPrompt.Core.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'NativeWindow.cs') -ReferencedAssemblies System.Windows.Forms.dll

$config = Get-Content -Raw (Join-Path $root 'config.json') | ConvertFrom-Json
$logDirectory = Join-Path $root 'logs'
[IO.Directory]::CreateDirectory($logDirectory) | Out-Null
$log = Join-Path $logDirectory ('v9-{0:yyyyMMdd}.log' -f (Get-Date))
$tools = Join-Path $root 'tools'
$adb = Join-Path $tools 'adb.exe'
$scrcpy = Join-Path $tools 'scrcpy.exe'
$mutex = [Threading.Mutex]::new($false, 'AndroidPromptV9.Singleton')
$ownsMutex = $false
$scrcpyProcess = $null
$window = $null
$tray = $null
$previousForeground = [IntPtr]::Zero
$startupForeground = [IntPtr]::Zero
$exitRequested = $false
$restartCount = 0
$captureBusy = $false

function Log([string]$message, [string]$level = 'INFO') { Write-Host (Write-V9Log -Path $log -Message $message -Level $level) }
function AdbArgs([string[]]$args) { return @('-s', $script:device.Serial) + $args }

function Get-ControlHandle {
    if ($null -eq $script:scrcpyProcess -or $script:scrcpyProcess.HasExited) { return [IntPtr]::Zero }
    $script:scrcpyProcess.Refresh()
    return $script:scrcpyProcess.MainWindowHandle
}

function Get-WindowsFocusTarget([IntPtr]$control) {
    foreach ($candidate in @($script:previousForeground, $script:startupForeground, [AndroidPromptWindow]::GetShellWindow())) {
        if ($candidate -ne $control -and [AndroidPromptWindow]::IsUsableWindow($candidate)) { return $candidate }
    }
    return [IntPtr]::Zero
}

function Start-ControlSession {
    $arguments = @($config.scrcpyArguments)
    $workingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $windowWidth = 180; $windowHeight = 120; $windowMargin = 12
    $windowX = [Math]::Max($workingArea.Left, $workingArea.Right - $windowWidth - $windowMargin)
    $windowY = $workingArea.Top + $windowMargin + 26
    $arguments += @('--always-on-top', "--window-width=$windowWidth", "--window-height=$windowHeight", "--window-x=$windowX", "--window-y=$windowY")
    if ($device.Serial) { $arguments += @('--serial', $device.Serial) }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $scrcpy
    $psi.WorkingDirectory = $tools
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = (($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + ($value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' } else { $value }
    }) -join ' ')
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'scrcpy failed to start.' }
    Start-Sleep -Milliseconds 800; $process.Refresh()
    if ($process.HasExited) { throw "scrcpy exited during startup: $($process.StandardError.ReadToEnd())" }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100; $process.Refresh()
    }
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'scrcpy control window was not created.' }
    Log "scrcpy control session started pid=$($process.Id) serial=$($device.Serial)" 'PASS'
    return $process
}

function Enter-Android {
    try {
        if ($null -eq $script:scrcpyProcess -or $script:scrcpyProcess.HasExited) { throw 'Control session is not running.' }
        $control = Get-ControlHandle
        $before = [AndroidPromptWindow]::GetForegroundWindow()
        $trackedBefore = $script:window.IsAndroidActive
        Log "route-enter begin foreground=$before control=$control trackedAndroid=$trackedBefore"
        if ($control -eq [IntPtr]::Zero) { throw 'Control session has no window.' }
        if ($before -eq $control) {
            $script:window.SetAndroidActive($true)
            Log "route-enter result=ANDROID_FOREGROUND foreground=$before control=$control capture=UNVERIFIED reason=already-foreground" 'WARN'
            return
        }
        if ([AndroidPromptWindow]::IsUsableWindow($before)) { $script:previousForeground = $before }
        if ($trackedBefore) {
            $script:window.SetAndroidActive($false)
            Log 'route-enter reconciled stale trackedAndroid=true because control was not foreground' 'WARN'
        }
        [void](Invoke-ProcessCapture $adb (AdbArgs @('shell','input','keyevent','KEYCODE_WAKEUP')) 5000)
        if (-not [AndroidPromptWindow]::WaitForLocalInputRelease(1500)) { throw 'Release Ctrl, Alt, Shift and mouse buttons before switching.' }
        if (-not [AndroidPromptWindow]::FocusAndVerify($control, 1000)) { throw "Could not verify Android control focus; foreground=$([AndroidPromptWindow]::GetForegroundWindow()) control=$control" }
        # The prior non-control foreground guarantees scrcpy received FOCUS_LOST.
        # In scrcpy 4.1, the first mouse-up in that released state is consumed and enables capture.
        Start-Sleep -Milliseconds 100
        if (-not [AndroidPromptWindow]::CaptureScrcpyFromReleasedState($control)) { throw 'Could not request scrcpy mouse capture.' }
        $script:window.SetAndroidActive($true)
        $after = [AndroidPromptWindow]::GetForegroundWindow()
        if ($after -ne $control) { throw "Android focus was lost after capture request; foreground=$after control=$control" }
        Log "route-enter result=ANDROID_FOREGROUND foreground=$after control=$control capture=CLICK_REQUESTED_UNVERIFIABLE" 'WARN'
    } catch {
        if ($script:window) { $script:window.SetAndroidActive($false) }
        Log "route-enter result=FAIL foreground=$([AndroidPromptWindow]::GetForegroundWindow()) error=$($_.Exception.Message)" 'FAIL'
        [Console]::Beep(350,120)
    }
}

function Return-Windows {
    try {
        if (-not $script:window) { throw 'Routing window is unavailable.' }
        $control = Get-ControlHandle
        $before = [AndroidPromptWindow]::GetForegroundWindow()
        $trackedBefore = $script:window.IsAndroidActive
        Log "route-exit begin foreground=$before control=$control trackedAndroid=$trackedBefore"
        if ($control -eq [IntPtr]::Zero -or $before -ne $control) {
            $script:window.SetAndroidActive($false)
            Log "route-exit result=WINDOWS_VERIFIED foreground=$before control=$control reason=control-not-foreground" 'PASS'
            return
        }
        $target = Get-WindowsFocusTarget $control
        if ($target -eq [IntPtr]::Zero) { throw 'No valid Windows focus target is available.' }
        if (-not [AndroidPromptWindow]::WaitForLocalInputRelease(1500)) { throw 'Release Ctrl, Alt, Shift and mouse buttons before returning to Windows.' }
        if (-not [AndroidPromptWindow]::FocusAndVerify($target, 1000)) {
            throw "Could not verify Windows focus; foreground=$([AndroidPromptWindow]::GetForegroundWindow()) control=$control target=$target"
        }
        $after = [AndroidPromptWindow]::GetForegroundWindow()
        if ($after -eq $control) { throw "Control window still owns foreground after Alt+2; control=$control target=$target" }
        $script:window.SetAndroidActive($false)
        Log "route-exit result=WINDOWS_VERIFIED foreground=$after control=$control target=$target focusLostRelease=EXPECTED" 'PASS'
    } catch {
        Log "route-exit result=FAIL foreground=$([AndroidPromptWindow]::GetForegroundWindow()) error=$($_.Exception.Message)" 'FAIL'
        [Console]::Beep(350,120)
    }
}

function Capture-AndroidScreen {
    if ($script:captureBusy) { return }
    $script:captureBusy = $true
    $process = $null; $memory = $null; $source = $null; $bitmap = $null
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $adb; $psi.Arguments = "-s $($script:device.Serial) exec-out screencap -p"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
        $memory = [IO.MemoryStream]::new(); [void]$process.Start()
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or $memory.Length -eq 0) { throw "ADB screencap failed: $errorText" }
        $memory.Position = 0; $source = [Drawing.Image]::FromStream($memory); $bitmap = [Drawing.Bitmap]::new($source)
        $copied = $false
        for ($attempt = 1; $attempt -le 10 -and -not $copied; $attempt++) {
            try { [Windows.Forms.Clipboard]::SetImage($bitmap); $copied = [Windows.Forms.Clipboard]::ContainsImage() }
            catch { if ($attempt -eq 10) { throw }; Start-Sleep -Milliseconds 120 }
        }
        if (-not $copied) { throw 'Windows clipboard did not confirm the Android screenshot.' }
        Log 'Android screenshot copied to Windows clipboard' 'PASS'
    } catch { Log $_.Exception.Message 'FAIL'; [Console]::Beep(350,120) }
    finally {
        if ($bitmap) { $bitmap.Dispose() }; if ($source) { $source.Dispose() }
        if ($memory) { $memory.Dispose() }; if ($process) { $process.Dispose() }
        $script:captureBusy = $false
    }
}

try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Android Prompt v9 is already running.' }
    foreach ($path in @($adb,$scrcpy)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing runtime tool: $path. Run install.ps1 first." } }
    $devices = Get-AdbDevices $adb
    $device = Select-AdbDevice $devices ([string]$config.deviceSerial)
    Log "ADB device ready: $($device.Serial)" 'PASS'
    $ime = Get-AndroidImeState $adb $device.Serial
    if (-not $ime.FcitxInstalled) { throw 'Fcitx5 for Android is not installed.' }
    if (-not $ime.UniKeyInstalled) { throw 'Fcitx5 UniKey plugin is not installed.' }
    $fcitxSelection = Set-AndroidFcitxUniKey $adb $device.Serial
    Log "Fcitx5 + UniKey selected explicitly: subtype=$($fcitxSelection.SubtypeId)" 'PASS'
    if ($PreflightOnly) { Log 'preflight completed' 'PASS'; exit 0 }

    $startupForeground = [AndroidPromptWindow]::GetForegroundWindow()
    $scrcpyProcess = Start-ControlSession
    $window = [AndroidPromptWindow]::new()
    $window.SetControlWindowHandle($scrcpyProcess.MainWindowHandle)
    Log "startup routing observation foreground=$([AndroidPromptWindow]::GetForegroundWindow()) control=$($scrcpyProcess.MainWindowHandle) preStartForeground=$startupForeground action=NONE"
    $window.add_EnterAndroid({ Enter-Android })
    $window.add_ExitAndroid({ Return-Windows })
    $window.add_CaptureAndroid({ Capture-AndroidScreen })
    $tray = [Windows.Forms.NotifyIcon]::new()
    $tray.Icon = [Drawing.SystemIcons]::Application; $tray.Text = 'Android Prompt v9'; $tray.Visible = $true
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    [void]$menu.Items.Add('Enter Android (Alt+1)', $null, { Enter-Android })
    [void]$menu.Items.Add('Return to Windows (Alt+2)', $null, { Return-Windows })
    [void]$menu.Items.Add('Capture Android (Alt+4)', $null, { Capture-AndroidScreen })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add('Exit', $null, { $script:exitRequested = $true; [Windows.Forms.Application]::Exit() })
    $tray.ContextMenuStrip = $menu

    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 500
    $timer.add_Tick({
        if ($script:scrcpyProcess.HasExited -and -not $script:exitRequested) {
            if ($script:window.IsAndroidActive) {
                Return-Windows
                Log 'control session disconnected; Windows input restored before restart' 'WARN'
            }
            if ($config.autoRestart -and $script:restartCount -lt $config.maxRestartAttempts) {
                $script:restartCount++; Log "scrcpy stopped; restart $($script:restartCount)/$($config.maxRestartAttempts)" 'WARN'
                try {
                    $script:scrcpyProcess.Dispose(); $script:scrcpyProcess = Start-ControlSession
                    $script:window.SetControlWindowHandle($script:scrcpyProcess.MainWindowHandle)
                } catch { Log $_.Exception.Message 'FAIL' }
            } else { Log 'scrcpy stopped; restart limit reached' 'FAIL'; [Windows.Forms.Application]::Exit() }
        }
    })
    $timer.Start(); Log 'ready: Alt+1 Android, Alt+2 Windows, PrtScr Android screenshot' 'PASS'
    [Windows.Forms.Application]::Run()
} catch {
    Log $_.Exception.Message 'FAIL'
    if (-not $PreflightOnly) { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Android Prompt v9','OK','Error') | Out-Null }
    exit 1
} finally {
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($window -and $window.IsAndroidActive) { Return-Windows }
    if ($window) { $window.Dispose() }
    if ($scrcpyProcess) { try { if (-not $scrcpyProcess.HasExited) { $scrcpyProcess.Kill($true) } } catch {}; $scrcpyProcess.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    Log 'shutdown complete; Windows input ownership retained' 'PASS'
}
