# 构建原生更新助手并放进 Flutter 的 Release 输出目录。
#
# 为什么需要这一步：`msix` 打包会把 `build\windows\x64\runner\Release` 下的文件整体装进包，
# 因此助手必须**先**复制到这里，再执行 `flutter build windows` / `flutter pub run msix:create`。
#
# 用法：
#   & tool\build_update_helper.ps1
#   & tool\build_update_helper.ps1 -Configuration Release -SkipCopy
param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$Configuration = 'Release',
  [switch]$SkipCopy,
  [string]$CMakePath = $env:BEST_PLANNING_CMAKE
)

$ErrorActionPreference = 'Stop'

if (-not $CMakePath) {
  $candidate = 'E:\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
  if (Test-Path $candidate) { $CMakePath = $candidate }
}
if (-not $CMakePath -or -not (Test-Path $CMakePath)) {
  throw '找不到 cmake.exe；请用 -CMakePath 指定，或把 cmake 加入 PATH。'
}

$sdkIncludeRoot = $env:BEST_PLANNING_WINRT_INCLUDE
if (-not $sdkIncludeRoot) {
  $candidates = @(
    'C:\Program Files (x86)\Windows Kits\10\Include\*\cppwinrt',
    'E:\Windows Kits\10\Include\*\cppwinrt'
  )
  $found = Get-ChildItem $candidates -Directory -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1
  if ($found) { $sdkIncludeRoot = $found.FullName }
}

$source = Join-Path $ProjectRoot 'windows\update_helper'
$build = Join-Path $source 'build'
$arguments = @('-S', $source, '-B', $build, '-G', 'Visual Studio 18 2026', '-A', 'x64')
if ($sdkIncludeRoot) { $arguments += "-DWINRT_INCLUDE=$sdkIncludeRoot" }

& $CMakePath @arguments
if ($LASTEXITCODE -ne 0) { throw "configure 失败（exit $LASTEXITCODE）" }
& $CMakePath --build $build --config $Configuration
if ($LASTEXITCODE -ne 0) { throw "build 失败（exit $LASTEXITCODE）" }

$exe = Join-Path $build "$Configuration\update_helper.exe"
if (-not (Test-Path $exe)) { throw "找不到 $exe" }

& $exe --selftest
if ($LASTEXITCODE -ne 0) { throw "助手自检失败（exit $LASTEXITCODE）" }

if (-not $SkipCopy) {
  $destination = Join-Path $ProjectRoot "build\windows\x64\runner\$Configuration"
  if (-not (Test-Path $destination)) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
  }
  Copy-Item $exe (Join-Path $destination 'update_helper.exe') -Force
  Write-Host "已复制到 $destination\update_helper.exe"
}

Write-Host '完成。'
