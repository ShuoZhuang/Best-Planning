# UAC 验收操作手册（本机 Windows 11 家庭版 · 10 例）

本文件是 `docs/testing/offline-installer-uac-broker-acceptance.md` 的**执行手册**，只覆盖
能在本机完成的 10 个用例。`UAC-ADMIN-02` / `UAC-STD-02`（Windows 10）**本机无法完成**，
缺这两项之前发布保持阻断。

## 0. 本机已做的准备（2026-10-18，可回滚）

| 项目 | 现状 | 回滚方式 |
| --- | --- | --- |
| UAC | `EnableLUA=1`（**重启后生效**） | `Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' EnableLUA 0` + 重启 |
| 管理员账户 | `AdminTest` / `Qx7!mVp2-Lk9a`（Administrators） | `Remove-LocalUser AdminTest` |
| 标准账户 | `StandardTest` / `Rz4@nWq8-Tb3s`（Users） | `Remove-LocalUser StandardTest` |
| 发布证书 | 已从 `LocalMachine\TrustedPeople` 移除 | `Import-Certificate -FilePath C:\Users\zs200\signing\personal_planner.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople` |
| 被测产物 | `C:\ProgramData\BestPlanningSetup-acceptance\cand2\`（当前候选）；同目录 `old\` 放 1.10.0/1.10.1 MSIX，以及 `.cer` | 删除目录即可 |
| 当前已装应用 | `ShuoZhuang.PersonalPlanner 1.10.0.0` | 升级后如需回退：卸载后装 `old\BestPlanning_1.10.0.0_x64.msix` |

回滚记录：`docs/testing/evidence/offline-installer-uac-broker-1.10.2/machine-before.json`。

## 1. 重启，并确认 UAC 真的生效

重启后打开 PowerShell：

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA   # 期望 1
whoami /groups | Select-String 'S-1-16-'      # 普通启动的会话应为 S-1-16-8192（Medium）
```

> 如果 DSH / 终端是"以管理员身份运行"启动的，那里的会话仍是 High，**不要**从中双击 Setup，
> 否则安装器会走 `elevation skipped` 分支、根本不触发 UAC。双击操作一律用资源管理器。

## 2. 两条 PowerShell 窗口的分工

| 用途 | 窗口 | 原因 |
| --- | --- | --- |
| `-Phase reset`（卸载包、移除证书） | **管理员** pwsh | 写 `LocalMachine` 证书库需要提权 |
| `-Phase before` / `after`（取证） | 普通 pwsh（与执行安装的账户一致） | 账号/包/日志都是"当前用户"视角 |
| 运行 Setup | **资源管理器双击** | 必须是普通完整性 |

## 3. 执行顺序（10 例）

每例都按 `reset → before → 人工执行 → after` 走。`after` 会按硬期望校验：退出码、包是否
登记为 `1.10.2.0`、证书是否写入；不符时**拒绝记 PASS**。

```powershell
cd G:\best-planing\.worktrees\native-implementation
$acc = '.\tool\uac_acceptance.ps1'
```

### 3.1 UAC-UPGRADE-01（1.10.0.0 → 1.10.2.0，证书未信任）

无需 reset：本机当前就是 `1.10.0.0` 且证书已移除。

```powershell
pwsh -NoProfile -File $acc -Case UAC-UPGRADE-01 -Phase before
# 资源管理器双击 C:\ProgramData\BestPlanningSetup-acceptance\cand2\BestPlanning_Setup_1.10.2_x64.exe
#   应出现一次 UAC 提示（发布者显示"未知发布者"，因为证书还没进受信任人）→ 点"是"
#   完成后记下退出码：在资源管理器启动时看不到，用下面的命令取最后一次运行的退出码
pwsh -NoProfile -File $acc -Case UAC-UPGRADE-01 -Phase after -ExitCode 0 -Status PASS
```

**通过标准**：`Get-AppxPackage ShuoZhuang.PersonalPlanner` 显示 `1.10.2.0`、`Status Ok`；
业务数据仍在（`F:\Documents\personal_planner.sqlite` 大小/哈希不变）；日志里有
`certificate imported` 与 `elevation channel connected clientPid=… protocol=2`。

