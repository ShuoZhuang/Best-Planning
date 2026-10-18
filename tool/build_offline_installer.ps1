# 构建离线单文件安装器（规格 §14.1 第 6–10 步）。
#
# 流程：校验版本与身份 → 生成内嵌元数据 → 构建 Setup stub → 把最终 MSIX、公开证书与
# 元数据写进资源 → 自检 → （可选）签名 → 输出 SHA-256 摘要。
#
# 用法：
#   & tool\build_offline_installer.ps1 -Msix release-artifacts\1.10.0\BestPlanning_1.10.0.0_x64.msix `
#       -Certificate C:\Users\zs200\signing\personal_planner.cer -Version 1.10.0 -Build 47
param(
  [Parameter(Mandatory = $true)][string]$Msix,
  [Parameter(Mandatory = $true)][string]$Certificate,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][int]$Build,
  [string]$MsixVersion = '',
  [string]$OutputDirectory = 'release-artifacts',
  [string]$SetupFileName = '',
  [string]$CMakePath = $env:BEST_PLANNING_CMAKE,
  [string]$WinRTInclude = $env:BEST_PLANNING_WINRT_INCLUDE,
  [string]$SigningThumbprint = '',
  [string]$StagingDirectory = '',
  [switch]$SkipSign,
  [switch]$SkipBuild,
  [int]$MinimumWindowsBuild = 17763
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Resolve-CMake {
  if ($CMakePath -and (Test-Path $CMakePath)) { return $CMakePath }
  $candidates = @(
    'E:\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
    'C:\Program Files\CMake\bin\cmake.exe'
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  $command = Get-Command cmake -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  throw '找不到 cmake.exe；请用 -CMakePath 指定。'
}

function Resolve-WinRTInclude {
  if ($WinRTInclude -and (Test-Path $WinRTInclude)) { return $WinRTInclude }
  $found = Get-ChildItem @(
    'C:\Program Files (x86)\Windows Kits\10\Include\*\cppwinrt',
    'E:\Windows Kits\10\Include\*\cppwinrt'
  ) -Directory -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
  if ($found) { return $found.FullName }
  throw '找不到 C++/WinRT 投影头文件目录；请用 -WinRTInclude 指定。'
}

function Resolve-SignTool {
  $found = Get-ChildItem @(
    'E:\Windows Kits\10\bin\*\x64\signtool.exe',
    'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe'
  ) -File -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
  if ($found) { return $found.FullName }
  return $null
}

function Read-PubspecVersion {
  $text = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw -Encoding UTF8
  $version = [regex]::Match($text, '(?m)^version:\s*(\S+)').Groups[1].Value
  $msix = [regex]::Match($text, '(?m)^\s+msix_version:\s*(\S+)').Groups[1].Value
  $identity = [regex]::Match($text, '(?m)^\s+identity_name:\s*(\S+)').Groups[1].Value
  $publisher = [regex]::Match($text, '(?m)^\s+publisher:\s*(.+)$').Groups[1].Value.Trim()
  return [ordered]@{ version = $version; msix = $msix; identity = $identity; publisher = $publisher }
}

# ── 1. 版本与文件校验 ────────────────────────────────────────────────────────
$Version = $Version.Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version 必须是三段式（例如 1.10.0）：$Version"
}
$parts = $Version.Split('.')
if (-not $MsixVersion) { $MsixVersion = "$Version.0" }
if ($MsixVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
  throw "MsixVersion 必须是四段式：$MsixVersion"
}
if (-not $SetupFileName) { $SetupFileName = "BestPlanning_Setup_${Version}_x64.exe" }

$msixPath = (Resolve-Path -LiteralPath $Msix).Path
$certificatePath = (Resolve-Path -LiteralPath $Certificate).Path
$pubspec = Read-PubspecVersion
if ($pubspec.version -ne "$Version+$Build") {
  throw "pubspec.yaml 版本是 $($pubspec.version)，与 -Version $Version -Build $Build 不一致。"
}
if ($pubspec.msix -ne $MsixVersion) {
  throw "pubspec.yaml 的 msix_version 是 $($pubspec.msix)，与 $MsixVersion 不一致。"
}

$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory }
              else { Join-Path $root $OutputDirectory }
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$finalSetup = Join-Path $outputRoot $SetupFileName

