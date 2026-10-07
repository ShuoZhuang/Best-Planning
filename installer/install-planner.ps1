# 智能日程 —— MSIX 一键安装／升级
#
# **为什么需要它**：本包是**自签名**的，Windows 要求先信任签名证书，否则双击 MSIX 会报
# 「证书链已处理，但终止于不受信任的根证书」(0x800B0109)。手动翻证书库要选"本地计算机"、
# 再挑"受信任人"存储，步骤多且容易点错。这个脚本把那几步合成一次双击。
#
# **它做什么**（仅此三件，不做别的）：
#   1. 把同目录的 `PersonalPlanner-signing-cert.cer` 导入 **本地计算机 → 受信任人**（幂等：已存在就跳过）；
#   2. 用 `Add-AppxPackage` 安装／**原位升级**同目录的 `*.msix`；
#   3. 报告结果。
#
# **为什么导入"受信任人"而不是"受信任的根证书颁发机构"**：前者是微软为旁加载（sideloading）
# 指定的较窄信任位置——只让这张证书能装应用，不会让它被当成任何网站／系统的根证书。
#
# 需要管理员：脚本会自己请求提权（会弹一次 UAC 确认框）。
$ErrorActionPreference = 'Stop'

# ── 自提权：不是管理员就重新以管理员身份启动自己，然后退出这一个实例 ──
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '需要管理员权限来信任证书并安装，正在请求提权…' -ForegroundColor Yellow
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
  )
  exit
}

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok($text) { Write-Host "    $text" -ForegroundColor Green }
function Write-Bad($text) { Write-Host "    $text" -ForegroundColor Red }

try {
  $dir = Split-Path -Parent $PSCommandPath
  $cer = Get-ChildItem -LiteralPath $dir -Filter 'PersonalPlanner-signing-cert.cer' -ErrorAction SilentlyContinue | Select-Object -First 1
  $msix = Get-ChildItem -LiteralPath $dir -Filter '*.msix' -ErrorAction SilentlyContinue | Select-Object -First 1

  if (-not $cer) { throw "同目录下找不到 PersonalPlanner-signing-cert.cer —— 请把整个文件夹一起解压，不要只复制单个文件。" }
  if (-not $msix) { throw "同目录下找不到 .msix 安装包 —— 请把整个文件夹一起解压，不要只复制单个文件。" }

  Write-Step "证书：$($cer.Name)"
  # **不要用 `Import-Certificate -CertStoreLocation 'Cert:\...'`**：在 `powershell.exe`（Windows
  # PowerShell 5.1）+ `-NoProfile` 的会话里证书提供程序尚未加载，传 `Cert:\` 路径会直接报
  # 「Cannot find drive. A drive with the name 'Cert' does not exist.」——2026-10-07 的真机验证
  # 正是这样失败的（而此前只在"证书早就受信任"的机器上试过，差点当成能用）。
  # 改用 .NET 证书库 API：与宿主、与提供程序的加载顺序都无关。
  $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cer.FullName)
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  try {
    # 幂等：同一张证书已在"受信任人"里就不再导入，避免每次升级往证书库里堆重复项。
    $already = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if ($already) {
      Write-Ok "已经受信任（指纹 $($cert.Thumbprint)），跳过导入。"
    }
    else {
      $store.Add($cert)
      Write-Ok "已导入 本地计算机\受信任人（指纹 $($cert.Thumbprint)）。"
    }
  }
  finally {
    $store.Close()
  }

  Write-Step "安装包：$($msix.Name)"
  $before = (Get-AppxPackage -Name 'ShuoZhuang.PersonalPlanner' -ErrorAction SilentlyContinue).Version
  try {
    Add-AppxPackage -Path $msix.FullName -ErrorAction Stop
  }
  catch {
    # 同一个版本再装一次时，Windows 会以不同措辞报错；这不算失败，如实说明即可。
    $now = (Get-AppxPackage -Name 'ShuoZhuang.PersonalPlanner' -ErrorAction SilentlyContinue).Version
    if ($now) {
      Write-Ok "该版本已经安装（$now），无需重复安装。"
    }
    else {
      throw
    }
  }
  $after = (Get-AppxPackage -Name 'ShuoZhuang.PersonalPlanner' -ErrorAction SilentlyContinue).Version

  Write-Host ''
  if ($before -and $after -and $before.ToString() -ne $after.ToString()) {
    Write-Host "完成：已从 $before 升级到 $after。" -ForegroundColor Green
  }
  elseif ($after) {
    Write-Host "完成：当前版本 $after。" -ForegroundColor Green
  }
  else {
    Write-Host '完成。' -ForegroundColor Green
  }
  Write-Host '可以从开始菜单打开「智能日程」。' -ForegroundColor Green
}
catch {
  Write-Host ''
  Write-Bad "安装失败：$($_.Exception.Message)"
  Write-Host ''
  Write-Host '可以改用手动步骤：' -ForegroundColor Yellow
  Write-Host '  1) 右键 PersonalPlanner-signing-cert.cer → 安装证书'
  Write-Host '  2) 存储位置选「本地计算机」→ 把证书放入「受信任人」'
  Write-Host '  3) 再双击 .msix 安装'
  Write-Host ''
  Write-Host '或者直接改用便携版：解压后双击 personal_planner.exe（不需要证书）。' -ForegroundColor Yellow
}
finally {
  Write-Host ''
  # 双击运行时停留，好让人看清结果；自动化验证时用环境变量跳过（否则会一直等人按键）。
  if ($env:PLANNER_INSTALLER_NO_PAUSE -ne '1') {
    Read-Host '按回车键关闭此窗口'
  }
}
