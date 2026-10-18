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
$pubspecOriginalText = [System.Text.Encoding]::UTF8.GetString($pubspecOriginal)
$backupOriginalText = [System.Text.Encoding]::UTF8.GetString($backupOriginal)
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Set-Version([string]$app, [string]$msix) {
  $script:pubspecText = $pubspecOriginalText
  $script:pubspecText = $script:pubspecText -replace '(?m)^version: .*$', "version: $app"
  $script:pubspecText = $script:pubspecText -replace '(?m)^  msix_version: .*$', "  msix_version: $msix"
  $script:pubspecText = $script:pubspecText -replace '(?m)^  output_name: .*$', "  output_name: personal_planner_${msix}_x64"
  [System.IO.File]::WriteAllText($pubspec, $script:pubspecText, $utf8)
  $assemblyText = $backupOriginalText -replace "const appVersion = '.*';", "const appVersion = '$app';"
  [System.IO.File]::WriteAllText($backupAssembly, $assemblyText, $utf8)
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

    # 首次安装交付包：便携目录 + 已签名 MSIX + 证书 + 一键安装脚本 + 校验值。
    # 自更新只负责"已安装之后"，从未安装过的用户仍然需要这一包。
    $stamp = Get-Date -Format 'yyyyMMdd'
    $bundleName = "PersonalPlanner-$($version.name)-build$($version.build)-windows-x64-$stamp"
    $bundleDir = Join-Path $root "release-artifacts\$bundleName"
    if (Test-Path $bundleDir) { Remove-Item $bundleDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
    Copy-Item (Join-Path $releaseDir '*') $bundleDir -Recurse -Force
    Copy-Item $finalPath $bundleDir -Force
    Copy-Item $manifestPath $bundleDir -Force
    Copy-Item 'C:\Users\zs200\signing\personal_planner.cer' `
        (Join-Path $bundleDir 'PersonalPlanner-signing-cert.cer') -Force
    Copy-Item (Join-Path $root 'installer\安装.cmd') $bundleDir -Force
    Copy-Item (Join-Path $root 'installer\install-planner.ps1') $bundleDir -Force

    $guide = @"
优计主义 $($version.name)（build $($version.build)）Windows x64 使用说明
====================================================================

两种使用方式：

1. 安装版（推荐）
   双击「安装.cmd」。它会请求一次管理员权限，把同目录的
   PersonalPlanner-signing-cert.cer 导入「本地计算机 → 受信任人」，
   然后安装/原位升级同目录的 MSIX。装好后从开始菜单打开。
   只有安装版才会接收后续的自更新。

2. 便携版
   直接双击 personal_planner.exe。不需要证书、不写入开始菜单；
   便携版没有 Windows 包身份，因此不会自动更新，也不会注册通知。

数据位置
--------
任务与设置保存在用户文档目录的 personal_planner.sqlite，卸载或覆盖
安装不会删除它。升级前建议在「设置 → 数据与帮助 → 数据备份与恢复」
保存一份备份。

版本
----
应用：$($version.app)
MSIX：$($version.msix)
安装包：$finalName

校验
----
SHA-256.txt 记录 personal_planner.exe、data\app.so、MSIX 与证书的哈希；
下载后可用 `Get-FileHash <文件> -Algorithm SHA256` 核对。
"@
    Set-Content -Path (Join-Path $bundleDir '使用说明.txt') -Value $guide -Encoding UTF8

    $exePath = Join-Path $releaseDir 'personal_planner.exe'
    $appSoPath = Join-Path $releaseDir 'data\app.so'
    $certPath = Join-Path $bundleDir 'PersonalPlanner-signing-cert.cer'
    $sumLines = @(
      "$((Get-FileHash $exePath -Algorithm SHA256).Hash.ToLowerInvariant())  personal_planner.exe",
      "$((Get-FileHash $appSoPath -Algorithm SHA256).Hash.ToLowerInvariant())  data\app.so",
      "$((Get-FileHash $finalPath -Algorithm SHA256).Hash.ToLowerInvariant())  $finalName",
      "$((Get-FileHash $certPath -Algorithm SHA256).Hash.ToLowerInvariant())  PersonalPlanner-signing-cert.cer"
    )
    Set-Content -Path (Join-Path $bundleDir 'SHA-256.txt') -Value $sumLines -Encoding ASCII

    $zipPath = Join-Path $root "release-artifacts\$bundleName.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $outerSums = $sumLines + @("$zipHash  $bundleName.zip")
    Set-Content -Path (Join-Path $artifactDir 'SHA-256.txt') -Value $outerSums -Encoding ASCII

    Write-Host "$($version.name) 产物：$finalPath"
    Write-Host "$($version.name) 清单：$manifestPath"
    Write-Host "$($version.name) 首次安装包：$zipPath"
  }
}
finally {
  [System.IO.File]::WriteAllBytes($pubspec, $pubspecOriginal)
  [System.IO.File]::WriteAllBytes($backupAssembly, $backupOriginal)
  Write-Host 'pubspec.yaml / backup_assembly.dart 已恢复。'
}