# ── 2. 用更新助手读取成品身份与签名 ──────────────────────────────────────────
$helper = Join-Path $root 'windows\update_helper\build\Release\update_helper.exe'
if (-not (Test-Path $helper)) {
  & (Join-Path $PSScriptRoot 'build_update_helper.ps1') -ProjectRoot $root -SkipCopy | Out-Null
}
if (-not (Test-Path $helper)) { throw "找不到更新助手：$helper" }
$verify = (& $helper --verify $msixPath | ConvertFrom-Json)
if (-not $verify.ok) { throw "更新助手无法验证 MSIX：$($verify.failureCode)" }
if ($verify.identity.identityName -ne $pubspec.identity) {
  throw "MSIX 身份 $($verify.identity.identityName) 与 pubspec 的 $($pubspec.identity) 不一致。"
}
if ($verify.identity.publisher -ne $pubspec.publisher) {
  throw "MSIX 发布者与 pubspec 不一致：$($verify.identity.publisher)"
}
if ($verify.identity.version -ne $MsixVersion) {
  throw "MSIX 版本 $($verify.identity.version) 与目标 $MsixVersion 不一致。"
}
if ($verify.identity.architecture -ne 'x64') {
  throw "MSIX 架构必须是 x64，实际 $($verify.identity.architecture)"
}

# ── 3. 公开证书：DER 摘要与指纹 ─────────────────────────────────────────────
$certificateBytes = [System.IO.File]::ReadAllBytes($certificatePath)
$certificateObject = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$certificateBytes)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$certificateSha256 = -join ($sha256.ComputeHash($certificateBytes) | ForEach-Object { $_.ToString('x2') })
$certificateThumbprint = ($certificateObject.GetCertHashString()).ToUpperInvariant()
if ($certificateObject.Subject -ne $pubspec.publisher) {
  throw "签名证书主题是 $($certificateObject.Subject)，与 pubspec 的 $($pubspec.publisher) 不一致（正式构建拒绝测试证书）。"
}
if ($certificateObject.NotAfter -lt (Get-Date)) {
  throw "签名证书已过期：$($certificateObject.NotAfter)"
}

# ── 4. 生成内嵌元数据（唯一来源，不接受手工复制） ────────────────────────────
$metadata = [ordered]@{
  schemaVersion         = 1
  installerVersion      = "$Version+$Build"
  appVersion            = "$Version+$Build"
  msixVersion           = $verify.identity.version
  identityName          = $verify.identity.identityName
  publisher             = $verify.identity.publisher
  familyName            = $verify.identity.familyName
  architecture          = $verify.identity.architecture
  packageSizeBytes      = [int64]$verify.sizeBytes
  packageSha256         = $verify.sha256
  certificateSha256     = $certificateSha256
  certificateThumbprint = $certificateThumbprint
  minimumWindowsBuild   = $MinimumWindowsBuild
  assetFileName         = (Split-Path -Leaf $msixPath)
}
if (-not $StagingDirectory) {
  # 不要用 LOCALAPPDATA：fx.ps1 会把它改到仓库内部（构建 Flutter 时），而仓库内的
  # 进程会被文件沙箱限制写系统临时目录。这里用未受影响的临时目录。
  $StagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "BestPlanningSetup\build-$Version-$Build"
}
$staging = $StagingDirectory
if ($staging.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "暂存目录不能位于仓库内（会被文件沙箱误伤）：$staging"
}
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
$metadataPath = Join-Path $staging 'payload-metadata.json'
$metadataJson = ($metadata | ConvertTo-Json -Depth 4)
[System.IO.File]::WriteAllText($metadataPath, $metadataJson, (New-Object System.Text.UTF8Encoding($false)))

