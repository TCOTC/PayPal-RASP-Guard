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
    [string]$SdkRoot,
    # Signing. Leave empty to use (or generate) keystore\debug.keystore.
    [string]$Keystore,
    [string]$KeystorePass = 'android',
    [string]$KeyAlias = 'raspguard',
    [string]$KeyPass = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$app = Join-Path $root 'app'
$build = Join-Path $root 'build'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- toolchain ---
# 判断某个目录是不是可用 JDK。用 -LiteralPath，避免路径里的方括号等被当作通配符。
function Test-Jdk([string]$path) {
    if (-not $path) { return $false }
    return (Test-Path -LiteralPath (Join-Path $path 'bin\javac.exe')) -or
           (Test-Path -LiteralPath (Join-Path $path 'bin\javac'))
}

if ($JdkHome) {
    if (-not (Test-Jdk $JdkHome)) { Fail "JdkHome given but no javac under: $JdkHome" }
    Write-Host "JDK (explicit): $JdkHome"
}

if (-not $JdkHome) {
    # 显式给出候选，逐个打印结果 —— 排查 CI 环境差异时不必再猜。
    $tries = [ordered]@{}
    $tries['JAVA_HOME']                    = $env:JAVA_HOME
    $tries['JAVA_HOME_21_X64']             = $env:JAVA_HOME_21_X64
    $tries['JAVA_HOME_17_X64']             = $env:JAVA_HOME_17_X64
    if ($env:LOCALAPPDATA) {
        $tries['Android Studio JBR (local)'] = Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'
    }
    $tries['Android Studio JBR (Program Files)'] = 'C:\Program Files\Android\Android Studio\jbr'
    $tries['C:\Program Files\Java']              = 'C:\Program Files\Java'

    foreach ($key in $tries.Keys) {
        $cand = $tries[$key]
        if (-not $cand) { Write-Host "  JDK candidate [$key]: <unset>"; continue }
        if (Test-Jdk $cand) {
            Write-Host "  JDK candidate [$key]: $cand  -> ok"
            $JdkHome = $cand
            break
        }
        Write-Host "  JDK candidate [$key]: $cand  -> no javac"
    }
}

if (-not $JdkHome) {
    $cmd = Get-Command javac -ErrorAction SilentlyContinue
    if ($cmd) {
        $JdkHome = Split-Path (Split-Path $cmd.Source)
        Write-Host "  JDK candidate [PATH]: $JdkHome  -> ok"
    }
}

if (-not $JdkHome -and (Test-Path -LiteralPath 'C:\hostedtoolcache\windows')) {
    # GitHub runners 的 JDK 缓存布局：Java_<vendor>/<version>/x64
    $hit = Get-ChildItem -LiteralPath 'C:\hostedtoolcache\windows' -Directory -Filter 'Java_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue } |
        Where-Object { Test-Jdk $_.FullName } | Select-Object -First 1
    if ($hit) {
        $JdkHome = $hit.FullName
        Write-Host "  JDK candidate [hostedtoolcache]: $JdkHome  -> ok"
    }
}

if (-not $JdkHome) {
    Fail "JDK not found. Set JAVA_HOME or pass -JdkHome <path to JDK> (needs bin\javac.exe)."
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

if ($Keystore) {
    if (-not (Test-Path $Keystore)) { Fail "Keystore not found: $Keystore" }
    $keystore = (Resolve-Path $Keystore).Path
    Write-Host "using provided keystore: $keystore"
} else {
    $keystore = Join-Path $root 'keystore\debug.keystore'
}
if (-not (Test-Path $keystore)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $keystore) | Out-Null
    & $keytool -genkeypair -keystore $keystore -alias raspguard -keyalg RSA -keysize 2048 `
        -validity 3650 -storepass android -keypass android -dname "CN=PayPal RASP Guard, O=dsh, C=CN" | Out-Null
}

$version = ([xml](Get-Content (Join-Path $app 'AndroidManifest.xml'))).manifest.versionName
$out = Join-Path $build "PayPal-RASP-Guard-$version.apk"
if (-not $KeyPass) { $KeyPass = $KeystorePass }
& $apksigner sign --ks $keystore --ks-pass "pass:$KeystorePass" --key-pass "pass:$KeyPass" --out $out $aligned
if ($LASTEXITCODE -ne 0) { Fail 'apksigner failed' }

& $apksigner verify --print-certs $out | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" }

$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $out -Leaf)" | Out-File -Encoding ascii "$out.sha256"
$size = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host ""
Write-Host "OK  $out  ($size KB)" -ForegroundColor Green

if ($Install) {
    Step 'installing via adb'
    & adb install -r $out
    if ($LASTEXITCODE -ne 0) { Fail 'adb install failed (device connected? same signing key as previous install?)' }
    Write-Host "Installed. Enable it in LSPosed (scope: PayPal) and force-stop the app." -ForegroundColor Yellow
}



