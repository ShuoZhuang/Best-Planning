# UAC 验收证据门禁的负例测试（修复计划 Task 7 Step 1、Step 3）。
#
# 用临时证据 JSON 覆盖七种无效情况；每种都必须让校验脚本退出 1，并指出具体缺失的 ID
# 或哈希。另有一个"完全有效"的对照用例，证明失败来自被改坏的那一项，而不是校验器
# 一律拒绝。
#
# 用法：& tool\installer_uac_gate_tests.ps1
param()

$ErrorActionPreference = 'Stop'
$gate = Join-Path $PSScriptRoot 'verify_installer_uac_evidence.ps1'
$version = '1.10.2'
$build = 51
$msixVersion = '1.10.2.0'
$setupSha = ('a' * 64)

$work = Join-Path $env:TEMP ("bp-uac-gate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure([string]$text) {
  $script:failures.Add($text)
  Write-Host "FAIL $text" -ForegroundColor Red
}
function Assert([bool]$condition, [string]$text) {
  if (-not $condition) { Add-Failure $text }
}

function Get-Sha256([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# 真实存在的日志与截图文件：门禁会按哈希核对，不用假路径。
$logPath = Join-Path $work 'setup.log'
$shotPath = Join-Path $work 'final.png'
[System.IO.File]::WriteAllText($logPath, "setup version 1.10.2+51`r`nfinalState Installed`r`n")
[System.IO.File]::WriteAllBytes($shotPath, [byte[]](1..64))

$ids = @(
  'UAC-ADMIN-01', 'UAC-ADMIN-02', 'UAC-STD-01', 'UAC-STD-02',
  'UAC-CANCEL-01', 'UAC-CANCEL-02', 'UAC-OFFLINE-01', 'UAC-TRUSTED-01',
  'UAC-UPGRADE-01', 'UAC-UPGRADE-02', 'UAC-REPAIR-01', 'UAC-UI-01'
)

function New-Cases([string]$status = 'PASS') {
  return @($ids | ForEach-Object {
      [ordered]@{
        id               = $_
        status           = $status
        osBuild          = '26200'
        accountMode      = 'filtered-admin'
        logPath          = $logPath
        logSha256        = (Get-Sha256 $logPath)
        screenshotPath   = $shotPath
        screenshotSha256 = (Get-Sha256 $shotPath)
      }
    })
}

function New-Evidence([object]$cases, [string]$releaseVersion = "$version+$build") {
  return ([ordered]@{
      schemaVersion  = 1
      releaseVersion = $releaseVersion
      msixVersion    = $msixVersion
      setupSha256    = $setupSha
      cases          = $cases
    } | ConvertTo-Json -Depth 6)
}

function Invoke-Gate([string]$evidenceText, [string]$setupHash = $setupSha) {
  $path = Join-Path $work ("evidence-" + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($path, $evidenceText, (New-Object System.Text.UTF8Encoding($false)))
  $output = & $gate -EvidencePath $path -SetupSha256 $setupHash `
      -Version $version -Build $build -MsixVersion $msixVersion 2>&1
  $exit = $LASTEXITCODE
  return [ordered]@{ exit = $exit; output = ($output | Out-String) }
}

function Expect-Failure([string]$name, [string]$evidenceText, [string]$setupHash = $setupSha,
                        [string]$expectText = '') {
  $result = Invoke-Gate $evidenceText $setupHash
  Assert ($result.exit -eq 1) "$name：应退出 1，实际 $($result.exit)"
  if ($expectText) {
    Assert ($result.output -match [regex]::Escape($expectText)) "$name：输出里没有指出 '$expectText'"
  }
  Write-Host ("{0} exit={1}" -f $name, $result.exit)
}

# 对照组：完全有效时必须通过，证明下面每一项失败都来自被改坏的那一处。
$valid = Invoke-Gate (New-Evidence (New-Cases))
Assert ($valid.exit -eq 0) "有效证据应通过，实际 exit $($valid.exit)：$($valid.output)"
Write-Host "baseline exit=$($valid.exit)"

# 1. 缺文件
$missing = Invoke-Gate (New-Evidence (New-Cases)) # 占位，下面用不存在的路径覆盖
$missingPath = Join-Path $work 'does-not-exist.json'
$output = & $gate -EvidencePath $missingPath -SetupSha256 $setupSha `
    -Version $version -Build $build -MsixVersion $msixVersion 2>&1
Assert ($LASTEXITCODE -eq 1) "缺文件：应退出 1"
Assert (($output | Out-String) -match '缺少 UAC broker 验收证据') '缺文件：输出没有指出缺少证据'
Write-Host "缺失证据 exit=$LASTEXITCODE"

# 2. 版本不符
Expect-Failure '版本不符' (New-Evidence (New-Cases) '1.10.1+50') $setupSha 'releaseVersion'

# 3. Setup 哈希不符
$wrongSetup = ('b' * 64)
Expect-Failure 'Setup 哈希不符' (New-Evidence (New-Cases)) $wrongSetup 'setupSha256'

# 4. 用例缺失
$missingCases = @(New-Cases | Where-Object { $_.id -ne 'UAC-UI-01' })
Expect-Failure '用例缺失' (New-Evidence $missingCases) $setupSha 'UAC-UI-01'

# 5. 重复 ID
$duplicated = New-Cases
$duplicated = @($duplicated + $duplicated[0])
Expect-Failure '重复 ID' (New-Evidence $duplicated) $setupSha '重复'

# 6. NOT RUN
$notRun = New-Cases
$notRun[3].status = 'NOT RUN'
Expect-Failure 'NOT RUN' (New-Evidence $notRun) $setupSha $ids[3]

# 7. 日志哈希不符
$badLog = New-Cases
$badLog[0].logSha256 = ('c' * 64)
Expect-Failure '日志哈希不符' (New-Evidence $badLog) $setupSha 'logPath'

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

$summary = [ordered]@{
  ok       = ($failures.Count -eq 0)
  cases    = 8
  failures = @($failures)
}
$summary | ConvertTo-Json -Depth 4
if ($failures.Count -gt 0) {
  Write-Host "$($failures.Count) 项失败" -ForegroundColor Red
  exit 1
}
Write-Host '门禁负例全部按预期被拒绝。' -ForegroundColor Green
exit 0
