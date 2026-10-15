param([switch]$Run)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'setup-windows.ps1')
Set-Location -LiteralPath (Join-Path $projectRoot 'apps\flutter_app')
flutter build windows --release --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
$executablePath = Join-Path (Get-Location) 'build\windows\x64\runner\Release\Folinq.exe'
Write-Host "Built: $executablePath"
if ($Run) { Start-Process -FilePath $executablePath -WindowStyle Hidden }
