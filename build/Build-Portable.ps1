[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$distRoot = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist' }
$packageName = 'Android-Prompt-v9-Portable'
$package = Join-Path $distRoot $packageName
$zip = Join-Path $distRoot ($packageName + '.zip')
$icon = Join-Path $root 'assets\AndroidPrompt.ico'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $csc)) { throw "Missing .NET Framework x64 C# compiler: $csc" }
$requiredTools = @('scrcpy.exe','scrcpy-server','adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll','SDL3.dll','avcodec-62.dll','avformat-62.dll','avutil-60.dll','swresample-6.dll','libusb-1.0.dll')
foreach ($name in $requiredTools) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "tools\$name"))) { throw "Missing runtime dependency: tools\$name" }
}

Add-Type -AssemblyName System.Drawing
function New-AndroidPromptIcon([string]$Path) {
    $sizes = @(16,24,32,48,64,128,256)
    $images = [Collections.Generic.List[byte[]]]::new()
    foreach ($size in $sizes) {
        $bitmap = [Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $scale = $size / 256.0
            $graphics.Clear([Drawing.Color]::FromArgb(16,24,39))
            $cyan = [Drawing.Pen]::new([Drawing.Color]::FromArgb(34,211,238),[Math]::Max(1,12*$scale))
            $blue = [Drawing.Pen]::new([Drawing.Color]::FromArgb(96,165,250),[Math]::Max(1,10*$scale))
            $key = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(219,234,254))
            $panel = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(23,36,58))
            try {
                $graphics.FillRectangle($panel,30*$scale,105*$scale,149*$scale,103*$scale)
                $graphics.DrawRectangle($blue,35*$scale,110*$scale,139*$scale,93*$scale)
                $graphics.DrawRectangle($cyan,145*$scale,41*$scale,58*$scale,118*$scale)
                foreach ($y in @(127,151)) { foreach ($x in @(49,75,101,127)) { $graphics.FillRectangle($key,$x*$scale,$y*$scale,17*$scale,14*$scale) } }
                $graphics.FillRectangle($key,62*$scale,176*$scale,70*$scale,13*$scale)
                $graphics.DrawLine($cyan,105*$scale,87*$scale,150*$scale,87*$scale)
                $graphics.DrawLine($cyan,150*$scale,87*$scale,136*$scale,74*$scale)
                $graphics.DrawLine($cyan,150*$scale,87*$scale,136*$scale,100*$scale)
            } finally { $cyan.Dispose(); $blue.Dispose(); $key.Dispose(); $panel.Dispose() }
            $memory = [IO.MemoryStream]::new(); $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png); $images.Add($memory.ToArray()); $memory.Dispose()
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
    $parent = Split-Path $Path -Parent; [IO.Directory]::CreateDirectory($parent) | Out-Null
    $file = [IO.File]::Create($Path); $writer = [IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($i=0; $i -lt $sizes.Count; $i++) {
            $s=$sizes[$i]; $writer.Write([byte]$(if($s -eq 256){0}else{$s})); $writer.Write([byte]$(if($s -eq 256){0}else{$s}))
            $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset); $offset += $images[$i].Length
        }
        foreach ($bytes in $images) { $writer.Write($bytes) }
    } finally { $writer.Dispose(); $file.Dispose() }
}

New-AndroidPromptIcon $icon

$resolvedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$resolvedPackage = [IO.Path]::GetFullPath($package)
if (-not $resolvedPackage.StartsWith($resolvedRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe output path.' }
if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Recurse -Force }
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
[IO.Directory]::CreateDirectory($package) | Out-Null

foreach ($directory in @('src','tools','assets','android-helper\dist','licenses')) { [IO.Directory]::CreateDirectory((Join-Path $package $directory)) | Out-Null }
Copy-Item -Path (Join-Path $root 'src\*') -Destination (Join-Path $package 'src') -Recurse -Force
Copy-Item -Path (Join-Path $root 'tools\*') -Destination (Join-Path $package 'tools') -Force
Copy-Item -LiteralPath (Join-Path $root 'assets\icon.svg'),$icon -Destination (Join-Path $package 'assets') -Force
Copy-Item -LiteralPath (Join-Path $root 'android-helper\dist\AndroidPromptClipboard-debug.apk') -Destination (Join-Path $package 'android-helper\dist') -Force
Copy-Item -LiteralPath (Join-Path $root 'config.json'),(Join-Path $root 'README.md'),(Join-Path $root 'PORTABLE-BUILD-REPORT.md'),(Join-Path $root 'THIRD-PARTY-NOTICES.md'),(Join-Path $root 'install-clipboard-helper.ps1') -Destination $package -Force
Copy-Item -LiteralPath (Join-Path $root 'licenses\README.md') -Destination (Join-Path $package 'licenses') -Force

$exe = Join-Path $package 'AndroidPrompt.exe'
& $csc /nologo /target:winexe /platform:x64 /optimize+ "/win32icon:$icon" "/out:$exe" /reference:System.dll /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'AndroidPrompt.Launcher.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw 'AndroidPrompt.exe compilation failed.' }
[GC]::Collect(); [GC]::WaitForPendingFinalizers()
$archiveError = $null
for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -LiteralPath $package -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
        $archiveError = $null; break
    } catch {
        $archiveError = $_
        Start-Sleep -Milliseconds 500
    }
}
if ($archiveError) { throw $archiveError }
Write-Host "PASS package=$package"
Write-Host "PASS zip=$zip bytes=$((Get-Item -LiteralPath $zip).Length)"
