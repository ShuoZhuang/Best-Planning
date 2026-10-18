# 发布门禁：离线安装器时代的五个正式产物必须同名、同版本、同哈希（规格 §14.3、§17）。
#
# 用法：
#   & tool\verify_release_assets.ps1 -Directory release-artifacts\1.10.0 -Version 1.10.0 -Build 47
#   & tool\verify_release_assets.ps1 -Directory ... -Version 1.10.0 -Build 47 -RequireSignature
param(
  [Parameter(Mandatory = $true)][string]$Directory,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][int]$Build,
  [string]$MsixVersion = '',
  [switch]$RequireSignature,
  [string]$UpdateStorageAcceptance = 'docs/testing/v1.10.0-packaged-update-storage-acceptance.md',
  [switch]$SkipUpdateStorageAcceptance
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$problems = New-Object System.Collections.Generic.List[string]

function Add-Problem([string]$text) {
  $script:problems.Add($text)
  Write-Host "FAIL $text" -ForegroundColor Red
}

function Assert([bool]$condition, [string]$text) {
  if (-not $condition) { Add-Problem $text }
}

if (-not $MsixVersion) { $MsixVersion = "$Version.0" }
if (-not (Test-Path $Directory)) { throw "找不到产物目录：$Directory" }
$directoryPath = (Resolve-Path $Directory).Path

$setupName = "BestPlanning_Setup_${Version}_x64.exe"
$portableName = "BestPlanning_Portable_${Version}_x64.zip"
$msixName = "BestPlanning_${MsixVersion}_x64.msix"
$manifestName = 'update-manifest.json'
$checksumName = 'SHA256SUMS.txt'

$expected = @($setupName, $portableName, $msixName, $manifestName, $checksumName)
foreach ($name in $expected) {
  Assert (Test-Path (Join-Path $directoryPath $name)) "缺少产物：$name"
}
if ($problems.Count -gt 0) {
  Write-Host "$($problems.Count) 个问题" -ForegroundColor Red
  exit 1
}

