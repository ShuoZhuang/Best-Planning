# 真实 Windows 上的升级冒烟（UPD-045 / UPD-046 / UPD-047 的操作步骤与记录）。
#
# **它不是自动验收，而是把"人在真机上做的那几步"固定成可复现的脚本**：
#   1. 记录旧版包身份与用户数据目录的指纹；
#   2. 安装旧包（如果尚未安装）；
#   3. 用更新助手校验新包；
#   4. 原位安装新包（模拟助手的最终部署步骤）；
#   5. 记录新包身份、数据目录指纹与结果，写成 JSON 证据文件。
#
# 真正点击左下角入口完成"自动升级 + 健康确认 + 回退"的那条链路，必须另行在应用内执行；
# 本脚本只覆盖"Windows 部署与数据保持"这一层，避免把自动化脚本当成完整验收。
param(
  [Parameter(Mandatory = $true)][string]$OldMsix,
  [Parameter(Mandatory = $true)][string]$NewMsix,
  [string]$Helper = (Join-Path $PSScriptRoot '..\windows\update_helper\build\Release\update_helper.exe'),
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\.tooling')
)

$ErrorActionPreference = 'Stop'
$packageFamily = 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym'
$dataDirectory = Join-Path $env:LOCALAPPDATA "Packages\$packageFamily\LocalState"
$record = [ordered]@{
  startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  oldMsix = (Resolve-Path $OldMsix).Path
  newMsix = (Resolve-Path $NewMsix).Path
  packageFamily = $packageFamily
  dataDirectory = $dataDirectory
  steps = @()
}

function Add-Step([string]$Name, [string]$Status, [string]$Detail = '') {
  $record.steps += [ordered]@{
    name = $Name
    status = $Status
    detail = $Detail
    atUtc = (Get-Date).ToUniversalTime().ToString('o')
  }
  Write-Host "[$Status] $Name $Detail"
}

function Get-DataFingerprint {
  if (-not (Test-Path $dataDirectory)) { return $null }
  $files = Get-ChildItem $dataDirectory -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object FullName
  $lines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($dataDirectory.Length).TrimStart('\')
    $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$relative $($file.Length) $hash"
  }
  return ($lines -join "`n")
}

function Get-PackageIdentity([string]$Path) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' }
    if (-not $entry) { throw '包内没有 AppxManifest.xml' }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    $identity = $xml.Package.Identity
    return [ordered]@{
      name = $identity.Name
      publisher = $identity.Publisher
      version = $identity.Version
      architecture = $identity.ProcessorArchitecture
    }
  } finally {
    $zip.Dispose()
  }
}

try {
  $record.oldIdentity = Get-PackageIdentity $record.oldMsix
  $record.newIdentity = Get-PackageIdentity $record.newMsix
  Add-Step '读取包身份' 'PASS' "$($record.oldIdentity.version) -> $($record.newIdentity.version)"

  if ($record.oldIdentity.name -ne $record.newIdentity.name -or
      $record.oldIdentity.publisher -ne $record.newIdentity.publisher) {
    throw '包身份或发布者发生变化，禁止继续'
  }

  $record.dataBefore = Get-DataFingerprint
  Add-Step '记录更新前数据' 'PASS' "$(($record.dataBefore -split "`n").Count) 个文件"

  if (Test-Path $Helper) {
    & $Helper --verify $record.newMsix | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "助手验证失败（exit $LASTEXITCODE）" }
    Add-Step '助手验证新包' 'PASS'
  } else {
    Add-Step '助手验证新包' 'NOT RUN' "找不到 $Helper"
  }

  $installed = Get-AppxPackage -PackageTypeFilter Main | Where-Object { $_.PackageFamilyName -eq $packageFamily }
  if (-not $installed) {
    Add-AppxPackage -Path $record.oldMsix
    Add-Step '安装旧版本' 'PASS' $record.oldIdentity.version
  } else {
    Add-Step '安装旧版本' 'SKIPPED' "已安装 $($installed.Version)"
  }

  Add-AppxPackage -Path $record.newMsix
  $after = Get-AppxPackage -PackageTypeFilter Main | Where-Object { $_.PackageFamilyName -eq $packageFamily }
  Add-Step '原位升级' 'PASS' "$($after.Version)"

  $record.dataAfter = Get-DataFingerprint
  $record.dataPreserved = ($record.dataBefore -eq $record.dataAfter)
  Add-Step '数据指纹对比' $(if ($record.dataPreserved) { 'PASS' } else { 'FAIL' })

  # 安装态更新存储自检（实施计划 §9.6）：以包身份跑真实的 state.json 覆盖写与
  # `.partial → .ready` 提升，证明缓存根不在被重定向的 %LOCALAPPDATA% 下。
  $installedPackage = Get-AppxPackage -PackageTypeFilter Main |
    Where-Object { $_.PackageFamilyName -eq $packageFamily }
  if ($installedPackage -and $installedPackage.InstallLocation) {
    $exe = Join-Path $installedPackage.InstallLocation 'personal_planner.exe'
    if (Test-Path $exe) {
      $reportPath = Join-Path $OutputDirectory 'update-storage-selftest.json'
      if (Test-Path $reportPath) { Remove-Item $reportPath -Force }
      $env:PLANNER_UPDATE_STORAGE_SELFTEST = $reportPath
      try {
        $selfTest = Start-Process -FilePath $exe -Wait -PassThru
        if (Test-Path $reportPath) {
          $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
          Add-Step '安装态更新存储自检' $(if ($report.ok) { 'PASS' } else { 'FAIL' }) $report.root
          $record.updateStorage = $report
        } else {
          Add-Step '安装态更新存储自检' 'FAIL' "没有生成报告（exit $($selfTest.ExitCode)）"
        }
      } finally {
        Remove-Item Env:PLANNER_UPDATE_STORAGE_SELFTEST -ErrorAction SilentlyContinue
      }
    } else {
      Add-Step '安装态更新存储自检' 'NOT RUN' "找不到 $exe"
    }
  } else {
    Add-Step '安装态更新存储自检' 'NOT RUN' '没有已安装的包'
  }

  # 启动新版：由人确认主界面可用后，再运行应用的"检查更新"页确认健康。
  Add-Step '启动并检查界面' 'MANUAL' '请手动启动应用，确认主界面、任务、日历可用'
}
catch {
  Add-Step '失败' 'FAIL' $_.Exception.Message
  $record.error = $_.Exception.Message
}
finally {
  $record.finishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
  $path = Join-Path $OutputDirectory ("update-e2e-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
  $record | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
  Write-Host "证据写入 $path"
}
