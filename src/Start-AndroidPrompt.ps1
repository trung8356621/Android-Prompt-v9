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
$exitRequested = $false
$restartCount = 0

function Log([string]$message, [string]$level = 'INFO') { Write-Host (Write-V9Log -Path $log -Message $message -Level $level) }
function AdbArgs([string[]]$args) { return @('-s', $script:device.Serial) + $args }

function Start-ControlSession {
    $arguments = @($config.scrcpyArguments)
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
    Log "scrcpy control session started pid=$($process.Id) serial=$($device.Serial)" 'PASS'
    return $process
}

function Enter-Android {
    try {
        if ($script:window.IsAndroidActive) { Log 'routing already ANDROID; duplicate Alt+1 ignored'; return }
        if ($null -eq $script:scrcpyProcess -or $script:scrcpyProcess.HasExited) { throw 'Control session is not running.' }
        $script:previousForeground = [AndroidPromptWindow]::GetForegroundWindow()
        [void](Invoke-ProcessCapture $adb (AdbArgs @('shell','input','keyevent','KEYCODE_WAKEUP')) 5000)
        if (-not [AndroidPromptWindow]::WaitForLocalInputRelease(1500)) { throw 'Release Ctrl, Alt, Shift and mouse buttons before switching.' }
        $script:scrcpyProcess.Refresh()
        if (-not [AndroidPromptWindow]::Focus($script:scrcpyProcess.MainWindowHandle)) { throw 'Windows refused to focus the control window.' }
        [AndroidPromptWindow]::ToggleScrcpyCapture()
        $script:window.SetAndroidActive($true)
        Log 'routing=ANDROID; Alt+2 returns to the previous Windows app' 'PASS'
    } catch { Log $_.Exception.Message 'FAIL'; [Console]::Beep(350,120) }
}

function Return-Windows {
    try {
        if (-not $script:window -or -not $script:window.IsAndroidActive) { Log 'routing already WINDOWS; duplicate Alt+2 ignored'; return }
        if ($script:scrcpyProcess -and -not $script:scrcpyProcess.HasExited) {
            $script:scrcpyProcess.Refresh()
            if ([AndroidPromptWindow]::Focus($script:scrcpyProcess.MainWindowHandle)) {
                [AndroidPromptWindow]::ToggleScrcpyCapture()
            }
        }
        $script:window.SetAndroidActive($false)
        if ($script:previousForeground -ne [IntPtr]::Zero) {
            [void][AndroidPromptWindow]::Focus($script:previousForeground)
        }
        Log 'routing=WINDOWS via Alt+2' 'PASS'
    } catch { Log $_.Exception.Message 'WARN' }
}

function Capture-AndroidScreen {
    try {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ("android-prompt-v9-capture-{0}.png" -f [guid]::NewGuid().ToString('N'))
        try {
            # Use adb pull through a temporary Android file; stdout capture is text-oriented.
            $remote = '/data/local/tmp/android-prompt-v9.png'
            $shot = Invoke-ProcessCapture $adb (AdbArgs @('shell','screencap','-p',$remote))
            if ($shot.ExitCode -ne 0) { throw $shot.StdErr }
            $pull = Invoke-ProcessCapture $adb (AdbArgs @('pull',$remote,$temp)) 30000
            [void](Invoke-ProcessCapture $adb (AdbArgs @('shell','rm','-f',$remote)))
            if ($pull.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $temp)) { throw $pull.StdErr }
            $bitmap = [Drawing.Bitmap]::FromFile($temp)
            try {
                $clipboardCopy = [Drawing.Bitmap]::new($bitmap)
                try {
                    $copied = $false
                    for ($attempt = 1; $attempt -le 10 -and -not $copied; $attempt++) {
                        try {
                            [Windows.Forms.Clipboard]::SetImage($clipboardCopy)
                            $copied = [Windows.Forms.Clipboard]::ContainsImage()
                        } catch { if ($attempt -eq 10) { throw }; Start-Sleep -Milliseconds 120 }
                    }
                    if (-not $copied) { throw 'Windows clipboard did not confirm the Android screenshot.' }
                } finally { $clipboardCopy.Dispose() }
            } finally { $bitmap.Dispose() }
            Log 'Android screenshot copied to Windows clipboard' 'PASS'
        } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    } catch { Log $_.Exception.Message 'FAIL'; [Console]::Beep(350,120) }
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

    $scrcpyProcess = Start-ControlSession
    $window = [AndroidPromptWindow]::new()
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
                try { $script:scrcpyProcess.Dispose(); $script:scrcpyProcess = Start-ControlSession } catch { Log $_.Exception.Message 'FAIL' }
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
    if ($window) { $window.Dispose() }
    if ($scrcpyProcess) { try { if (-not $scrcpyProcess.HasExited) { $scrcpyProcess.Kill($true) } } catch {}; $scrcpyProcess.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    Log 'shutdown complete; Windows input ownership retained' 'PASS'
}