function Get-Sha256([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ── 版本一致性：pubspec 是唯一数值来源 ──────────────────────────────────────
$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw -Encoding UTF8
$pubspecVersion = [regex]::Match($pubspec, '(?m)^version:\s*(\S+)').Groups[1].Value
$pubspecMsix = [regex]::Match($pubspec, '(?m)^\s+msix_version:\s*(\S+)').Groups[1].Value
Assert ($pubspecVersion -eq "$Version+$Build") "pubspec.yaml 的 version 是 $pubspecVersion，应为 $Version+$Build"
Assert ($pubspecMsix -eq $MsixVersion) "pubspec.yaml 的 msix_version 是 $pubspecMsix，应为 $MsixVersion"

$backup = Get-Content -LiteralPath (Join-Path $root 'lib\app\backup_assembly.dart') -Raw -Encoding UTF8
$appVersion = [regex]::Match($backup, "const appVersion = '([^']+)'").Groups[1].Value
Assert ($appVersion -eq "$Version+$Build") "backup_assembly.dart 的 appVersion 是 $appVersion，应为 $Version+$Build"

# ── Setup：文件名、文件版本、内嵌载荷 ───────────────────────────────────────
$setupPath = Join-Path $directoryPath $setupName
$fileVersion = (Get-Item -LiteralPath $setupPath).VersionInfo.ProductVersion
Assert ($fileVersion -eq "$Version+$Build") "Setup 文件版本是 $fileVersion，应为 $Version+$Build"
# 在仓库**之外**的副本上运行 Setup：仓库内的进程受文件沙箱限制，无法创建临时目录，
# 会让内嵌自检报出与安装器无关的 INSTALLER_TEMP_UNAVAILABLE。
$gateStaging = Join-Path ([System.IO.Path]::GetTempPath()) "BestPlanningSetup\gate-$Version-$Build"
if (Test-Path $gateStaging) { Remove-Item $gateStaging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $gateStaging | Out-Null
$stagedSetup = Join-Path $gateStaging 'setup-under-test.exe'
Copy-Item -LiteralPath $setupPath -Destination $stagedSetup -Force
$embeddedCheck = (& $stagedSetup --verify-embedded | ConvertFrom-Json)
Assert ([bool]$embeddedCheck.ok) "Setup 内嵌载荷自检失败：$($embeddedCheck.errorCode) $($embeddedCheck.detail)"
Assert ($embeddedCheck.targetVersion -eq $MsixVersion) "Setup 内嵌版本 $($embeddedCheck.targetVersion) 与 $MsixVersion 不一致"

# ── MSIX：身份、版本、架构与哈希 ────────────────────────────────────────────
$helper = Join-Path $root 'windows\update_helper\build\Release\update_helper.exe'
$msixPath = Join-Path $directoryPath $msixName
$verified = (& $helper --verify $msixPath | ConvertFrom-Json)
Assert ([bool]$verified.ok) "MSIX 验证失败：$($verified.failureCode)"
Assert ($verified.identity.version -eq $MsixVersion) "MSIX 版本 $($verified.identity.version) 与 $MsixVersion 不一致"
Assert ($verified.identity.architecture -eq 'x64') "MSIX 架构不是 x64"
Assert ($embeddedCheck.packageSha256 -eq $verified.sha256) 'Setup 内嵌 MSIX 与独立 MSIX 的哈希不一致'
Assert ($embeddedCheck.familyName -eq $verified.identity.familyName) 'Setup 内嵌包族名与 MSIX 不一致'

# ── 签名清单：版本、身份、资产名、大小与哈希 ────────────────────────────────
$manifestPath = Join-Path $directoryPath $manifestName
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$payload = $manifest.payload
Assert ($payload.release.version -eq $Version) "清单 release.version 是 $($payload.release.version)，应为 $Version"
Assert ([int]$payload.release.buildNumber -eq $Build) "清单 buildNumber 是 $($payload.release.buildNumber)，应为 $Build"
Assert ($payload.release.msixVersion -eq $MsixVersion) '清单 msixVersion 不一致'
Assert ($payload.release.tag -eq "v$Version") "清单 tag 是 $($payload.release.tag)，应为 v$Version"
Assert ($payload.compatibility.packageIdentityName -eq $verified.identity.identityName) '清单包身份与 MSIX 不一致'
Assert ($payload.compatibility.publisher -eq $verified.identity.publisher) '清单发布者与 MSIX 不一致'
Assert ($payload.compatibility.architecture -eq 'x64') '清单架构不是 x64'
Assert ($payload.package.fileName -eq $msixName) "清单资产名是 $($payload.package.fileName)，应为 $msixName"
Assert ([int64]$payload.package.sizeBytes -eq [int64]$verified.sizeBytes) '清单大小与 MSIX 不一致'
Assert ($payload.package.sha256 -eq $verified.sha256) '清单哈希与 MSIX 不一致'
Assert ($manifest.signature.algorithm -eq 'Ed25519') '清单缺少 Ed25519 签名'

# ── SHA256SUMS：恰好覆盖四个产物，且哈希一致 ───────────────────────────────
$checksumPath = Join-Path $directoryPath $checksumName
$lines = Get-Content -LiteralPath $checksumPath | Where-Object { $_.Trim() -ne '' }
$entries = @{}
foreach ($line in $lines) {
  $match = [regex]::Match($line, '^([0-9a-fA-F]{64})\s{2}(.+)$')
  if (-not $match.Success) { Add-Problem "校验行格式不对：$line"; continue }
  $entries[$match.Groups[2].Value.Trim()] = $match.Groups[1].Value.ToLowerInvariant()
}
$hashedFiles = @($setupName, $portableName, $msixName, $manifestName)
foreach ($name in $hashedFiles) {
  Assert ($entries.ContainsKey($name)) "SHA256SUMS.txt 缺少 $name"
  if ($entries.ContainsKey($name)) {
    Assert ($entries[$name] -eq (Get-Sha256 (Join-Path $directoryPath $name))) "$name 的哈希与 SHA256SUMS.txt 不一致"
  }
}
foreach ($name in $entries.Keys) {
  Assert ($hashedFiles -contains $name) "SHA256SUMS.txt 含意外条目：$name"
}

# ── 便携版：必须真的可运行（含主程序与 app.so） ─────────────────────────────
Add-Type -AssemblyName System.IO.Compression.FileSystem
$portablePath = Join-Path $directoryPath $portableName
$archive = [System.IO.Compression.ZipFile]::OpenRead($portablePath)
try {
  $names = @($archive.Entries | ForEach-Object { $_.FullName })
  Assert ($names -contains 'personal_planner.exe') '便携版缺少 personal_planner.exe'
  Assert ($names -contains 'data/app.so' -or $names -contains 'data\app.so') '便携版缺少 data/app.so'
} finally {
  $archive.Dispose()
}

# ── 可选：Setup 必须带有效签名与时间戳 ─────────────────────────────────────
if ($RequireSignature) {
  $signature = Get-AuthenticodeSignature -LiteralPath $setupPath
  Assert ($signature.Status -eq 'Valid') "Setup 签名状态是 $($signature.Status)"
  Assert ($null -ne $signature.TimeStamperCertificate) 'Setup 签名缺少可信时间戳'
}

# ── 安装态更新存储验收（实施计划 §9.6）：缺证据或不是 PASS 时阻止发布 ──────
if (-not $SkipUpdateStorageAcceptance) {
  $acceptancePath = if ([System.IO.Path]::IsPathRooted($UpdateStorageAcceptance)) {
    $UpdateStorageAcceptance
  } else {
    Join-Path $root $UpdateStorageAcceptance
  }
  if (-not (Test-Path $acceptancePath)) {
    Add-Problem "缺少安装态更新存储验收记录：$UpdateStorageAcceptance"
  } else {
    $acceptance = Get-Content -LiteralPath $acceptancePath -Raw -Encoding UTF8
    if ($acceptance -notmatch '(?m)^结论：PASS\s*$') {
      Add-Problem '安装态更新存储验收记录不是 PASS（结论：PASS）'
    }
  }
}

$result = [ordered]@{
  ok          = ($problems.Count -eq 0)
  version     = "$Version+$Build"
  msixVersion = $MsixVersion
  directory   = $directoryPath
  setupSha256 = (Get-Sha256 $setupPath)
  msixSha256  = $verified.sha256
  problems    = @($problems)
}
$result | ConvertTo-Json -Depth 4
if ($problems.Count -gt 0) {
  Write-Host "$($problems.Count) 个问题" -ForegroundColor Red
  exit 1
}
Write-Host '发布门禁通过。' -ForegroundColor Green
exit 0
