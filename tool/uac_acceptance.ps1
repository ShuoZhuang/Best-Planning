# UAC 真人验收的取证与复位工具（修复计划 Task 6 辅助脚本，不是被测代码）。
#
# 它只做三件事，避免手抄与"看起来通过"：
#   -Phase reset  ：把机器恢复成"没有目标包、没有发布证书"的前置状态
#   -Phase before ：记录安装前账号/包/证书并截图
#   -Phase after  ：记录安装后状态、复制日志与截图、算出哈希，并按用例的硬期望校验
#   -Phase report ：把 12 个用例合并成 docs/testing/evidence/offline-installer-uac-broker-1.10.2.json
#
# 硬期望不符时 **拒绝写 PASS**（例如 UAC-CANCEL-01 必须是 exit 10 且没有包）。
# 本脚本不签任何东西、不改安装器、也不产生"模拟结果"。
#
# 用法（PowerShell 7）：
#   pwsh -NoProfile -File .\tool\uac_acceptance.ps1 -Case UAC-ADMIN-01 -Phase reset
#   pwsh -NoProfile -File .\tool\uac_acceptance.ps1 -Case UAC-ADMIN-01 -Phase before
#   ...（人工执行该用例）...
#   pwsh -NoProfile -File .\tool\uac_acceptance.ps1 -Case UAC-ADMIN-01 -Phase after -ExitCode 0 -Status PASS
#   pwsh -NoProfile -File .\tool\uac_acceptance.ps1 -Phase report
param(
  [string]$Case = '',
  [ValidateSet('reset', 'untrust', 'before', 'after', 'report')][string]$Phase = 'before',
  [int]$ExitCode = 0,
  [ValidateSet('PASS', 'FAIL')][string]$Status = 'PASS',
  [string]$Note = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$evidenceRoot = Join-Path $root 'docs\testing\evidence\offline-installer-uac-broker-1.10.2'
$identity = 'ShuoZhuang.PersonalPlanner'
$targetVersion = '1.10.2.0'
$certificateThumbprint = '9E157ECE535D16A224593CA39C084705A4FD3C13'

# 每个用例的硬期望：包是否必须登记为 1.10.2.0、退出码必须是多少。
$expectations = @{
  'UAC-ADMIN-01'   = @{ package = $targetVersion; exit = 0;  mode = 'filtered-admin' }
  'UAC-ADMIN-02'   = @{ package = $targetVersion; exit = 0;  mode = 'filtered-admin' }
  'UAC-STD-01'     = @{ package = $targetVersion; exit = 0;  mode = 'standard' }
  'UAC-STD-02'     = @{ package = $targetVersion; exit = 0;  mode = 'standard' }
  'UAC-CANCEL-01'  = @{ package = $null;          exit = 10; mode = 'filtered-admin' }
  'UAC-CANCEL-02'  = @{ package = $null;          exit = 10; mode = 'standard' }
  'UAC-OFFLINE-01' = @{ package = $targetVersion; exit = 0;  mode = 'filtered-admin' }
  'UAC-TRUSTED-01' = @{ package = $targetVersion; exit = 0;  mode = 'original-user' }
  'UAC-UPGRADE-01' = @{ package = $targetVersion; exit = 0;  mode = 'upgrade-from-1.10.0' }
  'UAC-UPGRADE-02' = @{ package = $targetVersion; exit = 0;  mode = 'upgrade-from-1.10.1' }
  'UAC-REPAIR-01'  = @{ package = $targetVersion; exit = 0;  mode = 'repair-1.10.2' }
  'UAC-UI-01'      = @{ package = $null;          exit = 31; mode = 'filtered-admin' }
}

function Get-InstalledPackage {
  $package = Get-AppxPackage -Name $identity -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $package) { return $null }
  return [ordered]@{ version = "$($package.Version)"; status = "$($package.Status)"; fullName = $package.PackageFullName }
}

function Get-TrustedCertificate {
  return @(Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty Thumbprint)
}

function Save-Screenshot([string]$path) {
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    return $true
  } catch {
    Write-Warning "截图失败（需要在交互式桌面会话里运行）：$($_.Exception.Message)"
    return $false
  }
}

function Get-LatestSetupLog {
  $logRoot = Join-Path $env:LOCALAPPDATA 'BestPlanning\Setup'
  if (-not (Test-Path $logRoot)) { return $null }
  return Get-ChildItem $logRoot -Filter 'setup-*.log' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime | Select-Object -Last 1
}

