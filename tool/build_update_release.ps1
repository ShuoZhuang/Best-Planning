# 生成 1.9.0 / 1.9.1 的正式签名测试产物（不安装、不发布）。
#
# 产物目录：
#   release-artifacts/1.9.0/BestPlanning_1.9.0.0_x64.msix
#   release-artifacts/1.9.0/update-manifest.json
#   release-artifacts/1.9.1/...
#
# 每个版本都执行：
#   1. 临时改写 `pubspec.yaml` 与 `backup_assembly.dart` 的版本（结束后恢复）；
#   2. `flutter build windows`（带 build-name / build-number）；
#   3. 复制 `update_helper.exe` 后 `msix:create` 签名打包；
#   4. 重命名为清单约定的资产名；
#   5. 用助手 `--verify` 验证真实签名与身份；
#   6. 用 Ed25519 私钥生成清单，再跑 `update_pipeline verify` 复验。
#
# 用法：
#   & tool\build_update_release.ps1
#   & tool\build_update_release.ps1 -SkipHelperBuild
param(
  [string]$OutputRoot = 'release-artifacts',
  [string]$SigningKey = 'C:\Users\zs200\signing\update-manifest-ed25519.pem',
  [switch]$SkipHelperBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fx = Join-Path (Split-Path -Parent (Split-Path -Parent $root)) '.tooling\fx.ps1'
$prepare = Join-Path (Split-Path -Parent (Split-Path -Parent $root)) '.tooling\prepare-windows-build.ps1'
$dart = Join-Path (Split-Path -Parent (Split-Path -Parent $root)) '.tooling\flutter-bundle\flutter\bin\cache\dart-sdk\bin\dart.exe'
$helper = Join-Path $root 'windows\update_helper\build\Release\update_helper.exe'
$pubspec = Join-Path $root 'pubspec.yaml'
$backupAssembly = Join-Path $root 'lib\app\backup_assembly.dart'

$versions = @(
  [ordered]@{ app = '1.9.0+46'; name = '1.9.0'; build = '46'; msix = '1.9.0.0' },
  [ordered]@{ app = '1.9.1+47'; name = '1.9.1'; build = '47'; msix = '1.9.1.0' }
)

$pubspecOriginal = [System.IO.File]::ReadAllBytes($pubspec)
$backupOriginal = [System.IO.File]::ReadAllBytes($backupAssembly)

function Set-Version([string]$app, [string]$msix) {
  $script:pubspecText = $script:pubspecText -replace '(?m)^version: .*$', "version: $app"
  $script:pubspecText = $script:pubspecText -replace '(?m)^  msix_version: .*$', "  msix_version: $msix"
  $script:pubspecText = $script:pubspecText -replace '(?m)^  output_name: .*$', "  output_name: personal_planner_${msix}_x64"
  Set-Content -Path $pubspec -Value $script:pubspecText -Encoding UTF8
  $assemblyText = $backupOriginal -replace "const appVersion = '.*';", "const appVersion = '$app';"
  Set-Content -Path $backupAssembly -Value $assemblyText -Encoding UTF8
}

try {
  if (-not $SkipHelperBuild) {
    & (Join-Path $PSScriptRoot 'build_update_helper.ps1') -ProjectRoot $root | Out-Host
  }
  if (-not (Test-Path $helper)) { throw "找不到助手：$helper" }
  if (-not (Test-Path $SigningKey)) { throw "找不到签名私钥：$SigningKey" }
  $env:BEST_PLANNING_UPDATE_SIGNING_KEY = $SigningKey

  foreach ($version in $versions) {
    Write-Host "=== $($version.name) ==="
    $script:pubspecText = $pubspecOriginal
    Set-Version $version.app $version.msix

    & $prepare -ProjectRoot $root | Out-Null
    & $fx build windows --release --no-pub `
        "--build-name=$($version.name)" "--build-number=$($version.build)"
    if ($LASTEXITCODE -ne 0) { throw "$($version.name) flutter build 失败" }

    $releaseDir = Join-Path $root "build\windows\x64\runner\Release"
    Copy-Item $helper (Join-Path $releaseDir 'update_helper.exe') -Force

    $artifactDir = Join-Path $root (Join-Path $OutputRoot $version.name)
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    & $fx pub run msix:create --build-windows=false --output-path $artifactDir
    if ($LASTEXITCODE -ne 0) { throw "$($version.name) msix:create 失败" }

    $built = Get-ChildItem $artifactDir -Filter *.msix |
      Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $built) { throw "$($version.name) 没有生成 MSIX" }
    $finalName = "BestPlanning_$($version.msix)_x64.msix"
    $finalPath = Join-Path $artifactDir $finalName
    if ($built.FullName -ne $finalPath) {
      Move-Item $built.FullName $finalPath -Force
    }

    & $helper --verify $finalPath
    if ($LASTEXITCODE -ne 0) { throw "$($version.name) 助手验证失败" }

    $manifestPath = Join-Path $artifactDir 'update-manifest.json'
    & $dart run (Join-Path $PSScriptRoot 'update_pipeline.dart') manifest `
        --msix $finalPath `
        --version $version.name `
        --build $version.build `
        --msix-version $version.msix `
        --output $manifestPath
    if ($LASTEXITCODE -ne 0) { throw "$($version.name) 清单生成失败" }

    & $dart run (Join-Path $PSScriptRoot 'update_pipeline.dart') verify `
        --manifest $manifestPath --msix $finalPath
    if ($LASTEXITCODE -ne 0) { throw "$($version.name) 清单复验失败" }

    Write-Host "$($version.name) 产物：$finalPath"
    Write-Host "$($version.name) 清单：$manifestPath"
  }
}
finally {
  Set-Content -Path $pubspec -Value $pubspecOriginal -Encoding UTF8
  Set-Content -Path $backupAssembly -Value $backupOriginal -Encoding UTF8
  Write-Host 'pubspec.yaml / backup_assembly.dart 已恢复。'
}


