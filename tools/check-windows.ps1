param([switch]$Prepare, [switch]$LocalUiTests)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
if ($Prepare) { & (Join-Path $PSScriptRoot 'setup-windows.ps1') }
$localFlutter = Join-Path $projectRoot '.tools\flutter\bin'
if (Test-Path (Join-Path $localFlutter 'flutter.bat')) { $env:PATH = "$localFlutter;$env:PATH" }
cargo fmt --manifest-path rust/Cargo.toml --all -- --check
if ($LASTEXITCODE -ne 0) { throw 'Rust format check failed.' }
cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets --locked -- -D warnings
if ($LASTEXITCODE -ne 0) { throw 'Rust analysis failed.' }
cargo test --manifest-path rust/Cargo.toml --workspace --locked
if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed.' }
Push-Location apps/flutter_app
try {
    flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
    if ($LocalUiTests) {
        cargo build --manifest-path ../../rust/Cargo.toml -p app-api --locked
        if ($LASTEXITCODE -ne 0) { throw 'Native test library build failed.' }
        $fixture = Join-Path $projectRoot 'tests\pdf-fixtures\native-text.pdf'
        if (-not (Test-Path -LiteralPath $fixture)) {
            New-Item -ItemType Directory -Force (Split-Path $fixture) | Out-Null
            cargo run --manifest-path ../../rust/Cargo.toml -p app-api --bin pdf-editor --locked -- fixture $fixture
            if ($LASTEXITCODE -ne 0) { throw 'Fixture generation failed.' }
        }
        flutter test --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
    }
} finally { Pop-Location }
