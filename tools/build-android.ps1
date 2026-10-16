param([switch]$GenerateBridge)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$flutterBin = Join-Path $projectRoot '.tools\flutter\bin'
if (Test-Path $flutterBin) { $env:PATH = "$flutterBin;$env:PATH" }
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = Join-Path $projectRoot '.tools\android-sdk' }
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
if (-not $env:JAVA_HOME) {
    $jdk = Get-ChildItem (Join-Path $projectRoot '.tools\java') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $jdk) { throw 'Install JDK 21 or configure JAVA_HOME.' }
    $env:JAVA_HOME = $jdk.FullName
}
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
python (Join-Path $PSScriptRoot 'prepare-resources.py')
if ($LASTEXITCODE -ne 0) { throw 'Resource preparation failed.' }
$ndkRoot = Join-Path $env:ANDROID_HOME 'ndk\28.2.13676358'
$nativeTools = Join-Path $ndkRoot 'toolchains\llvm\prebuilt\windows-x86_64\bin'
if (-not (Test-Path $nativeTools)) { throw 'Android NDK 28.2.13676358 is required.' }
$archive = Join-Path $projectRoot 'native\android\pdfium-android-arm64.tgz'
if (-not (Test-Path $archive)) {
    New-Item -ItemType Directory -Force (Split-Path $archive) | Out-Null
    Invoke-WebRequest 'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7881/pdfium-android-arm64.tgz' -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne '16D23BB86C4188D59326DC509938F59DF3C417ECFDD3D2CA2F160DC5BD49A839') { throw 'Android PDFium checksum mismatch.' }
if (-not (Test-Path native\android\lib\libpdfium.so)) {
    tar -xzf $archive -C (Split-Path $archive)
    if ($LASTEXITCODE -ne 0) { throw 'PDFium extraction failed.' }
}
if ($GenerateBridge) {
    flutter_rust_bridge_codegen generate
    if ($LASTEXITCODE -ne 0) { throw 'Bridge generation failed.' }
    cargo fmt --manifest-path rust/Cargo.toml --all
    if ($LASTEXITCODE -ne 0) { throw 'Generated code formatting failed.' }
}
rustup target add aarch64-linux-android
if ($LASTEXITCODE -ne 0) { throw 'Android Rust target setup failed.' }
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS = '-C link-arg=-Wl,-z,max-page-size=16384'
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = Join-Path $nativeTools 'aarch64-linux-android24-clang.cmd'
$env:CC_aarch64_linux_android = $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
$env:AR_aarch64_linux_android = Join-Path $nativeTools 'llvm-ar.exe'
cargo build --manifest-path rust/Cargo.toml --package app-api --release --target aarch64-linux-android --locked
if ($LASTEXITCODE -ne 0) { throw 'Android Rust build failed.' }
$jni = Join-Path $projectRoot 'apps\flutter_app\android\app\src\main\jniLibs\arm64-v8a'
New-Item -ItemType Directory -Force $jni | Out-Null
Copy-Item rust\target\aarch64-linux-android\release\libapp_api.so $jni -Force
Copy-Item native\android\lib\libpdfium.so $jni -Force
$licenses = Join-Path $projectRoot 'apps\flutter_app\android\app\src\main\assets\licenses\pdfium'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item native\android\licenses\* $licenses -Recurse -Force
Copy-Item native\android\LICENSE $licenses -Force
if ($env:HTTP_PROXY) {
    $proxy = [Uri]$env:HTTP_PROXY
    $env:GRADLE_OPTS = "$env:GRADLE_OPTS -Dhttp.proxyHost=$($proxy.Host) -Dhttp.proxyPort=$($proxy.Port) -Dhttps.proxyHost=$($proxy.Host) -Dhttps.proxyPort=$($proxy.Port)"
}
Set-Location apps\flutter_app
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency setup failed.' }
flutter build apk --release --target-platform android-arm64 --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Android APK build failed.' }
python (Join-Path $PSScriptRoot 'verify-android.py') 'build/app/outputs/flutter-apk/app-release.apk'
if ($LASTEXITCODE -ne 0) { throw 'Android native resource verification failed.' }
Write-Host 'Built apps/flutter_app/build/app/outputs/flutter-apk/app-release.apk (development signing).'
