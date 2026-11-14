<#
.SYNOPSIS
  Builds PayPal-RASP-Guard (an LSPosed/Xposed module) without Gradle.

.DESCRIPTION
  Toolchain: JDK (javac/keytool) + Android SDK build-tools (aapt2/d8/zipalign/apksigner).
  Locations are auto-detected; override with -JdkHome / -SdkRoot if needed.

.PARAMETER Install
  After a successful build, `adb install -r` the result to the connected device.

.PARAMETER JdkHome
  Path to a JDK. Defaults to $env:JAVA_HOME, then Android Studio's bundled JBR, then PATH.

.PARAMETER SdkRoot
  Android SDK root. Defaults to $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT,
  then %LOCALAPPDATA%\Android\Sdk.

.EXAMPLE
  .\build.ps1

.EXAMPLE
  .\build.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [string]$JdkHome,
    [string]$SdkRoot
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$app = Join-Path $root 'app'
$build = Join-Path $root 'build'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- toolchain ---
if (-not $JdkHome) {
    $candidates = @(
        $env:JAVA_HOME,
        (Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'),
        'C:\Program Files\Android\Android Studio\jbr',
        'C:\Program Files\Java'
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\javac.exe')) }
    if ($candidates) { $JdkHome = $candidates[0] }
    elseif (Get-Command javac -ErrorAction SilentlyContinue) { $JdkHome = Split-Path (Split-Path (Get-Command javac).Source) }
}
if (-not $JdkHome -or -not (Test-Path (Join-Path $JdkHome 'bin\javac.exe'))) {
    Fail "JDK not found. Pass -JdkHome <path to JDK> (needs bin\javac.exe)."
}
$javac = Join-Path $JdkHome 'bin\javac.exe'
$keytool = Join-Path $JdkHome 'bin\keytool.exe'

if (-not $SdkRoot) {
    $SdkRoot = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $SdkRoot -or -not (Test-Path $SdkRoot)) { Fail "Android SDK not found. Pass -SdkRoot <path>." }

$buildTools = Get-ChildItem (Join-Path $SdkRoot 'build-tools') -Directory -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.Name -replace '[^\d\.].*$','') } -Descending | Select-Object -First 1
if (-not $buildTools) { Fail "No build-tools found under $SdkRoot\build-tools" }
$aapt2 = Join-Path $buildTools.FullName 'aapt2.exe'
$d8 = Join-Path $buildTools.FullName 'd8.bat'
$zipalign = Join-Path $buildTools.FullName 'zipalign.exe'
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'

$platform = Get-ChildItem (Join-Path $SdkRoot 'platforms') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'android.jar') } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $platform) { Fail "No platforms/android-*/android.jar found under $SdkRoot\platforms" }
$androidJar = Join-Path $platform.FullName 'android.jar'

Write-Host "JDK        : $JdkHome"
Write-Host "SDK        : $SdkRoot"
Write-Host "build-tools: $($buildTools.Name)"
Write-Host "android.jar: $androidJar"

# -------------------------------------------------------------------- clean ---
Step 'cleaning'
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in @('classes', 'stub-classes', 'dex')) { New-Item -ItemType Directory -Force -Path (Join-Path $build $d) | Out-Null }

# ------------------------------------------------------------- compile java ---
Step 'compiling stubs (Xposed API surface)'
$stubSrc = @(Get-ChildItem (Join-Path $root 'stubs') -Recurse -Filter *.java | Select-Object -ExpandProperty FullName)
& $javac --release 11 -nowarn -d (Join-Path $build 'stub-classes') @stubSrc
if ($LASTEXITCODE -ne 0) { Fail 'stub compilation failed' }

Step 'compiling module source'
$srcFiles = @(Get-ChildItem (Join-Path $app 'src') -Recurse -Filter *.java | Select-Object -ExpandProperty FullName)
$stubOut = Join-Path $build 'stub-classes'
& $javac --release 11 -nowarn -cp "$androidJar;$stubOut" -d (Join-Path $build 'classes') @srcFiles
if ($LASTEXITCODE -ne 0) { Fail 'module compilation failed' }

# ------------------------------------------------------------------- dexing ---
# 只把模块自身的类打进 dex；de.robv.* 由 LSPosed 在运行时提供，绝不能打包。
Step 'dexing (module classes only)'
$appClasses = @(Get-ChildItem (Join-Path $build 'classes') -Recurse -Filter *.class | Select-Object -ExpandProperty FullName)
& $d8 --release --min-api 26 --lib $androidJar --output (Join-Path $build 'dex') @appClasses
if ($LASTEXITCODE -ne 0) { Fail 'd8 failed' }

# ----------------------------------------------------------------- packaging ---
Step 'packaging resources'
$resZip = Join-Path $build 'res.zip'
& $aapt2 compile --dir (Join-Path $app 'res') -o $resZip
if ($LASTEXITCODE -ne 0) { Fail 'aapt2 compile failed' }

$unsigned = Join-Path $build 'unsigned.apk'
& $aapt2 link -o $unsigned -I $androidJar --manifest (Join-Path $app 'AndroidManifest.xml') `
    --min-sdk-version 26 --target-sdk-version 34 -A (Join-Path $app 'assets') $resZip
if ($LASTEXITCODE -ne 0) { Fail 'aapt2 link failed' }

Step 'adding classes.dex'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($unsigned, 'Update')
try {
    $entry = $zip.CreateEntry('classes.dex')
    $s = $entry.Open()
    $bytes = [IO.File]::ReadAllBytes((Join-Path $build 'dex\classes.dex'))
    $s.Write($bytes, 0, $bytes.Length)
    $s.Close()
} finally { $zip.Dispose() }

# ------------------------------------------------------------------- signing ---
Step 'aligning and signing'
$aligned = Join-Path $build 'aligned.apk'
& $zipalign -f 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { Fail 'zipalign failed' }

$keystore = Join-Path $root 'keystore\debug.keystore'
if (-not (Test-Path $keystore)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $keystore) | Out-Null
    & $keytool -genkeypair -keystore $keystore -alias raspguard -keyalg RSA -keysize 2048 `
        -validity 3650 -storepass android -keypass android -dname "CN=PayPal RASP Guard, O=dsh, C=CN" | Out-Null
}

$version = ([xml](Get-Content (Join-Path $app 'AndroidManifest.xml'))).manifest.versionName
$out = Join-Path $build "PayPal-RASP-Guard-$version.apk"
& $apksigner sign --ks $keystore --ks-pass pass:android --key-pass pass:android --out $out $aligned
if ($LASTEXITCODE -ne 0) { Fail 'apksigner failed' }

& $apksigner verify --print-certs $out | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" }

$size = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host ""
Write-Host "OK  $out  ($size KB)" -ForegroundColor Green

if ($Install) {
    Step 'installing via adb'
    & adb install -r $out
    if ($LASTEXITCODE -ne 0) { Fail 'adb install failed (device connected? same signing key as previous install?)' }
    Write-Host "Installed. Enable it in LSPosed (scope: PayPal) and force-stop the app." -ForegroundColor Yellow
}


