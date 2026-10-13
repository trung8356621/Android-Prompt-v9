$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem (Join-Path $root 'src') -Filter *.ps1 -Recurse)
$files += Get-ChildItem (Join-Path $root 'src') -Filter *.psm1 -Recurse
$files += Get-ChildItem $PSScriptRoot -Filter *.ps1 -Recurse
$errors = @()
foreach ($file in $files) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($error in $parseErrors) { $errors += "$($file.Name):$($error.Extent.StartLineNumber): $($error.Message)" }
}
if ($errors.Count) { $errors | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$references = @([Windows.Forms.Form].Assembly.Location)
Add-Type -Path (Join-Path $root 'src\NativeWindow.cs') -ReferencedAssemblies $references
Add-Type -Path (Join-Path $root 'src\ImageTransferWorker.cs') -ReferencedAssemblies @([Windows.Forms.Form].Assembly.Location,[Drawing.Image].Assembly.Location)
Write-Host "PASS: parsed $($files.Count) PowerShell files and compiled native helpers"
