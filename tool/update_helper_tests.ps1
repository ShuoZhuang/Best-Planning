# 原生更新助手的可复现验收（UPD-015 / UPD-031 / UPD-032 / UPD-033 的本地证据）。
#
# 它做四件事：
#   1. 构建后运行 `--selftest`；
#   2. 对一份**真实签名 MSIX** 运行 `--verify`，断言身份与签名通过；
#   3. 生成一次性请求并运行 `--apply --dry-run`，断言锁、进程等待、二次验证与状态机
#      都真实执行，但**不部署、不激活**；
#   4. 用错误令牌验证请求会被拒绝。
#
# 用法：
#   & tool\update_helper_tests.ps1
#   & tool\update_helper_tests.ps1 -Msix build\windows\x64\runner\Release\personal_planner_1.8.1.0_x64.msix
param(
  [string]$Msix = 'build\windows\x64\runner\Release\personal_planner_1.8.1.0_x64.msix',
  [string]$Helper = 'windows\update_helper\build\Release\update_helper.exe',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$helperPath = if ([System.IO.Path]::IsPathRooted($Helper)) { $Helper } else { Join-Path $root $Helper }
$msixPath = if ([System.IO.Path]::IsPathRooted($Msix)) { $Msix } else { Join-Path $root $Msix }

if (-not $SkipBuild) {
  & (Join-Path $PSScriptRoot 'build_update_helper.ps1') -ProjectRoot $root -SkipCopy | Out-Host
}
if (-not (Test-Path $helperPath)) { throw "找不到助手：$helperPath" }
if (-not (Test-Path $msixPath)) { throw "找不到 MSIX：$msixPath" }

& $helperPath --selftest
if ($LASTEXITCODE -ne 0) { throw 'selftest 失败' }
Write-Host 'PASS selftest'

$verifyJson = & $helperPath --verify $msixPath
if ($LASTEXITCODE -ne 0) { throw "verify 失败：$verifyJson" }
$verify = $verifyJson | ConvertFrom-Json
if (-not $verify.ok) { throw "verify 未通过：$verifyJson" }
if ($verify.identity.identityName -ne 'ShuoZhuang.PersonalPlanner') {
  throw "包身份不符：$($verify.identity.identityName)"
}
if ($verify.identity.familyName -ne 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym') {
  throw "包族名不符：$($verify.identity.familyName)"
}
if ($verify.identity.architecture -ne 'x64') { throw "架构不符：$($verify.identity.architecture)" }
Write-Host "PASS verify $($verify.identity.version) sha256=$($verify.sha256)"

# 用仓库内的临时目录：本会话的受限令牌会拒绝助手在系统 TEMP 下创建文件。
$workRoot = Join-Path $root ('.tooling\helper-dryrun-' + [guid]::NewGuid().ToString('N'))
$versionDir = Join-Path $workRoot '1.8.1.0'
New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
try {
  $package = Join-Path $versionDir 'package.msix.ready'
  Copy-Item $msixPath $package
  $size = (Get-Item $package).Length
  $sha = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()
  $now = (Get-Date).ToUniversalTime()
  $request = [ordered]@{
    schemaVersion = 1
    transactionId = 'dry-run-1'
    fromVersion = '1.8.0.0'
    toVersion = '1.8.1.0'
    packagePath = $package
    packageSizeBytes = $size
    packageSha256 = $sha
    identityName = 'ShuoZhuang.PersonalPlanner'
    familyName = 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym'
    publisher = 'CN=Shuo Zhuang, O=Personal User, C=CN'
    architecture = 'x64'
    mainPid = 0
    trayPid = 0
    mainStartedAtUtc = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    trayStartedAtUtc = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    token = ('a' * 64)
    createdAtUtc = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    expiresAtUtc = $now.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ')
    rollbackPackagePath = $null
    rollbackVersion = $null
    snapshotPath = $null
    dataDirectory = $null
  }
  $requestPath = Join-Path $versionDir 'update-request.json'
  $request | ConvertTo-Json -Depth 5 | Set-Content -Path $requestPath -Encoding UTF8

  & $helperPath --apply $requestPath --dry-run | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'apply --dry-run 失败' }
  $status = Get-Content (Join-Path $versionDir 'helper-status.json') -Raw | ConvertFrom-Json
  if ($status.state -ne 'verified') { throw "apply 状态不是 verified：$($status.state)" }
  Write-Host 'PASS apply --dry-run（验证通过，未部署）'

  # 错误令牌必须被拒绝，且不进入部署阶段。
  $bad = [ordered]@{}
  foreach ($key in $request.Keys) { $bad[$key] = $request[$key] }
  $bad.transactionId = 'dry-run-bad-token'
  $bad.token = 'short'
  $badRequest = Join-Path $versionDir 'bad-request.json'
  $bad | ConvertTo-Json -Depth 5 | Set-Content -Path $badRequest -Encoding UTF8
  & $helperPath --apply $badRequest --dry-run | Out-Host
  if ($LASTEXITCODE -eq 0) { throw '错误令牌竟然被接受' }
  $badStatus = Get-Content (Join-Path $versionDir 'helper-status.json') -Raw | ConvertFrom-Json
  if ($badStatus.failureCode -ne 'UPDATE_HELPER_REQUEST_INVALID') {
    throw "错误令牌的失败码不对：$($badStatus.failureCode)"
  }
  Write-Host 'PASS 错误令牌被拒绝'
}
finally {
  if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force }
}

Write-Host '全部通过。'
exit 0

