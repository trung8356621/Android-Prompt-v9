[CmdletBinding()]
param([switch]$PreflightOnly, [int]$SmokeTestSeconds = 0)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AndroidPrompt.Core.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'NativeWindow.cs') -ReferencedAssemblies System.Windows.Forms.dll
Add-Type -Path (Join-Path $PSScriptRoot 'HeadlessInputBridge.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'ImageTransferWorker.cs') -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll

$config = Get-Content -Raw (Join-Path $root 'config.json') | ConvertFrom-Json
$logDirectory = Join-Path $root 'logs'
[IO.Directory]::CreateDirectory($logDirectory) | Out-Null
$log = Join-Path $logDirectory ('v9-{0:yyyyMMdd}.log' -f (Get-Date))
$tools = Join-Path $root 'tools'
$adb = Join-Path $tools 'adb.exe'
$scrcpyServer = Join-Path $tools 'scrcpy-server'
$scrcpy = Join-Path $tools 'scrcpy.exe'
$mutex = [Threading.Mutex]::new($false, 'AndroidPromptV9.Singleton')
$ownsMutex = $false
$inputBridge = $null
$clipboardProcess = $null
$window = $null
$tray = $null
$appIcon = $null
$exitRequested = $false
$restartCount = 0
$captureBusy = $false
$imageTransfer = $null

function Log([string]$message, [string]$level = 'INFO') { try { [void](Write-V9Log -Path $log -Message $message -Level $level) } catch {} }
function AdbArgs([string[]]$args) { return @('-s', $script:device.Serial) + $args }

function Start-ControlSession {
    $bridge = [HeadlessInputBridge]::new($adb, $device.Serial, $scrcpyServer, $window.Handle)
    Log "headless scrcpy-server control session started serial=$($device.Serial) state=$($bridge.State)" 'PASS'
    return $bridge
}

function Start-ClipboardSession {
    $arguments = @('--no-window','--no-video','--no-audio','--keyboard=disabled','--mouse=disabled','--no-power-on')
    if ($device.Serial) { $arguments += @('--serial', $device.Serial) }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $scrcpy; $psi.WorkingDirectory = $tools
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true; $psi.Arguments = $arguments -join ' '
    $process = [Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) { throw "Headless clipboard session failed: $($process.StandardError.ReadToEnd())" }
    Log "headless text clipboard session started pid=$($process.Id)" 'PASS'
    return $process
}

function Enter-Android {
    try {
        if ($null -eq $script:inputBridge -or -not $script:inputBridge.IsConnected) { throw 'Headless control session is not connected.' }
        Log "route-enter begin state=$($script:inputBridge.State)"
        [void](Invoke-ProcessCapture $adb (AdbArgs @('shell','input','keyevent','KEYCODE_WAKEUP')) 5000)
        if (-not $script:inputBridge.EnterAndroid()) { throw "Could not enter Android routing state: $($script:inputBridge.State)" }
        $script:window.SetAndroidActive($true)
        Log 'route-enter result=ANDROID state=ANDROID transport=HEADLESS_UHID' 'PASS'
    } catch {
        if ($script:window) { $script:window.SetAndroidActive($false) }
        Log "route-enter result=FAIL error=$($_.Exception.Message)" 'FAIL'
        [Console]::Beep(350,120)
    }
}

function Return-Windows {
    try {
        if (-not $script:window) { throw 'Routing window is unavailable.' }
        Log "route-exit begin state=$($script:inputBridge.State)"
        $script:inputBridge.ReturnWindows()
        $script:window.SetAndroidActive($false)
        Log "route-exit result=WINDOWS state=$($script:inputBridge.State)" 'PASS'
    } catch {
        Log "route-exit result=FAIL error=$($_.Exception.Message)" 'FAIL'
        [Console]::Beep(350,120)
    }
}

function Send-WindowsImageToAndroid {
    if (-not $script:imageTransfer.TryStart()) { Log 'image-transfer ignored because another Alt+3 transfer is active' 'WARN' }
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
    foreach ($path in @($adb,$scrcpy,$scrcpyServer)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing runtime tool: $path. Run install.ps1 first." } }
    $devices = Get-AdbDevices $adb
    $device = Select-AdbDevice $devices ([string]$config.deviceSerial)
    Log "ADB device ready: $($device.Serial)" 'PASS'
    $ime = Get-AndroidImeState $adb $device.Serial
    if (-not $ime.FcitxInstalled) { throw 'Fcitx5 for Android is not installed.' }
    if (-not $ime.UniKeyInstalled) { throw 'Fcitx5 UniKey plugin is not installed.' }
    $fcitxSelection = Set-AndroidFcitxUniKey $adb $device.Serial
    Log "Fcitx5 + UniKey selected explicitly: subtype=$($fcitxSelection.SubtypeId)" 'PASS'
    if ($PreflightOnly) { Log 'preflight completed' 'PASS'; exit 0 }
    $imageTransfer = [ImageTransferWorker]::new($adb, $device.Serial, $log)

    $window = [AndroidPromptWindow]::new()
    $window.add_EnterAndroid({ Enter-Android })
    $window.add_ExitAndroid({ Return-Windows })
    $window.add_SendImage({ Send-WindowsImageToAndroid })
    $window.add_CaptureAndroid({ Capture-AndroidScreen })
    $inputBridge = Start-ControlSession
    $clipboardProcess = Start-ClipboardSession
    $inputBridge.add_EmergencyReturn({ $script:window.RequestReturnWindows() })
    $inputBridge.add_CaptureAndroid({ $script:window.RequestCaptureAndroid() })
    $inputBridge.add_Disconnected({ $script:window.RequestReturnWindows() })
    $window.add_RawInput({ param($rawHandle) $script:inputBridge.ProcessRawInput($rawHandle) })
    $tray = [Windows.Forms.NotifyIcon]::new()
    $iconPath = Join-Path $root 'assets\AndroidPrompt.ico'
    if (-not (Test-Path -LiteralPath $iconPath)) { throw "Missing application icon: $iconPath" }
    $appIcon = [Drawing.Icon]::new($iconPath, 16, 16)
    $tray.Icon = $appIcon; $tray.Text = 'Android Prompt v9'; $tray.Visible = $true
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    [void]$menu.Items.Add('Enter Android (Alt+1)', $null, { Enter-Android })
    [void]$menu.Items.Add('Return to Windows (Alt+2)', $null, { Return-Windows })
    [void]$menu.Items.Add('Send clipboard image to Android (Alt+3)', $null, { Send-WindowsImageToAndroid })
    [void]$menu.Items.Add('Capture Android (Alt+4)', $null, { Capture-AndroidScreen })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add('Exit', $null, { $script:exitRequested = $true; [Windows.Forms.Application]::Exit() })
    $tray.ContextMenuStrip = $menu

    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 500
    $smokeDeadline = if ($SmokeTestSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($SmokeTestSeconds) } else { [DateTime]::MaxValue }
    $timer.add_Tick({
        if ([DateTime]::UtcNow -ge $script:smokeDeadline) { $script:exitRequested = $true; [Windows.Forms.Application]::Exit(); return }
        if (-not $script:inputBridge.IsConnected -and -not $script:exitRequested) {
            if ($script:window.IsAndroidActive) {
                Return-Windows
                Log 'control session disconnected; Windows input restored before restart' 'WARN'
            }
            if ($config.autoRestart -and $script:restartCount -lt $config.maxRestartAttempts) {
                $script:restartCount++; Log "scrcpy stopped; restart $($script:restartCount)/$($config.maxRestartAttempts)" 'WARN'
                try {
                    $script:inputBridge.Dispose(); $script:inputBridge = Start-ControlSession
                    $script:inputBridge.add_EmergencyReturn({ $script:window.RequestReturnWindows() })
                    $script:inputBridge.add_CaptureAndroid({ $script:window.RequestCaptureAndroid() })
                    $script:inputBridge.add_Disconnected({ $script:window.RequestReturnWindows() })
                } catch { Log $_.Exception.Message 'FAIL' }
            } else { Log 'scrcpy stopped; restart limit reached' 'FAIL'; [Windows.Forms.Application]::Exit() }
        }
    })
    $timer.Start(); Log 'ready headless: Alt+1 Android, RightAlt/Alt+2 Windows, PrtScr Android screenshot' 'PASS'
    [Windows.Forms.Application]::Run()
} catch {
    Log $_.Exception.Message 'FAIL'
    if (-not $PreflightOnly) { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Android Prompt v9','OK','Error') | Out-Null }
    exit 1
} finally {
    if ($imageTransfer) { $imageTransfer.Dispose() }
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($appIcon) { $appIcon.Dispose() }
    if ($window -and $window.IsAndroidActive) { Return-Windows }
    if ($window) { $window.Dispose() }
    if ($inputBridge) { $inputBridge.Dispose() }
    if ($clipboardProcess) { try { if (-not $clipboardProcess.HasExited) { $clipboardProcess.Kill(); $clipboardProcess.WaitForExit(3000) } } catch {}; $clipboardProcess.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    Log 'shutdown complete; Windows input ownership retained' 'PASS'
}
