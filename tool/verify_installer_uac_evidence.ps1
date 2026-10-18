# 发布门禁的一部分：校验 UAC broker 的 12 项真人验收证据（修复计划 Task 6 Step 6、Task 7 Step 1/2）。
#
# 单独成文件是为了能被负例测试直接驱动：缺文件、版本不符、Setup 哈希不符、用例缺失、
# 重复 ID、NOT RUN、日志哈希不符这七种情况都必须让本脚本退出 1。
#
# 用法：
#   & tool\verify_installer_uac_evidence.ps1 `
#       -EvidencePath docs/testing/evidence/offline-installer-uac-broker-1.10.2.json `
#       -SetupSha256 <最终签名 Setup 的 hash> -Version 1.10.2 -Build 51 -MsixVersion 1.10.2.0
param(
  [Parameter(Mandatory = $true)][string]$EvidencePath,
  [Parameter(Mandatory = $true)][string]$SetupSha256,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][int]$Build,
  [Parameter(Mandatory = $true)][string]$MsixVersion
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$problems = New-Object System.Collections.Generic.List[string]

function Add-Problem([string]$text) {
  $script:problems.Add($text)
  Write-Host "FAIL $text" -ForegroundColor Red
}

function Resolve-RepoPath([string]$relative) {
  if ([string]::IsNullOrWhiteSpace($relative)) { return $null }
  if ([System.IO.Path]::IsPathRooted($relative)) { return $relative }
  return (Join-Path $root $relative)
}

# 12 个 ID 必须恰好出现一次（顺序不敏感）。
$expectedIds = @(
  'UAC-ADMIN-01', 'UAC-ADMIN-02', 'UAC-STD-01', 'UAC-STD-02',
  'UAC-CANCEL-01', 'UAC-CANCEL-02', 'UAC-OFFLINE-01', 'UAC-TRUSTED-01',
  'UAC-UPGRADE-01', 'UAC-UPGRADE-02', 'UAC-REPAIR-01', 'UAC-UI-01'
)

$path = Resolve-RepoPath $EvidencePath
if ($null -eq $path -or -not (Test-Path -LiteralPath $path)) {
  Add-Problem "缺少 UAC broker 验收证据：$EvidencePath"
} else {
  try {
    $evidence = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    $evidence = $null
    Add-Problem "UAC broker 验收证据不是合法 JSON：$EvidencePath"
  }

  if ($null -ne $evidence) {
    if ($evidence.schemaVersion -ne 1) {
      Add-Problem "UAC 证据 schemaVersion 是 $($evidence.schemaVersion)，应为 1"
    }
    if ($evidence.releaseVersion -ne "$Version+$Build") {
      Add-Problem "UAC 证据 releaseVersion 是 $($evidence.releaseVersion)，应为 $Version+$Build"
    }
    if ($evidence.msixVersion -ne $MsixVersion) {
      Add-Problem "UAC 证据 msixVersion 是 $($evidence.msixVersion)，应为 $MsixVersion"
    }
    $recordedSetup = ([string]$evidence.setupSha256).ToLowerInvariant()
    if ($recordedSetup -notmatch '^[0-9a-f]{64}$') {
      Add-Problem 'UAC 证据 setupSha256 为空或不是 64 位小写十六进制'
    } elseif ($recordedSetup -ne $SetupSha256.ToLowerInvariant()) {
      Add-Problem 'UAC 证据 setupSha256 与当前 Setup 不一致（证据绑定的是另一个候选）'
    }

    $cases = @($evidence.cases)
    $seen = @{}
    foreach ($case in $cases) {
      $id = [string]$case.id
      if ($expectedIds -notcontains $id) {
        Add-Problem "UAC 证据出现未知用例：$id"
        continue
      }
      if ($seen.ContainsKey($id)) {
        Add-Problem "UAC 证据用例重复：$id"
        continue
      }
      $seen[$id] = $case
    }
    foreach ($id in $expectedIds) {
      if (-not $seen.ContainsKey($id)) { Add-Problem "UAC 证据缺少用例：$id" }
    }

    foreach ($id in $expectedIds) {
      if (-not $seen.ContainsKey($id)) { continue }
      $case = $seen[$id]
      if ($case.status -ne 'PASS') {
        Add-Problem "UAC 用例 $id 状态是 $($case.status)，只有 PASS 才允许发布"
        continue
      }
      foreach ($field in @('osBuild', 'accountMode')) {
        if ([string]::IsNullOrWhiteSpace([string]$case.$field)) {
          Add-Problem "UAC 用例 $id 缺少 $field"
        }
      }
      foreach ($pair in @(
          @{ path = 'logPath'; hash = 'logSha256' },
          @{ path = 'screenshotPath'; hash = 'screenshotSha256' })) {
        $relative = [string]$case.($pair.path)
        $expectedHash = ([string]$case.($pair.hash)).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($relative)) {
          Add-Problem "UAC 用例 $id 缺少 $($pair.path)"
          continue
        }
        if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
          Add-Problem "UAC 用例 $id 的 $($pair.hash) 不是 64 位小写十六进制"
          continue
        }
        $resolved = Resolve-RepoPath $relative
        if (-not (Test-Path -LiteralPath $resolved)) {
          Add-Problem "UAC 用例 $id 的 $($pair.path) 不存在：$relative"
          continue
        }
        $actual = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expectedHash) {
          Add-Problem "UAC 用例 $id 的 $($pair.path) 哈希不符：$relative"
        }
      }
    }
  }
}

$result = [ordered]@{
  ok       = ($problems.Count -eq 0)
  evidence = $EvidencePath
  problems = @($problems)
}
$result | ConvertTo-Json -Depth 4
if ($problems.Count -gt 0) {
  Write-Host "$($problems.Count) 个问题" -ForegroundColor Red
  exit 1
}
exit 0
