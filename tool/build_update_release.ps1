# 生成 1.10.0 的五个正式产物（不安装、不上传）。
#
# 产物目录 release-artifacts/1.10.0：
#   BestPlanning_Setup_1.10.0_x64.exe       离线单文件安装器（内嵌 MSIX 与公开证书）
#   BestPlanning_Portable_1.10.0_x64.zip    便携版
#   BestPlanning_1.10.0.0_x64.msix          已签名 MSIX
#   update-manifest.json                    应用内更新清单（Ed25519 签名）
#   SHA256SUMS.txt                          四个产物的 SHA-256
#
# 用法：
#   & tool\build_update_release.ps1
#   & tool\build_update_release.ps1 -SkipSign          # 本地验证：不签 Setup
#   & tool\build_update_release.ps1 -SkipFlutterBuild  # 复用已有 Release 输出
param(
  [string]$Version = '1.10.0',
  [int]$Build = 47,
  [string]$MsixVersion = '1.10.0.0',
  [string]$OutputDirectory = 'release-artifacts',
  [string]$SigningKey = 'C:\Users\zs200\signing\update-manifest-ed25519.pem',
  [string]$SigningCertificate = 'C:\Users\zs200\signing\personal_planner.cer',
  [string]$SigningThumbprint = '9E157ECE535D16A224593CA39C084705A4FD3C13',
  [switch]$SkipHelperBuild,
  [switch]$SkipFlutterBuild,
  [switch]$SkipSign
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$workspace = Split-Path -Parent (Split-Path -Parent $root)
$fx = Join-Path $workspace '.tooling\fx.ps1'
$prepare = Join-Path $workspace '.tooling\prepare-windows-build.ps1'
$dart = Join-Path $workspace '.tooling\flutter-bundle\flutter\bin\cache\dart-sdk\bin\dart.exe'
$helper = Join-Path $root 'windows\update_helper\build\Release\update_helper.exe'
$pubspec = Join-Path $root 'pubspec.yaml'
$backupAssembly = Join-Path $root 'lib\app\backup_assembly.dart'

$artifactDir = Join-Path $root (Join-Path $OutputDirectory $Version)
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

# 暂存目录必须在仓库之外：fx.ps1 会把 TEMP/LOCALAPPDATA 指到仓库内部，而仓库内的
# 进程受文件沙箱限制，无法写系统临时目录（会让安装器自检出现假失败）。
$realTemp = [System.IO.Path]::GetTempPath()
$stagingRoot = Join-Path $realTemp 'BestPlanningSetup\staging'
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

$msixName = "BestPlanning_${MsixVersion}_x64.msix"
$setupName = "BestPlanning_Setup_${Version}_x64.exe"
$portableName = "BestPlanning_Portable_${Version}_x64.zip"

$pubspecOriginal = [System.IO.File]::ReadAllBytes($pubspec)
$backupOriginal = [System.IO.File]::ReadAllBytes($backupAssembly)
$pubspecText = [System.Text.Encoding]::UTF8.GetString($pubspecOriginal)
$backupText = [System.Text.Encoding]::UTF8.GetString($backupOriginal)
$utf8 = New-Object System.Text.UTF8Encoding($false)

try {
  $pubspecText = $pubspecText -replace '(?m)^version: .*$', "version: $Version+$Build"
  $pubspecText = $pubspecText -replace '(?m)^  msix_version: .*$', "  msix_version: $MsixVersion"
  $pubspecText = $pubspecText -replace '(?m)^  output_name: .*$', "  output_name: personal_planner_${MsixVersion}_x64"
  [System.IO.File]::WriteAllText($pubspec, $pubspecText, $utf8)
  $backupText = $backupText -replace "const appVersion = '.*';", "const appVersion = '$Version+$Build';"
  [System.IO.File]::WriteAllText($backupAssembly, $backupText, $utf8)

  if (-not $SkipHelperBuild) {
    & (Join-Path $PSScriptRoot 'build_update_helper.ps1') -ProjectRoot $root -SkipCopy | Out-Null
  }
  if (-not (Test-Path $helper)) { throw "找不到助手：$helper" }
  if (-not (Test-Path $SigningKey)) { throw "找不到签名私钥：$SigningKey" }
  $env:BEST_PLANNING_UPDATE_SIGNING_KEY = $SigningKey

  if (-not $SkipFlutterBuild) {
    # fx.ps1 会把 TEMP/TMP/LOCALAPPDATA 指到仓库内部；调用完立刻还原，
    # 否则后面所有"在仓库外暂存"的逻辑都会跟着变。
    $envBackup = @{}
    foreach ($name in @('TEMP', 'TMP', 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE')) {
      $envBackup[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }
    & $prepare -ProjectRoot $root | Out-Null
    & $fx build windows --release --no-pub "--build-name=$Version" "--build-number=$Build"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build 失败' }
    foreach ($name in $envBackup.Keys) {
      [System.Environment]::SetEnvironmentVariable($name, $envBackup[$name])
    }
  }
  if (-not (Test-Path (Join-Path $releaseDir 'personal_planner.exe'))) {
    throw "找不到应用输出：$releaseDir"
  }
  Copy-Item $helper (Join-Path $releaseDir 'update_helper.exe') -Force

  # ── MSIX ──────────────────────────────────────────────────────────────────
  & $fx pub run msix:create --build-windows=false --output-path $artifactDir
  if ($LASTEXITCODE -ne 0) { throw 'msix:create 失败' }
  $built = Get-ChildItem $artifactDir -Filter *.msix | Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $built) { throw '没有生成 MSIX' }
  $msixPath = Join-Path $artifactDir $msixName
  if ($built.FullName -ne $msixPath) { Move-Item $built.FullName $msixPath -Force }

  & $helper --verify $msixPath
  if ($LASTEXITCODE -ne 0) { throw '助手验证 MSIX 失败' }

  $manifestPath = Join-Path $artifactDir 'update-manifest.json'
  & $dart run (Join-Path $PSScriptRoot 'update_pipeline.dart') manifest `
      --msix $msixPath `
      --version $Version `
      --build $Build `
      --msix-version $MsixVersion `
      --output $manifestPath
  if ($LASTEXITCODE -ne 0) { throw '清单生成失败' }
  & $dart run (Join-Path $PSScriptRoot 'update_pipeline.dart') verify `
      --manifest $manifestPath --msix $msixPath
  if ($LASTEXITCODE -ne 0) { throw '清单复验失败' }

  # ── 便携版 ────────────────────────────────────────────────────────────────
  $portablePath = Join-Path $artifactDir $portableName
  if (Test-Path $portablePath) { Remove-Item $portablePath -Force }
  Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $portablePath -CompressionLevel Optimal

  # ── 离线单文件安装器 ──────────────────────────────────────────────────────
  $setupParams = @{
    Msix             = $msixPath
    Certificate      = $SigningCertificate
    Version          = $Version
    Build            = $Build
    MsixVersion      = $MsixVersion
    OutputDirectory  = (Join-Path $OutputDirectory $Version)
    StagingDirectory = (Join-Path $stagingRoot "build-$Version-$Build")
  }
  if (-not $SkipSign -and $SigningThumbprint) {
    $setupParams.SigningThumbprint = $SigningThumbprint
  } else {
    $setupParams.SkipSign = $true
  }
  & (Join-Path $PSScriptRoot 'build_offline_installer.ps1') @setupParams
  if ($LASTEXITCODE -ne 0) { throw '构建离线安装器失败' }
  if (-not (Test-Path (Join-Path $artifactDir $setupName))) {
    throw "离线安装器没有产出：$setupName"
  }

  # ── 校验清单 ──────────────────────────────────────────────────────────────
  $checksumLines = @()
  foreach ($name in @($setupName, $portableName, $msixName, 'update-manifest.json')) {
    $path = Join-Path $artifactDir $name
    if (-not (Test-Path $path)) { throw "缺少产物：$path" }
    $checksumLines += "$((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant())  $name"
  }
  Set-Content -LiteralPath (Join-Path $artifactDir 'SHA256SUMS.txt') -Value $checksumLines -Encoding ASCII

  # ── 门禁 ──────────────────────────────────────────────────────────────────
  $gateParams = @{
    Directory   = $artifactDir
    Version     = $Version
    Build       = $Build
    MsixVersion = $MsixVersion
  }
  if (-not $SkipSign -and $SigningThumbprint) { $gateParams.RequireSignature = $true }
  & (Join-Path $PSScriptRoot 'verify_release_assets.ps1') @gateParams
  if ($LASTEXITCODE -ne 0) { throw '发布门禁未通过' }

  [ordered]@{
    ok          = $true
    version     = "$Version+$Build"
    msixVersion = $MsixVersion
    directory   = $artifactDir
    setup       = (Join-Path $artifactDir $setupName)
    setupSha256 = (Get-FileHash (Join-Path $artifactDir $setupName) -Algorithm SHA256).Hash.ToLowerInvariant()
    portable    = $portablePath
    msix        = $msixPath
    manifest    = $manifestPath
  } | ConvertTo-Json -Depth 4
}
finally {
  [System.IO.File]::WriteAllBytes($pubspec, $pubspecOriginal)
  [System.IO.File]::WriteAllBytes($backupAssembly, $backupOriginal)
  Write-Host 'pubspec.yaml / backup_assembly.dart 已恢复。'
}
