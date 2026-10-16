$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$localFlutter = Join-Path $projectRoot '.tools\flutter\bin'
if (Test-Path (Join-Path $localFlutter 'flutter.bat')) {
    $env:PATH = "$localFlutter;$env:PATH"
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter SDK is required. Install Flutter or place it in .tools/flutter.'
}
$flutterInfo = flutter --version --machine | ConvertFrom-Json
if ($flutterInfo.frameworkVersion -ne '3.47.7') {
    throw 'Use Flutter 3.47.7, the version pinned for this repository.'
}
python (Join-Path $PSScriptRoot 'prepare-resources.py')
if ($LASTEXITCODE -ne 0) { throw 'Resource preparation failed.' }
$archivePath = Join-Path $projectRoot 'native\windows\pdfium-win-x64.tgz'
New-Item -ItemType Directory -Force (Split-Path $archivePath) | Out-Null
if (-not (Test-Path $archivePath)) {
    Invoke-WebRequest 'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7881/pdfium-win-x64.tgz' -OutFile $archivePath
}
$expectedHash = '73CC0DE638AC2095E7445BF56A38200A5B7C7CA0E9F4BA144598F2457377AC08'
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'PDFium archive checksum mismatch.'
}
$dllPath = Join-Path $projectRoot 'native\windows\bin\pdfium.dll'
if (-not (Test-Path -LiteralPath $dllPath)) {
    tar -xzf $archivePath -C (Split-Path $archivePath)
    if ($LASTEXITCODE -ne 0) { throw 'PDFium extraction failed.' }
}
if (-not (Get-Command flutter_rust_bridge_codegen -ErrorAction SilentlyContinue)) {
    cargo install flutter_rust_bridge_codegen --version 2.11.1 --locked
    if ($LASTEXITCODE -ne 0) { throw 'Bridge generator installation failed.' }
}
$generatorVersion = flutter_rust_bridge_codegen --version
if ($generatorVersion -notmatch '\b2\.11\.1\b') {
    throw 'Use flutter_rust_bridge_codegen 2.11.1 to match the pinned Rust and Dart runtime versions.'
}
Push-Location apps\flutter_app
try {
    # Pub resolves package metadata before attempting Windows links. Machines
    # without symlink privilege can use ordinary directory junctions instead.
    flutter pub get
    $pubExit = $LASTEXITCODE
    $pluginsFile = Join-Path (Get-Location) '.flutter-plugins-dependencies'
    if (Test-Path $pluginsFile) {
        $plugins = Get-Content -Raw -LiteralPath $pluginsFile | ConvertFrom-Json
        $links = Join-Path (Get-Location) 'windows\flutter\ephemeral\.plugin_symlinks'
        New-Item -ItemType Directory -Force $links | Out-Null
        foreach ($plugin in $plugins.plugins.windows) {
            $link = Join-Path $links $plugin.name
            if (-not (Test-Path -LiteralPath $link)) {
                New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
            }
        }
    }
    if ($pubExit -ne 0) {
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency setup failed.' }
    }
} finally { Pop-Location }
flutter_rust_bridge_codegen generate
if ($LASTEXITCODE -ne 0) { throw 'Bridge generation failed.' }
# Keep generated Rust consistent with the repository formatter.
cargo fmt --manifest-path rust/Cargo.toml --all
if ($LASTEXITCODE -ne 0) { throw 'Rust formatting failed.' }
Write-Host 'Windows dependencies are ready.'
