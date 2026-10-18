# 离线安装器组件测试（规格 §16.2）。
#
# 覆盖：内嵌资源提取、篡改字节、替换证书、错误身份、错误哈希、无效会话 nonce、
# 未知子命令、普通流程不调用 PowerShell、--plan 不写系统。
#
# 所有被测 EXE 都复制到工作区之外再运行：开发机的文件沙箱会限制"位于仓库内的进程
# 写系统临时目录"，那是环境限制，不是安装器缺陷（2026-10-18 实测）。
#
# 用法：
#   & tool\installer_tests.ps1
#   & tool\installer_tests.ps1 -Msix release-artifacts\1.10.0\BestPlanning_1.10.0.0_x64.msix
param(
  [string]$Msix = '',
  [string]$Certificate = 'C:\Users\zs200\signing\personal_planner.cer',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cmake = 'E:\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$winrt = 'E:\Windows Kits\10\Include\10.0.26100.0\cppwinrt'
$staging = Join-Path $env:LOCALAPPDATA 'BestPlanningSetup\component-tests'
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string]$text) {
  $script:failures.Add($text)
  Write-Host "FAIL $text" -ForegroundColor Red
}

function Assert([bool]$condition, [string]$text) {
  if (-not $condition) { Add-Failure $text }
}

function Read-Json([string]$text) {
  try { return $text | ConvertFrom-Json } catch { return $null }
}

function Invoke-Setup([string]$exe, [string[]]$arguments) {
  $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru `
      -RedirectStandardOutput (Join-Path $staging 'setup-out.txt') `
      -RedirectStandardError (Join-Path $staging 'setup-err.txt')
  $stdout = Get-Content (Join-Path $staging 'setup-out.txt') -Raw -ErrorAction SilentlyContinue
  return [ordered]@{ exit = $process.ExitCode; stdout = $stdout }
}

function Get-Pubspec {
  $text = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw -Encoding UTF8
  return [ordered]@{
    version   = [regex]::Match($text, '(?m)^version:\s*(\S+)').Groups[1].Value
    msix      = [regex]::Match($text, '(?m)^\s+msix_version:\s*(\S+)').Groups[1].Value
    identity  = [regex]::Match($text, '(?m)^\s+identity_name:\s*(\S+)').Groups[1].Value
    publisher = [regex]::Match($text, '(?m)^\s+publisher:\s*(.+)$').Groups[1].Value.Trim()
  }
}