> 取退出码的最省事方式：用 `cmd /c start /wait` 不行（会绕过普通令牌）。
> 建议改用：资源管理器地址栏运行 Setup，然后看日志最后一行 `finalState`，并在 `after`
> 时手工确认退出码（失败页会显示"退出码"）。若你不确定，就先按 `-ExitCode 0` 记录，
> 脚本会用包版本与证书状态反查；不符它会拒绝 PASS。

### 3.2 UAC-REPAIR-01（已装 1.10.2.0，选择"修复安装"）

```powershell
pwsh -NoProfile -File $acc -Case UAC-REPAIR-01 -Phase before
# 双击同一个 Setup；此时证书已受信任 → 不应再弹 UAC
# 在"当前版本已经安装"页面点"修复安装"
pwsh -NoProfile -File $acc -Case UAC-REPAIR-01 -Phase after -ExitCode 0 -Status PASS
```

**通过标准**：没有先卸载、数据未清、最终仍是 `1.10.2.0`。

### 3.3 UAC-TRUSTED-01（证书已存在 → 不弹 UAC）

```powershell
pwsh -NoProfile -File $acc -Case UAC-TRUSTED-01 -Phase before
# 双击 Setup：必须**没有** UAC 提示；页面直接进入"当前版本已经安装"或安装流程
pwsh -NoProfile -File $acc -Case UAC-TRUSTED-01 -Phase after -ExitCode 0 -Status PASS
```

### 3.4 UAC-CANCEL-01（管理员点"否"）

```powershell
pwsh -NoProfile -File $acc -Case UAC-CANCEL-01 -Phase reset     # 需管理员窗口
pwsh -NoProfile -File $acc -Case UAC-CANCEL-01 -Phase before
# 双击 Setup → UAC 点"否"
pwsh -NoProfile -File $acc -Case UAC-CANCEL-01 -Phase after -ExitCode 10 -Status PASS
```

**通过标准**：退出码 10；证书不存在；包不存在；日志 `finalState NotInstalled`，
且**不出现** `INSTALLER_CERTIFICATE_IMPORT_FAILED`。

### 3.5 UAC-ADMIN-01（干净首次安装，点"是"）

```powershell
pwsh -NoProfile -File $acc -Case UAC-ADMIN-01 -Phase reset
pwsh -NoProfile -File $acc -Case UAC-ADMIN-01 -Phase before
# 双击 Setup → UAC 点"是" → 完成后应自动启动应用
pwsh -NoProfile -File $acc -Case UAC-ADMIN-01 -Phase after -ExitCode 0 -Status PASS
```

### 3.6 UAC-STD-01（标准账户 + 另一个管理员凭据）★核心

```powershell
# 先在 zs200（管理员）里 reset
pwsh -NoProfile -File $acc -Case UAC-STD-01 -Phase reset
# 注销 / 切换用户到 StandardTest，在 StandardTest 会话里执行 before
pwsh -NoProfile -File $acc -Case UAC-STD-01 -Phase before
# 用 StandardTest 双击 Setup → UAC 凭据框输入 AdminTest / Qx7!mVp2-Lk9a → 等待完成
pwsh -NoProfile -File $acc -Case UAC-STD-01 -Phase after -ExitCode 0 -Status PASS
```

**通过标准（三条必须同时成立）**：

```text
StandardTest: ShuoZhuang.PersonalPlanner 1.10.2.0 Status Ok
AdminTest:    安装前后登记集合不因本次测试新增目标包
LocalMachine\TrustedPeople: 9E157ECE… 存在，HasPrivateKey=False
```

在 `AdminTest` 会话里执行 `Get-AppxPackage ShuoZhuang.PersonalPlanner` 应为空。

### 3.7 UAC-OFFLINE-01（断网后首次安装）

