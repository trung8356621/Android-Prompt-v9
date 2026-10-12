$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Static.Tests.ps1')
& (Join-Path $PSScriptRoot 'Unit.Tests.ps1')
Write-Host 'PASS: host test suite'