function New-Metadata(
  [string]$msixPath,
  [string]$certificatePath,
  [string]$outputPath,
  [string]$msixVersion,
  [hashtable]$overrides = @{}
) {
  $helper = Join-Path $root 'windows\update_helper\build\Release\update_helper.exe'
  $verify = Read-Json (& $helper --verify $msixPath)
  if (-not $verify.ok) { throw "无法读取 MSIX：$($verify.failureCode)" }
  $certificateBytes = [System.IO.File]::ReadAllBytes($certificatePath)
  $certificateObject = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$certificateBytes)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  $certificateSha256 = -join ($sha256.ComputeHash($certificateBytes) | ForEach-Object { $_.ToString('x2') })
  $metadata = [ordered]@{
    schemaVersion         = 1
    installerVersion      = '1.10.0+47'
    appVersion            = '1.10.0+47'
    msixVersion           = $verify.identity.version
    identityName          = $verify.identity.identityName
    publisher             = $verify.identity.publisher
    familyName            = $verify.identity.familyName
    architecture          = $verify.identity.architecture
    packageSizeBytes      = [int64]$verify.sizeBytes
    packageSha256         = $verify.sha256
    certificateSha256     = $certificateSha256
    certificateThumbprint = $certificateObject.GetCertHashString().ToUpperInvariant()
    minimumWindowsBuild   = 17763
    assetFileName         = (Split-Path -Leaf $msixPath)
  }
  foreach ($key in $overrides.Keys) { $metadata[$key] = $overrides[$key] }
  [System.IO.File]::WriteAllText($outputPath, ($metadata | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  return $metadata
}

function New-Setup([string]$name, [string]$msixPath, [string]$certificatePath, [string]$metadataPath) {
  $setupPath = Join-Path $staging $name
  & (Join-Path $staging 'embed_payload.exe') --stub (Join-Path $staging 'stub.exe') `
      --output $setupPath --msix $msixPath --certificate $certificatePath --metadata $metadataPath | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "内嵌失败：$name" }
  return $setupPath
}

# ── 准备：构建、清理、复制到工作区之外 ─────────────────────────────────────
if (-not $SkipBuild) {
  & $cmake -S (Join-Path $root 'installer') -B (Join-Path $root 'installer\build') `
      -G 'Visual Studio 18 2026' -A x64 "-DWINRT_INCLUDE=$winrt" | Out-Null
  & $cmake --build (Join-Path $root 'installer\build') --config Release | Out-Null
  if ($LASTEXITCODE -ne 0) { throw '安装器构建失败' }
}

$pubspec = Get-Pubspec
if (-not $Msix) {
  $candidate = Join-Path $root "release-artifacts\$($pubspec.version.Split('+')[0])\BestPlanning_$($pubspec.msix)_x64.msix"
  if (-not (Test-Path $candidate)) {
    throw "找不到 MSIX：$candidate；请先用 tool\build_update_release.ps1 生成。"
  }
  $Msix = $candidate
}
$Msix = (Resolve-Path -LiteralPath $Msix).Path
$Certificate = (Resolve-Path -LiteralPath $Certificate).Path
if (-not (Test-Path $Certificate)) { throw "找不到证书：$Certificate" }

if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$installerBuild = Join-Path $root 'installer\build\Release'
Copy-Item (Join-Path $installerBuild 'BestPlanningSetup.exe') (Join-Path $staging 'stub.exe') -Force
Copy-Item (Join-Path $installerBuild 'embed_payload.exe') (Join-Path $staging 'embed_payload.exe') -Force
Copy-Item (Join-Path $installerBuild 'installer_tests.exe') (Join-Path $staging 'installer_tests.exe') -Force
Copy-Item $Msix (Join-Path $staging 'payload.msix') -Force
Copy-Item $Certificate (Join-Path $staging 'signing.cer') -Force

# 两张真实证书：固定的发布证书 + 一张无关的自签名测试证书。
$testCertificate = New-SelfSignedCertificate -DnsName 'best-planning-installer-test.local' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(30)
Export-Certificate -Cert $testCertificate -FilePath (Join-Path $staging 'other.cer') -Type CERT | Out-Null
$otherCertificate = (Join-Path $staging 'other.cer')

# ── 1. 单元测试（真实 MSIX + 两张证书） ────────────────────────────────────
$unit = Start-Process -FilePath (Join-Path $staging 'installer_tests.exe') `
    -ArgumentList @('--msix', (Join-Path $staging 'payload.msix'), '--certificate', $Certificate,
                    '--second-certificate', $otherCertificate) `
    -Wait -PassThru -RedirectStandardOutput (Join-Path $staging 'unit.txt')
Write-Host (Get-Content (Join-Path $staging 'unit.txt') -Raw)
Assert ($unit.ExitCode -eq 0) "installer_tests 失败（exit $($unit.ExitCode)）"

# ── 2. 正常 Setup：自检、内嵌校验、计划模式 ────────────────────────────────
$metadataPath = Join-Path $staging 'metadata.json'
$metadata = New-Metadata (Join-Path $staging 'payload.msix') $Certificate $metadataPath $pubspec.msix
$validSetup = New-Setup 'setup-valid.exe' (Join-Path $staging 'payload.msix') $Certificate $metadataPath

$selftest = Invoke-Setup $validSetup @('--selftest')
Assert ($selftest.exit -eq 0) "Setup --selftest 失败（exit $($selftest.exit)）"

$verifyEmbedded = Invoke-Setup $validSetup @('--verify-embedded')
$embedded = Read-Json $verifyEmbedded.stdout
Assert ($verifyEmbedded.exit -eq 0 -and $embedded.ok) "Setup --verify-embedded 失败（exit $($verifyEmbedded.exit)）"
Assert ($embedded.packageSha256 -eq $metadata.packageSha256) '内嵌 SHA-256 与元数据不一致'
Assert ($embedded.familyName -eq $metadata.familyName) '内嵌包族名不一致'

$installedBefore = (Get-AppxPackage -Name $metadata.identityName -ErrorAction SilentlyContinue).Version
$plan = Invoke-Setup $validSetup @('--plan')
$planJson = Read-Json $plan.stdout
Assert ($plan.exit -eq 0 -and $planJson.ok) "Setup --plan 失败（exit $($plan.exit)）: $($plan.stdout)"
$installedAfter = (Get-AppxPackage -Name $metadata.identityName -ErrorAction SilentlyContinue).Version
Assert ("$installedBefore" -eq "$installedAfter") '--plan 不应改变已安装版本'

# ── 3. 篡改元数据哈希：必须在写系统之前失败（exit 30） ─────────────────────
$badHashMetadata = Join-Path $staging 'metadata-badhash.json'
New-Metadata (Join-Path $staging 'payload.msix') $Certificate $badHashMetadata $pubspec.msix `
    @{ packageSha256 = ('0' * 64) } | Out-Null
$badHashSetup = New-Setup 'setup-badhash.exe' (Join-Path $staging 'payload.msix') $Certificate $badHashMetadata
$badHash = Invoke-Setup $badHashSetup @('--verify-embedded')
Assert ($badHash.exit -eq 30) "哈希不符应返回 30，实际 $($badHash.exit)"

# ── 4. 篡改 MSIX 字节（元数据仍是原始哈希）：exit 30 ───────────────────────
$tamperedMsix = Join-Path $staging 'tampered.msix'
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $staging 'payload.msix'))
$middle = [int]($bytes.Length / 2)
$bytes[$middle] = $bytes[$middle] -bxor 0xFF
[System.IO.File]::WriteAllBytes($tamperedMsix, $bytes)
$tamperedSetup = New-Setup 'setup-tampered.exe' $tamperedMsix $Certificate $metadataPath
$tampered = Invoke-Setup $tamperedSetup @('--verify-embedded')
Assert ($tampered.exit -eq 30) "篡改字节应返回 30，实际 $($tampered.exit)"

# ── 5. 资源里换成另一张证书：必须拒绝（exit 30） ───────────────────────────
$wrongCertSetup = New-Setup 'setup-wrongcert.exe' (Join-Path $staging 'payload.msix') $otherCertificate $metadataPath
$wrongCert = Invoke-Setup $wrongCertSetup @('--verify-embedded')
Assert ($wrongCert.exit -eq 30) "错误证书应返回 30，实际 $($wrongCert.exit)"

# ── 6. 证书与元数据自洽但不是签名者：必须拒绝（exit 30） ───────────────────
$otherMetadataPath = Join-Path $staging 'metadata-othercert.json'
$otherMetadata = New-Metadata (Join-Path $staging 'payload.msix') $otherCertificate $otherMetadataPath $pubspec.msix
$signerMismatchSetup = New-Setup 'setup-signermismatch.exe' (Join-Path $staging 'payload.msix') $otherCertificate $otherMetadataPath
$signerMismatch = Invoke-Setup $signerMismatchSetup @('--verify-embedded')
Assert ($signerMismatch.exit -eq 30) "签名者不符应返回 30，实际 $($signerMismatch.exit)"

# ── 7. 错误身份：元数据必须自校验失败（exit 30） ───────────────────────────
$badIdentityMetadata = Join-Path $staging 'metadata-badidentity.json'
New-Metadata (Join-Path $staging 'payload.msix') $Certificate $badIdentityMetadata $pubspec.msix `
    @{ identityName = 'Someone.Else.Planner'; familyName = 'Someone.Else.Planner_v9555qkaxdyym' } | Out-Null
$badIdentitySetup = New-Setup 'setup-badidentity.exe' (Join-Path $staging 'payload.msix') $Certificate $badIdentityMetadata
$badIdentity = Invoke-Setup $badIdentitySetup @('--verify-embedded')
Assert ($badIdentity.exit -eq 30) "身份错误应返回 30，实际 $($badIdentity.exit)"

# ── 8. 无效提权会话：nonce 不对必须被拒绝，且不得写证书 ────────────────────
$nonce = ('a' * 64)
$badSession = Invoke-Setup $validSetup @('--elevated-session', '--pipe', '\\.\pipe\BestPlanningSetup-test',
                                         '--nonce', $nonce, '--parent', "$PID")
Assert ($badSession.exit -ne 0) "无效会话应被拒绝，实际 exit $($badSession.exit)"

# ── 9. 普通流程不得依赖 PowerShell ─────────────────────────────────────────
$binaryText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($validSetup))
Assert (-not ($binaryText -match '(?i)powershell')) 'Setup 二进制里出现了 powershell'
$sources = Get-ChildItem (Join-Path $root 'installer') -Recurse -Include *.cpp,*.h -File |
    Where-Object { $_.FullName -notmatch '\\build\\' }
