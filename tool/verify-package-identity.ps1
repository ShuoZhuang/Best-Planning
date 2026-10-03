# 核对 hasWindowsPackageIdentity 的两个分支（需要已安装并受信任的 MSIX）
#
# 为什么需要这个脚本：`lib/platform/windows/windows_package_identity.dart` 的单元测试无法覆盖
# "有包身份时返回 true"那一支——它要求进程真的跑在包里。而这一支在 §13.0 的 R8 ② 里长期登记为
# "不得计入已验证"。本脚本把它变成**可复现的核对**：
#
#   1. 非打包上下文（对照组）：`GetCurrentPackageFullName` 必须返回
#      APPMODEL_ERROR_NO_PACKAGE(15700) → 函数返回 false；
#   2. 包内上下文（实验组）：同一个 API、同一条**两段式缓冲流程**必须返回
#      122 → 0，并给出包全名 → 函数返回 true。
#
# 用了 `Invoke-CommandInDesktopPackage`（Appx 模块）把探针跑进包的上下文里，探针把结果写到临时
# 文件再由本脚本读回——因为该 cmdlet 不回传子进程的标准输出。
#
# 前置条件：MSIX 已安装（`Add-AppxPackage`），证书已被信任。未安装时脚本会直接说明并退出 1。
#
# 用法：
#   pwsh -File tool/verify-package-identity.ps1
#   pwsh -File tool/verify-package-identity.ps1 -PackageName ShuoZhuang.PersonalPlanner

[CmdletBinding()]
param(
  [string]$PackageName = 'ShuoZhuang.PersonalPlanner'
)

$ErrorActionPreference = 'Stop'

function Get-ProbeScript {
  # 两段式流程与生产代码逐行对应：先传 nullptr 取长度，再按长度分配缓冲取名字。
  # 用 ASCII 写入，避免 Windows PowerShell 5.1 把 UTF-8 无 BOM 的脚本按 ANSI 读而报语法错。
  @'
$out = @()
$sig = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PkgProbe {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern int GetCurrentPackageFullName(ref uint len, StringBuilder name);
}
"@
try { Add-Type -TypeDefinition $sig } catch { $out += "ADD-TYPE-FAIL: " + $_.Exception.Message }
if ($out.Count -eq 0) {
  $len = 0
  $r1 = [PkgProbe]::GetCurrentPackageFullName([ref]$len, $null)
  $out += "FIRST-RC=$r1"
  $out += "FIRST-LEN=$len"
  if ($r1 -eq 122 -and $len -gt 0) {
    $sb = New-Object System.Text.StringBuilder ([int]$len)
    $r2 = [PkgProbe]::GetCurrentPackageFullName([ref]$len, $sb)
    $out += "SECOND-RC=$r2"
    $out += "PACKAGE-FULL-NAME=" + $sb.ToString()
  }
}
$out | Set-Content -Path 'PROBE_OUT' -Encoding UTF8
'@
}

$package = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if (-not $package) {
  Write-Host "未找到已安装的包 '$PackageName'。请先用 Add-AppxPackage 安装 MSIX。" -ForegroundColor Yellow
  exit 1
}

$pfn = $package.PackageFamilyName
$appId = (Get-AppxPackageManifest -Package $package.PackageFullName).Package.Applications.Application.Id
Write-Host "包         : $($package.PackageFullName)"
Write-Host "包族名     : $pfn"
Write-Host "应用 Id    : $appId"
Write-Host ''

$powershell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$probeScript = Join-Path $env:TEMP 'dsh-pkg-identity-probe.ps1'
$controlOut = Join-Path $env:TEMP 'dsh-pkg-identity-control.txt'
$packagedOut = Join-Path $env:TEMP 'dsh-pkg-identity-packaged.txt'

function Invoke-Probe {
  param([string]$OutFile, [switch]$InPackage)
  Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
  (Get-ProbeScript).Replace('PROBE_OUT', $OutFile) |
    Set-Content -Path $probeScript -Encoding ASCII
  if ($InPackage) {
    Invoke-CommandInDesktopPackage -PackageFamilyName $pfn -AppId $appId `
      -Command $powershell51 `
      -Args "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$probeScript`"" | Out-Null
  } else {
    & $powershell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probeScript | Out-Null
  }
  # 该 cmdlet 不回传子进程输出，且不保证等到写文件完成，因此轮询而不是固定 sleep。
  for ($i = 0; $i -lt 20; $i++) {
    if (Test-Path $OutFile) { break }
    Start-Sleep -Milliseconds 500
  }
  if (-not (Test-Path $OutFile)) { return $null }
  return @(Get-Content $OutFile)
}

Write-Host '--- 对照组：非打包进程（期望 FIRST-RC=15700，即"没有包身份"）---'
$control = Invoke-Probe -OutFile $controlOut
if ($null -eq $control) { Write-Host '对照组没有产出结果' -ForegroundColor Red; exit 1 }
$control | ForEach-Object { Write-Host "    $_" }

Write-Host ''
Write-Host '--- 实验组：包内进程（期望 FIRST-RC=122 且 SECOND-RC=0）---'
$packaged = Invoke-Probe -OutFile $packagedOut -InPackage
if ($null -eq $packaged) { Write-Host '实验组没有产出结果' -ForegroundColor Red; exit 1 }
$packaged | ForEach-Object { Write-Host "    $_" }

Write-Host ''
$controlRc = ($control | Where-Object { $_ -like 'FIRST-RC=*' }) -replace 'FIRST-RC=', ''
$firstRc = ($packaged | Where-Object { $_ -like 'FIRST-RC=*' }) -replace 'FIRST-RC=', ''
$secondRc = ($packaged | Where-Object { $_ -like 'SECOND-RC=*' }) -replace 'SECOND-RC=', ''
$fullName = ($packaged | Where-Object { $_ -like 'PACKAGE-FULL-NAME=*' }) -replace 'PACKAGE-FULL-NAME=', ''

$ok = ($controlRc -eq '15700') -and ($firstRc -eq '122') -and ($secondRc -eq '0') -and
      ($fullName -eq $package.PackageFullName)

Write-Host '--- 结论 ---'
Write-Host "对照组返回 15700（无包身份）        : $(if ($controlRc -eq '15700') { '是' } else { "否（$controlRc）" })"
Write-Host "包内首调返回 122、二次返回 0        : $(if ($firstRc -eq '122' -and $secondRc -eq '0') { '是' } else { "否（$firstRc / $secondRc）" })"
Write-Host "包名与 InstallLocation 一致          : $(if ($fullName -eq $package.PackageFullName) { '是' } else { "否（$fullName）" })"
Write-Host ''
if ($ok) {
  Write-Host 'hasWindowsPackageIdentity 的两个分支均已用真实 kernel32 调用验证：' -ForegroundColor Green
  Write-Host '  非打包进程 → false（15700）；本包内进程 → true（122 → 0）。' -ForegroundColor Green
  exit 0
}
Write-Host '与预期不符，请检查上面的原始输出。' -ForegroundColor Red
exit 1