# ── 5. 构建 stub 与内嵌工具 ─────────────────────────────────────────────────
$cmake = Resolve-CMake
$winrt = Resolve-WinRTInclude
if (-not $SkipBuild) {
  $buildDirectory = Join-Path $root 'installer\build'
  & $cmake -S (Join-Path $root 'installer') -B $buildDirectory -G 'Visual Studio 18 2026' -A x64 `
      "-DWINRT_INCLUDE=$winrt" `
      "-DAPPSETUP_VERSION_MAJOR=$($parts[0])" `
      "-DAPPSETUP_VERSION_MINOR=$($parts[1])" `
      "-DAPPSETUP_VERSION_PATCH=$($parts[2])" `
      "-DAPPSETUP_VERSION_BUILD=$Build" `
      "-DAPPSETUP_VERSION_TEXT=$Version+$Build"
  if ($LASTEXITCODE -ne 0) { throw "cmake configure 失败（exit $LASTEXITCODE）" }
  & $cmake --build $buildDirectory --config Release --target BestPlanningSetup embed_payload
  if ($LASTEXITCODE -ne 0) { throw "cmake build 失败（exit $LASTEXITCODE）" }
}
$stub = Join-Path $root 'installer\build\Release\BestPlanningSetup.exe'
$embed = Join-Path $root 'installer\build\Release\embed_payload.exe'
if (-not (Test-Path $stub)) { throw "找不到 Setup stub：$stub" }
if (-not (Test-Path $embed)) { throw "找不到内嵌工具：$embed" }

# 安装器要能在真实位置运行：把 stub 与内嵌工具放到工作区之外再执行，
# 避免开发机上的文件沙箱把"写临时目录"误判成安装器缺陷。
Copy-Item $stub (Join-Path $staging 'stub.exe') -Force
Copy-Item $embed (Join-Path $staging 'embed_payload.exe') -Force
Copy-Item $msixPath (Join-Path $staging $metadata.assetFileName) -Force
Copy-Item $certificatePath (Join-Path $staging 'signing.cer') -Force

$stagedSetup = Join-Path $staging $SetupFileName
& (Join-Path $staging 'embed_payload.exe') `
    --stub (Join-Path $staging 'stub.exe') `
    --output $stagedSetup `
    --msix (Join-Path $staging $metadata.assetFileName) `
    --certificate (Join-Path $staging 'signing.cer') `
    --metadata $metadataPath | Out-Null
if ($LASTEXITCODE -ne 0) { throw "内嵌载荷失败（exit $LASTEXITCODE）" }

# ── 6. 内嵌后自检：读资源、校验字节、身份、签名与固定证书 ──────────────────
$embedded = (& $stagedSetup --verify-embedded | ConvertFrom-Json)
if (-not $embedded.ok) {
  throw "Setup 自检失败：$($embedded.errorCode) $($embedded.detail)"
}
if ($embedded.packageSha256 -ne $metadata.packageSha256) {
  throw "内嵌 MSIX 的 SHA-256 与元数据不一致。"
}
if ($embedded.certificateThumbprint -ne $certificateThumbprint) {
  throw "内嵌证书指纹与元数据不一致。"
}
$fileVersion = (Get-Item $stagedSetup).VersionInfo.ProductVersion
if ($fileVersion -ne "$Version+$Build") {
  throw "Setup 文件版本 $fileVersion 与目标 $Version+$Build 不一致。"
}

# ── 7. 可选签名：先嵌入再签名，签名后不再改文件 ────────────────────────────
$signed = $false
if (-not $SkipSign -and $SigningThumbprint) {
  $signtool = Resolve-SignTool
  if (-not $signtool) { throw '找不到 signtool.exe，无法签名 Setup。' }
  & $signtool sign /sha1 $SigningThumbprint /fd SHA256 `
      /tr 'http://timestamp.digicert.com' /td SHA256 $stagedSetup
  if ($LASTEXITCODE -ne 0) { throw "签名 Setup 失败（exit $LASTEXITCODE）" }
  $signature = Get-AuthenticodeSignature -LiteralPath $stagedSetup
  if ($signature.Status -ne 'Valid') {
    throw "Setup 签名验证失败：$($signature.Status) $($signature.StatusMessage)"
  }
  if (-not $signature.TimeStamperCertificate) {
    throw 'Setup 签名缺少可信时间戳。'
  }
  $signed = $true
}

Copy-Item $stagedSetup $finalSetup -Force
$setupHash = (Get-FileHash -LiteralPath $finalSetup -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [ordered]@{
  ok              = $true
  setup           = $finalSetup
  setupBytes      = (Get-Item $finalSetup).Length
  setupSha256     = $setupHash
  signed          = $signed
  version         = "$Version+$Build"
  msixVersion     = $MsixVersion
  packageSha256   = $metadata.packageSha256
  certificate     = $certificateThumbprint
  metadataPath    = $metadataPath
  stagingPath     = $staging
}
$result | ConvertTo-Json -Depth 4