foreach ($source in $sources) {
  $text = Get-Content -LiteralPath $source.FullName -Raw
  Assert (-not ($text -match '(?i)powershell|cmd\.exe')) "$($source.Name) 引用了 PowerShell 或 cmd"
}

# ── 10. 日志里不得出现业务数据路径（粗检） ─────────────────────────────────
$logRoot = Join-Path $env:LOCALAPPDATA 'BestPlanning\Setup'
if (Test-Path $logRoot) {
  $latest = Get-ChildItem $logRoot -Filter 'setup-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1
  if ($latest) {
    $logText = Get-Content -LiteralPath $latest.FullName -Raw
    Assert (-not ($logText -match 'sqlite|personal_planner\.sqlite|task_id|course_id')) '日志里出现了业务数据标识'
  }
}

# 清理本次生成的测试证书，避免往当前用户的证书库里堆东西。
Remove-Item "Cert:\CurrentUser\My\$($testCertificate.Thumbprint)" -Force -ErrorAction SilentlyContinue

$summary = [ordered]@{
  ok          = ($failures.Count -eq 0)
  failures    = @($failures)
  msix        = $Msix
  staging     = $staging
  tests       = 10
}
$summary | ConvertTo-Json -Depth 4
if ($failures.Count -gt 0) {
  Write-Host "$($failures.Count) 项失败" -ForegroundColor Red
  exit 1
}
Write-Host '组件测试全部通过。' -ForegroundColor Green
exit 0