function Get-Sha256([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RelativePath([string]$path) {
  return [System.IO.Path]::GetRelativePath($root, $path).Replace('\', '/')
}

function Get-CaseDir([string]$id) {
  $dir = Join-Path $evidenceRoot $id
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function Get-AccountSnapshot {
  $groups = whoami /groups
  $admin = [bool]($groups | Select-String -SimpleMatch 'S-1-5-32-544')
  $integrity = if ($groups | Select-String -SimpleMatch 'S-1-16-12288') { 'high' }
               elseif ($groups | Select-String -SimpleMatch 'S-1-16-8192') { 'medium' }
               else { 'unknown' }
  return [ordered]@{
    whoami    = "$(whoami)"
    isAdmin   = $admin
    integrity = $integrity
    osBuild   = "$((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
  }
}

if ($Phase -ne 'report') {
  if ([string]::IsNullOrWhiteSpace($Case) -or -not $expectations.ContainsKey($Case)) {
    throw "需要 -Case <ID>，可选：$($expectations.Keys -join ', ')"
  }
}

# reset / untrust 要写 LocalMachine 证书库：在普通权限终端里调用时自动用一次 UAC 提权重启自己。
if ($Phase -in @('reset', 'untrust')) {
  $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '需要管理员权限来移除受信任证书，正在请求一次 UAC…'
    $arguments = @('-NoProfile', '-File', $PSCommandPath, '-Case', $Case, '-Phase', $Phase)
    $elevated = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments `
        -Verb RunAs -Wait -PassThru
    exit $elevated.ExitCode
  }
}

switch ($Phase) {
  'reset' {
    $package = Get-InstalledPackage
    if ($null -ne $package) {
      Get-AppxPackage -Name $identity | Remove-AppxPackage -ErrorAction Stop
      Write-Host "已卸载 $identity $($package.version)"
    } else { Write-Host '目标包本来就不存在' }

    $present = Get-TrustedCertificate
    if ($present -contains $certificateThumbprint) {
      Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$certificateThumbprint" -Force
      Write-Host '已移除发布证书（可用 C:\ProgramData\BestPlanningSetup-acceptance\personal_planner.cer 导回）'
    } else { Write-Host '发布证书本来就不在 TrustedPeople' }

    $packageAfter = Get-InstalledPackage
    $certAfter = Get-TrustedCertificate
    [ordered]@{
      ok             = ($null -eq $packageAfter -and -not ($certAfter -contains $certificateThumbprint))
      package        = $packageAfter
      trustedPeople  = $certAfter
      account        = Get-AccountSnapshot
    } | ConvertTo-Json -Depth 4
  }

  'untrust' {
    # 只移除发布证书，**保留**已安装的包：升级用例需要"装着旧版、但证书尚未受信任"。
    $present = Get-TrustedCertificate
    if ($present -contains $certificateThumbprint) {
      Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$certificateThumbprint" -Force
      Write-Host '已移除发布证书（包保留）'
    } else { Write-Host '发布证书本来就不在 TrustedPeople' }
    [ordered]@{
      package       = Get-InstalledPackage
      trustedPeople = Get-TrustedCertificate
    } | ConvertTo-Json -Depth 4
  }
  'before' {
    $dir = Get-CaseDir $Case
    $snapshot = Get-AccountSnapshot
    $snapshot.package = Get-InstalledPackage
    $snapshot.trustedPeople = Get-TrustedCertificate
    $snapshot.capturedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'before.json') -Encoding UTF8
    $shot = Join-Path $dir 'screenshot-before.png'
    if (Save-Screenshot $shot) { Write-Host "截图：$shot" }
    $snapshot | ConvertTo-Json -Depth 4
  }

  'after' {
    $dir = Get-CaseDir $Case
    $expectation = $expectations[$Case]
    $snapshot = Get-AccountSnapshot
    $snapshot.package = Get-InstalledPackage
    $snapshot.trustedPeople = Get-TrustedCertificate
    $snapshot.exitCode = $ExitCode
    $snapshot.capturedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    $shotPath = Join-Path $dir 'screenshot-after.png'
    if (Save-Screenshot $shotPath) { Write-Host "截图：$shotPath" }

    $log = Get-LatestSetupLog
    $logPath = $null
    if ($null -ne $log) {
      $logPath = Join-Path $dir 'setup.log'
      Copy-Item $log.FullName $logPath -Force
      $lines = Get-Content -LiteralPath $logPath
      $snapshot.finalState = ($lines | Select-String -Pattern '^.*finalState ' | Select-Object -Last 1 |
          ForEach-Object { ($_ -split 'finalState ')[-1].Trim() })
      $snapshot.lastFailure = ($lines | Select-String -Pattern '^.*failure ' | Select-Object -Last 1 |
          ForEach-Object { $_.Line.Trim() })
      $snapshot.channelLines = @($lines | Select-String -Pattern 'elevation (launch|channel|helper)' |
          ForEach-Object { $_.Line.Trim() })
    } else {
      Write-Warning '没有找到 Setup 日志'
    }

    # ── 硬期望校验：不符就拒绝 PASS ───────────────────────────────────────────
    $problems = @()
    if ($ExitCode -ne $expectation.exit) {
      $problems += "退出码应为 $($expectation.exit)，实际 $ExitCode"
    }
    $actualVersion = if ($null -eq $snapshot.package) { $null } else { $snapshot.package.version }
    if ($null -eq $expectation.package) {
      if ($null -ne $actualVersion) { $problems += "不应该登记包，实际 $actualVersion" }
    } elseif ($actualVersion -ne $expectation.package) {
      $problems += "包版本应为 $($expectation.package)，实际 $actualVersion"
    }
    if ($expectation.exit -eq 0 -and -not ($snapshot.trustedPeople -contains $certificateThumbprint)) {
      $problems += '成功用例必须看到发布证书已写入 TrustedPeople'
    }
    if ($null -eq $logPath) { $problems += '缺少 Setup 日志' }
    # 取消类用例必须证明"UAC 被拒绝"，而不是"在准备页点了取消"——两者退出码相同，
    # 但后者完全没有触及提权路径。
    if ($Case -in @('UAC-CANCEL-01', 'UAC-CANCEL-02')) {
      if ($null -ne $logPath) {
        $logText = Get-Content -LiteralPath $logPath -Raw
        if ($logText -notmatch 'uac-declined') {
          $problems += '日志没有 uac-declined：这次不是 UAC 被拒绝（可能是在准备页点了取消）'
        }
      }
      if ($snapshot.finalState -ne 'NotInstalled') {
        $problems += "取消用例的 finalState 应为 NotInstalled，实际 $($snapshot.finalState)"
      }
    }
    if (-not (Test-Path $shotPath)) { $problems += '缺少截图' }

    $declared = $Status
    if ($declared -eq 'PASS' -and $problems.Count -gt 0) {
      $declared = 'FAIL'
      Write-Host '按硬期望校验，本用例不能记为 PASS：' -ForegroundColor Red
      $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    }

    $record = [ordered]@{
      id           = $Case
      status       = $declared
      declared     = $Status
      problems     = @($problems)
      osBuild      = $snapshot.osBuild
      accountMode  = $expectation.mode
      exitCode     = $ExitCode
      finalState   = $snapshot.finalState
      note         = $Note
      logPath      = if ($logPath) { Get-RelativePath $logPath } else { '' }
      logSha256    = if ($logPath) { Get-Sha256 $logPath } else { '' }
      screenshotPath = if (Test-Path $shotPath) { Get-RelativePath $shotPath } else { '' }
      screenshotSha256 = if (Test-Path $shotPath) { Get-Sha256 $shotPath } else { '' }
    }
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'after.json') -Encoding UTF8
    $record | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'case.json') -Encoding UTF8
    $record | ConvertTo-Json -Depth 4
  }

  'report' {
    $cases = @()
    foreach ($id in $expectations.Keys | Sort-Object) {
      $file = Join-Path $evidenceRoot "$id\case.json"
      if (-not (Test-Path $file)) {
        $cases += [ordered]@{
          id = $id; status = 'NOT RUN'; osBuild = ''; accountMode = $expectations[$id].mode
          logPath = ''; logSha256 = ''; screenshotPath = ''; screenshotSha256 = ''
        }
        continue
      }
      $record = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
      $cases += [ordered]@{
        id = $id; status = $record.status; osBuild = $record.osBuild
        accountMode = $record.accountMode; logPath = $record.logPath
        logSha256 = $record.logSha256; screenshotPath = $record.screenshotPath
        screenshotSha256 = $record.screenshotSha256
      }
    }

    $setup = 'release-artifacts\1.10.2\BestPlanning_Setup_1.10.2_x64.exe'
    $setupPath = Join-Path $root $setup
    $document = [ordered]@{
      schemaVersion  = 1
      releaseVersion = '1.10.2+51'
      msixVersion    = '1.10.2.0'
      setupSha256    = if (Test-Path $setupPath) { Get-Sha256 $setupPath } else { '' }
      candidate      = [ordered]@{
        setupFileName = (Split-Path -Leaf $setup)
        setupBytes    = if (Test-Path $setupPath) { (Get-Item $setupPath).Length } else { 0 }
        authenticodeStatus = if (Test-Path $setupPath) { "$((Get-AuthenticodeSignature $setupPath).Status)" } else { '' }
        timestampCertificate = if (Test-Path $setupPath) { "$((Get-AuthenticodeSignature $setupPath).TimeStamperCertificate.Subject)" } else { '' }
        embeddedMsixSha256 = if (Test-Path $setupPath) {
          ((& (Join-Path $root 'windows\update_helper\build\Release\update_helper.exe') --verify (Join-Path $root 'release-artifacts\1.10.2\BestPlanning_1.10.2.0_x64.msix') | ConvertFrom-Json).sha256)
        } else { '' }
        targetVersion = '1.10.2+51'
        recordedAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
      }
      cases = $cases
    }
    $jsonPath = Join-Path (Split-Path -Parent $evidenceRoot) 'offline-installer-uac-broker-1.10.2.json'
    $document | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $pass = @($cases | Where-Object { $_.status -eq 'PASS' }).Count
    [ordered]@{
      ok       = ($pass -eq $cases.Count)
      passed   = $pass
      total    = $cases.Count
      evidence = Get-RelativePath $jsonPath
    } | ConvertTo-Json -Depth 4
  }
}