```powershell
pwsh -NoProfile -File $acc -Case UAC-OFFLINE-01 -Phase reset
# 断开网络（禁用适配器或拔网线），确认 ping 不通
pwsh -NoProfile -File $acc -Case UAC-OFFLINE-01 -Phase before
# 双击 Setup → UAC 点"是"
pwsh -NoProfile -File $acc -Case UAC-OFFLINE-01 -Phase after -ExitCode 0 -Status PASS
```

### 3.8 UAC-UI-01（人为让辅助进程失败，界面必须报 `INSTALLER_ELEVATION_FAILED`）

需要"故障注入候选"（故意让辅助进程在连接前退出，**只用于本用例，不签、不发布**）。
拿到它之前这一例保持 `NOT RUN`。

```powershell
pwsh -NoProfile -File $acc -Case UAC-UI-01 -Phase reset
pwsh -NoProfile -File $acc -Case UAC-UI-01 -Phase before
# 双击注入候选 → UAC 点"是"
pwsh -NoProfile -File $acc -Case UAC-UI-01 -Phase after -ExitCode 31 -Status PASS
```

**通过标准**：页面显示 `INSTALLER_ELEVATION_FAILED`（"管理员授权步骤未完成"），
**不**显示"证书写入失败"；证书与包都不存在。

### 3.9 UAC-UPGRADE-02（1.10.1.0 → 1.10.2.0）

需要先把机器恢复成"装着 `1.10.1.0`、但证书尚未受信任"。**不要**用 `-Phase reset` 之后装
1.10.1，它会把刚装的包再卸掉；按下面顺序做：

```powershell
# ① 管理员窗口：先让证书受信任，才能侧载 1.10.1.0
Import-Certificate -FilePath 'C:\Users\zs200\signing\personal_planner.cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople
Get-AppxPackage ShuoZhuang.PersonalPlanner | Remove-AppxPackage
Add-AppxPackage 'C:\ProgramData\BestPlanningSetup-acceptance\old\BestPlanning_1.10.1.0_x64.msix'
(Get-AppxPackage ShuoZhuang.PersonalPlanner).Version      # 期望 1.10.1.0

# ② 再把证书移回去，恢复"未信任"前置
Remove-Item 'Cert:\LocalMachine\TrustedPeople\9E157ECE535D16A224593CA39C084705A4FD3C13' -Force

# ③ 取证 → 双击 Setup 点"是" → 取证
pwsh -NoProfile -File $acc -Case UAC-UPGRADE-02 -Phase before
pwsh -NoProfile -File $acc -Case UAC-UPGRADE-02 -Phase after -ExitCode 0 -Status PASS
```

**通过标准**：原位升级到 `1.10.2.0`，设置与业务数据保留。

## 4. 汇总与门禁

10 例（或全部 12 例）完成后：

```powershell
pwsh -NoProfile -File .\tool\uac_acceptance.ps1 -Phase report
pwsh -NoProfile -File .\tool\verify_release_assets.ps1 -Directory release-artifacts\1.10.2 -Version 1.10.2 -Build 51 -RequireSignature
```

`report` 会重算 Setup/MSIX 哈希与每个用例的日志、截图哈希并写回
`docs/testing/evidence/offline-installer-uac-broker-1.10.2.json`；任何一例不是 `PASS`、
路径为空或哈希不符，门禁都不会通过。

只有 12 项全部 `PASS` 时，才把
`docs/testing/offline-installer-uac-broker-acceptance.md` 顶部结论改成 `PASS`，
然后建 `v1.10.2` 并上传 `release-artifacts/1.10.2/` 的五个文件。

## 5. 收尾（测完建议恢复本机）

```powershell
# 恢复证书
Import-Certificate -FilePath 'C:\Users\zs200\signing\personal_planner.cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople
# 卸载测试版并回装 1.10.0.0（如需要）
Get-AppxPackage ShuoZhuang.PersonalPlanner | Remove-AppxPackage
Add-AppxPackage 'C:\ProgramData\BestPlanningSetup-acceptance\old\BestPlanning_1.10.0.0_x64.msix'
# 关闭测试账户 / UAC（关闭 UAC 需要再重启一次）
Remove-LocalUser AdminTest
Remove-LocalUser StandardTest
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' EnableLUA 0
```
