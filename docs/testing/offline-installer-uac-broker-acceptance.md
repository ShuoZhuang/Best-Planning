# 离线安装器 UAC broker 真人验收记录（1.10.2）

结论：NOT RUN
原因：`1.10.2+51` 候选已在本机 Windows 11 完成 9 项真人用例（含**标准账户跨凭据**、UAC 取消、
断网等价、证书已受信任、`1.10.0`/`1.10.1` 原位升级与同版本修复），矩阵仍缺
`UAC-ADMIN-02`/`UAC-STD-02`（Windows 10）、`UAC-CANCEL-02`（标准账户取消）与 `UAC-UI-01`
（故障注入候选），且 `UAC-STD-01` 缺截图。缺任一项即不得发布。

> 本文是**待执行的验收模板**，不是结果。任何一行都不允许在未实际执行的情况下填成
> `PASS`；`docs/testing/evidence/offline-installer-uac-broker-1.10.2.json` 必须与本文
> 逐项对应，且 `setupSha256` 必须是最终签名候选的哈希。
>
> 只有 12 项全部通过时，本文件的结论才允许改为 `PASS`；缺 Windows 10、标准账户或跨
> 凭据场景时保持 `NOT RUN` 或 `FAIL`，不得写 `PARTIAL PASS` 后继续发布。

日期：（待填）
修复计划：`docs/superpowers/plans/2026-10-18-offline-installer-uac-broker-repair.md`
**执行手册：`docs/testing/offline-installer-uac-broker-runbook.md`**（本机 Windows 11 的 10 例逐步操作、
`tool/uac_acceptance.ps1` 取证命令、本机改造与回滚方式）
修复规格：`docs/superpowers/specs/2026-10-18-offline-bootstrap-installer-design.md` §7.1、§8.1、§8.5、§9、§10、§12、§14、§16～§18
目标版本：`1.10.2+51` / MSIX `1.10.2.0` / Tag `v1.10.2`
执行账户：（待填：测试别名与账户类型，不写真实姓名）
UAC 授权账户：（待填：测试别名，不写密码）

## 1. 固定候选产物

本批候选已在开发机构建并签名（`tool\build_update_release.ps1 -Version 1.10.2 -Build 51
-MsixVersion 1.10.2.0`）。**重建即产生新候选，哈希随之改变，旧证据全部作废。**

| 项目 | 值 |
| --- | --- |
| 文件名 | `BestPlanning_Setup_1.10.2_x64.exe` |
| 字节数 | 19,020,120 |
| SHA-256 | `ec69dc9991bb487b14feb0eaef1f1fdc9a9381a3452fb1bb0a2a0f9b0d5746e6` |
| Authenticode 状态 | `Valid` |
| 时间戳证书 | `DigiCert SHA256 RSA4096 Timestamp Responder 2026 1` |
| 内嵌 MSIX SHA-256 | `de8af8f7ed05f78e60da36198b9276febd7841105c5983640814f9f5783791c9` |
| MSIX 版本 | `1.10.2.0`（18,575,088 字节，身份 `ShuoZhuang.PersonalPlanner`，x64） |
| 便携版 | `BestPlanning_Portable_1.10.2_x64.zip`（17,220,697 字节） |
| 清单 | `update-manifest.json`（1,275 字节） |
| 产物目录 | `release-artifacts/1.10.2/`（含 `SHA256SUMS.txt`） |
| 候选生成时间 | 2026-10-18 |

门禁现状：结构、版本、签名与哈希**全部通过**（`-SkipInstallerUacAcceptance` 时 `ok=true`）；
使用 `-RequireSignature` 的正常门禁**只剩**下面 §3 的 12 项 `NOT RUN`，因此发布保持阻断。

### 1.1 本次验收发现并已修复的额外缺陷（完成页按钮 / 退出码）

2026-10-18 第一次真实 GUI 安装（`UAC-UPGRADE-01`）暴露了两个**与 UAC 无关**的既有缺陷，
由本次验收发现并已修复：

| 现象 | 根因 | 修复 |
| --- | --- | --- |
| 安装成功页的「完成」按钮点不动，只能关窗口 | 次级按钮的点击语义按"进度条是否可见"判断；完成页同样显示 100% 进度条，于是「完成」被当成「取消」：按钮被禁用 + 只登记取消请求 + 永不解析界面等待 | 改按**页面**判断：只有 `UiPage::Progress` 的次级按钮是取消（`ClassifySecondaryClick`），并新增三个单元测试 |
| **安装成功但退出码是 `99`（`INSTALLER_INTERNAL_ERROR`）** | 用窗口 X 关闭时 `Ask` 返回 `None`，worker 正常返回 0，但对话框已销毁、`kWorkerDoneMessage` 不再发出，`Run()` 返回未更新的 `worker_result_`（初值 99） | worker 线程先写 `worker_exit_code_`（原子量），`Run()` 在 `join()` 之后返回它；关闭窗口不再吞掉真实退出码 |

实测证据：旧候选完成一次**成功**安装（包 `1.10.2.0`、证书已写入、日志 `result Installed`）后，
进程退出码为 `{"exit": 99}`。

影响面：任何 GUI 安装都会命中（成功也报 99），因此 `1.10.0` / `1.10.1` 的界面路径同样存在。
既有验收全部走 `--install-unattended` 的 headless 路径，所以此前从未暴露——这与 ROOT-06
是同一类问题：测试路径绕过了真实用户路径。

修复改的是 Setup 二进制，因此候选哈希改变（MSIX 未变，仍是 `de8af8f7…`）：

```text
旧候选（作废）BestPlanning_Setup_1.10.2_x64.exe  0060e7475a08d3eb484834412c9d762e71ee984244caa27c12da6c370295e5ed
新候选（当前）BestPlanning_Setup_1.10.2_x64.exe  ec69dc9991bb487b14feb0eaef1f1fdc9a9381a3452fb1bb0a2a0f9b0d5746e6
```

旧候选产生的一切证据（含已完成的 `UAC-UPGRADE-01`）**全部作废**，已删除并重跑。

## 2. 账户与前置状态

| 项目 | 值 |
| --- | --- |
| 管理员账户 | `AdminTest`（启用 UAC，已登录一次，配置文件可用） |
| 标准账户 | `StandardTest`（已登录一次，配置文件可用） |
| 测试前目标包 | 不得存在 `ShuoZhuang.PersonalPlanner 1.10.2.0` |
| 测试前发布证书 | 不在 `LocalMachine\TrustedPeople` |
| 发布证书指纹 | `9E157ECE535D16A224593CA39C084705A4FD3C13`（`CN=Shuo Zhuang, O=Personal User, C=CN`） |

## 3. 验收矩阵

每个用例都必须记录：实际结果、日志路径与 SHA-256、截图路径与 SHA-256、Setup 退出码、
`finalState`、安装前/后的包登记与证书状态。

| ID | 环境 | 发起账户 | UAC 行为 | 必须证明 | 实际结果 |
| --- | --- | --- | --- | --- | --- |
| UAC-ADMIN-01 | Windows 11 x64 稳定版 | 管理员过滤令牌 | 点"是" | 一次 UAC；证书写入；包安装给同一用户；启动成功 | PASS |
| UAC-ADMIN-02 | Windows 10 x64 受支持版 | 管理员过滤令牌 | 点"是" | 同上 | NOT RUN |
| UAC-STD-01 | Windows 11 x64 稳定版 | 标准账户 | 输入 `AdminTest` 凭据 | 证书机器级写入；包只登记给 `StandardTest`；管理员账户不新增登记 | PASS |
| UAC-STD-02 | Windows 10 x64 受支持版 | 标准账户 | 输入 `AdminTest` 凭据 | 同上 | NOT RUN |
| UAC-CANCEL-01 | Windows 11 | 管理员过滤令牌 | 点"否" | 退出码 10；证书不存在；包不存在；`finalState NotInstalled` | PASS |
| UAC-CANCEL-02 | Windows 11 | 标准账户 | 取消凭据框 | 与 UAC-CANCEL-01 相同 | NOT RUN |
| UAC-OFFLINE-01 | Windows 11 | 管理员过滤令牌 | 断网后点"是" | 完整安装和启动；没有网络请求依赖 | PASS |
| UAC-TRUSTED-01 | Windows 11 | 原安装用户 | 证书已存在 | 不弹 UAC；直接复验并安装/修复 | PASS |
| UAC-UPGRADE-01 | Windows 11 | 已装 1.10.0 | 正常授权（如需要） | 原位升级到 1.10.2；数据文件哈希/字段验收符合既有规格 | PASS |
| UAC-UPGRADE-02 | Windows 11 | 已装 1.10.1 | 正常授权（如需要） | 原位升级到 1.10.2；设置和业务数据保留 | PASS |
| UAC-REPAIR-01 | Windows 11 | 已装 1.10.2 | 选择修复 | 不先卸载，不清数据，最终登记仍为 `1.10.2.0` | PASS |
| UAC-UI-01 | Windows 11 | 任一未信任账户 | 人为触发 helper 失败候选 | 页面显示 `INSTALLER_ELEVATION_FAILED`，不显示证书已尝试写入 | NOT RUN |

### 3.1 进度（2026-10-18 本机实测）

已执行并在本文件 §1 候选上取得证据：**9 项 PASS**
（`UAC-ADMIN-01`、`UAC-STD-01`、`UAC-CANCEL-01`、`UAC-OFFLINE-01`、`UAC-TRUSTED-01`、
`UAC-UPGRADE-01`、`UAC-UPGRADE-02`、`UAC-REPAIR-01`、`UAC-UI-01`）。

仍阻断发布的 4 项：

| 项 | 原因 | 解除方式 |
| --- | --- | --- |
| `UAC-ADMIN-02` | 需要 Windows 10 环境 | 装 Win10 虚拟机后重跑 |
| `UAC-STD-02` | 需要 Windows 10 环境 | 同上 |
| `UAC-CANCEL-02` | 需要标准账户会话（本机可做，本次未执行；临时测试账户已按用户要求删除） | 在最终矩阵里用 VM 重跑 |
| `UAC-STD-01` | 功能已证实（包只登记给 `StandardTest`、`AdminTest` 无新增、证书机器级写入），但该会话未运行取证脚本，**缺少截图** | 在最终矩阵里用工具重采 |

`UAC-UI-01` 的实测细节（故障注入候选，辅助进程连接前 `exit 4`）：

```text
elevation launch succeeded pid=60200
elevation helper exited code=4
elevation channel failed status=elevated-child-exited win32=0
failure INSTALLER_ELEVATION_FAILED detail=elevated-child-exited exit=4
result FAILED_BEFORE_CHANGE
finalState NotInstalled
```

即：立即诊断出子进程退出（未等 180 秒超时）、**没有**误报 `pipe-connect-timeout`、界面报
`INSTALLER_ELEVATION_FAILED` 而不是证书写入失败，证书与包都不存在（退出码 31）。
故障注入候选只用于该用例：未签名、放在 `C:\ProgramData\BestPlanningSetup-acceptance\inject\`，
**不在** `release-artifacts/` 里，也不进入任何发布产物。

关于 `UAC-STD-01` 的实测细节：日志 14:12:31 请求提权 → 14:12:52 才连上（21 秒即输入
`AdminTest` 凭据的时间），随后 `protocol=2`、`clientPid` 匹配、`certificate imported`、
`installed 1.10.2.0`；提权查询结果为
`StandardTest=1.10.2.0 Ok`、`AdminTest=[]`、`zs200=[]`，
`TrustedPeople` 存在 `9E157ECE…` 且 `HasPrivateKey=False`。
## 4. 每个用例的取证清单

- [ ] 安装前 `whoami` 的测试别名和账户类型
- [ ] 安装前目标包查询结果（`Get-AppxPackage ShuoZhuang.PersonalPlanner`）
- [ ] 安装前证书指纹查询结果（`Cert:\LocalMachine\TrustedPeople`）
- [ ] UAC 前、授权后、最终页面截图（三张，含窗口标题与时间）
- [ ] Setup 日志原文件及其 SHA-256
- [ ] 安装后原始用户的包版本和状态
- [ ] 标准账户场景中管理员账户的包登记对比（安装前后集合）
- [ ] 最终证书指纹、存储位置、`HasPrivateKey`
- [ ] Setup 退出码与 `finalState`

## 5. 普通用户安装归属（UAC-STD-01/02 硬条件）

```text
StandardTest: ShuoZhuang.PersonalPlanner 1.10.2.0 Status Ok
AdminTest: 安装前后登记集合不因本次测试新增目标包
LocalMachine\TrustedPeople: 固定指纹存在，HasPrivateKey=false
```

任一条件不满足即 `FAIL`。不能用"安装器显示成功"替代系统查询。

## 6. 自动化证据（已执行，2026-10-18，不是真人证据）

以下结果来自修复实现后的本机回归。它们证明**代码路径**与**错误语义**，**不能**替代 §3 的
任何一项。

| 项目 | 命令 | 实际结果 |
| --- | --- | --- |
| 原生单元测试（Debug） | `installer\build\Debug\installer_tests.exe --certificate <cer>` | `65 tests, 0 failures`，exit 0 |
| 原生单元测试（Release） | `installer\build\Release\installer_tests.exe --certificate <cer>` | `65 tests, 0 failures`，exit 0 |
| Setup 自检 | `BestPlanningSetup.exe --selftest` | `selftest ok`（见下方环境说明） |
| 组件测试 | `& tool\installer_tests.ps1 -SkipBuild -Msix release-artifacts\1.10.2\BestPlanning_1.10.2.0_x64.msix` | `ok=true`、`failures=[]`、`tests=20`；`IPC-AUTO-01/02/03` 均 `exit=2` 且发布证书状态不变 |
| 门禁（结构 + 签名） | `-Directory release-artifacts\1.10.2 -Version 1.10.2 -Build 51 -SkipInstallerUacAcceptance` | `ok=true`；`setupSha256` 与 §1 一致（显式跳过只用于非签名开发验证，且 `-RequireSignature` 时被拒） |
| 门禁（正式口径） | `-Directory release-artifacts\1.10.2 -Version 1.10.2 -Build 51 -RequireSignature` | 结构与签名全部通过，只剩 4 项真人用例待补（2 项 Win10、1 项标准账户取消、1 项缺截图） → 发布阻断 |
| 门禁负例 | `& tool\installer_uac_gate_tests.ps1` | 对照用例通过；缺文件 / 版本不符 / Setup 哈希不符 / 用例缺失 / 重复 ID / `NOT RUN` / 日志哈希不符 **七项全部被拒绝**（exit 1） |
| 静态分析 | `flutter analyze` | `No issues found!`，exit 0 |
| Flutter 全量测试 | `flutter test` | `All tests passed!`（2933 项），exit 0 |
| 禁止残留 | `rg -n "ParentIsSameExecutable\|TH32CS_SNAPPROCESS" installer\src installer\include` | 无匹配 |
| 管道创建标志 | `rg -n "PIPE_ACCESS_DUPLEX" installer\src\elevation_broker.cpp` | 同一表达式含 `FILE_FLAG_FIRST_PIPE_INSTANCE` 与 `FILE_FLAG_OVERLAPPED`；pipe mode 含 `PIPE_REJECT_REMOTE_CLIENTS` |

环境说明（测试环境限制，**不是安装器功能缺陷**，也**不能**据此认定缺陷已修好）：

- **`installer_tests.ps1` 必须用 PowerShell 7 执行**（文件是无 BOM 的 UTF-8；Windows
  PowerShell 5.1 会按 ANSI 解码中文，报成"缺少 }"之类的解析错误）：

  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\tool\installer_tests.ps1
  ```

  该脚本本身会把被测 EXE 暂存到工作区之外，所以正常情况下只需要这一条命令。
- **手动跑 `--selftest` 时先把 EXE 复制到仓库与工作树之外**：仓库内的进程受文件沙箱限制，
  无法在系统临时目录建目录，`SecureSession` 会以 `session created` 失败。

  ```powershell
  $stage = Join-Path $env:LOCALAPPDATA 'BestPlanningSetup\manual-selftest'
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Copy-Item .\installer\build\Debug\BestPlanningSetup.exe $stage -Force
  & (Join-Path $stage 'BestPlanningSetup.exe') --selftest
  ```

  输出 `selftest ok` 即认定自检通过。在仓库内直接运行会看到
  `FAIL session created / session write / session read back`（exit 1），那是环境限制。
- **本机无法替代真人验收**：候选 Setup 的 `--plan` 报 `certificateTrusted: true`、
  `wouldRequestElevation: false`（发布证书 `9E157ECE…` 已在本机
  `LocalMachine\TrustedPeople`），一次真实的 UAC 授权路径在本机根本不会被走到——这正是
  `1.10.0` / `1.10.1` 在开发机上测不出来的原因（ROOT-06）。**自动化全绿不等于
  `pipe-connect-timeout` 已在真实设备上消失**；只有 §3 的干净环境与标准账户场景能证明。
- 候选 Setup 的只读自检结果：`--version` = `1.10.2+51`，`--verify-embedded` 的
  `packageSha256` 与 MSIX 一致，`--selftest` = `selftest ok`，`--plan` 报
  `action: upgrade`、`installedVersion: 1.10.0.0`（本机当前登记版本）。

## 7. 需求 → 证据映射（计划 §6）

| Requirement | 自动化证据 | 真人证据 | 状态 |
| --- | --- | --- | --- |
| 管道真正使用 overlapped 模式 | `elevation_channel_connects_expected_client`、`elevation_channel_round_trips_message_over_overlapped_handles`、`elevation_channel_times_out_and_cancels_io` + 源码审计 | UAC-ADMIN-01/02 | 自动化 PASS；真人 NOT RUN |
| 子进程提前退出立即可诊断 | `elevation_channel_reports_child_exit_code`、`broker_maps_child_exit_to_elevation_failed` | UAC-UI-01 | 自动化 PASS；真人 NOT RUN |
| 客户端 PID 绑定 | `elevation_channel_rejects_unexpected_client_pid`、`broker_rejects_client_pid_mismatch_before_ack` | IPC-AUTO-05 | 自动化 PASS |
| pipe/nonce 强绑定 | `elevated_args_accept_exact_pipe_nonce_pair` 等七项、`IPC-AUTO-01/02/03` | UAC-ADMIN-01 日志 `protocol=2` | 自动化 PASS；真人 NOT RUN |
| 摘要/协议不符时不写证书 | `broker_rejects_handshake_protocol_mismatch`、`broker_rejects_handshake_digest_mismatch` | IPC-AUTO-07/08 | 自动化 PASS |
| UAC 拒绝无系统改变 | `controller_preserves_elevation_failed` + `error_descriptions_match_exit_codes` | UAC-CANCEL-01/02 | 自动化 PASS；真人 NOT RUN |
| 管理员一次授权安装 | `broker_*` 与 `elevation_channel_*` | UAC-ADMIN-01/02 | 自动化 PASS；真人 NOT RUN |
| 标准账户跨凭据仍装给原用户 | 无法由单元测试证明 | UAC-STD-01/02 | **NOT RUN** |
| 断网首次安装 | `--verify-embedded` 内嵌资源自检（组件测试第 2 组） | UAC-OFFLINE-01 | 自动化 PASS；真人 NOT RUN |
| 已信任证书不重复 UAC | `installer_controller.cpp` 的 `certificate_trusted_` 分支（`elevation skipped` 仅在已提权时） | UAC-TRUSTED-01 | 无专用单元测试；真人 NOT RUN |
| 旧版升级保留数据 | 既有部署/数据测试 | UAC-UPGRADE-01/02 | 真人 NOT RUN |
| 同版本修复不卸载 | `version_policy_test` | UAC-REPAIR-01 | 自动化 PASS；真人 NOT RUN |
| 错误界面不误称证书已写入 | `elevation_failed_copy_does_not_claim_certificate_write`、`certificate_import_failed_copy_requires_attempted_write` | UAC-UI-01 | 自动化 PASS；真人 NOT RUN |
| 最终证据绑定发布文件 | `tool\installer_uac_gate_tests.ps1` 七项负例 | JSON 中 `setupSha256` | 自动化 PASS |

## 8. 安全审计记录（计划 Task 8 Step 4）

逐项核对，均以源码为准：

| 审计项 | 结论 | 依据 |
| --- | --- | --- |
| 不存在 PID/nonce/摘要验证前发送 `accepted` 的路径 | 通过 | `RequestCertificateTrust` 先 `WaitForExpectedElevationClient`（含 PID 核对），再 `ReadElevationMessage`，只有 `ValidateElevationHandshakeRequest` 返回真时才写 `ok=true` |
| 辅助进程不接受路径、脚本、存储区或任意命令 | 通过 | `ParseElevatedSessionArguments` 只接受 `--elevated-session --pipe <name> --nonce <hex>`；其余一律 `unknown-argument`；证书存储区在 `TrustCertificate` 内固定为 `LocalMachine\TrustedPeople` |
| DACL 没有扩大 | 通过 | SDDL 仍为 `(A;;GA;;;<当前用户 SID>)(A;;GA;;;SY)(A;;GA;;;BA)`；新增的是 `PIPE_REJECT_REMOTE_CLIENTS` |
| 每个 HANDLE/事件/管道/未完成 I/O 在所有 return 路径关闭或取消 | 通过 | `ManualEvent` 是 RAII；超时/等待失败/子进程退出都先 `CancelIoEx`；broker 每条失败路径都恰好关闭一次 `hProcess` 与管道 |
| `TerminateProcess` 只发生在证书写入尚未开始的 pre-ACK 阶段 | 通过 | 仅 `DecideElevationFailure().terminate_helper` 为真时调用；`ChildExited` 时为假；ACK `accepted` 之后没有任何终止调用 |
| 标准账户跨凭据路径仍由普通进程部署 MSIX | 通过（代码） | 辅助进程只调用 `TrustCertificate`；`DeployPackage` 只在普通权限的 `RunInteractive` 中执行。真人归属仍需 UAC-STD-01/02 |
| 日志 detail 不泄露 nonce、凭据或用户数据 | 通过 | detail 只含稳定状态 token、PID、退出码与 Win32 错误码；`LogTrustOutcome` 不写命令行为管道名 |

## 9. 失败处理

- 任一用例 `FAIL`：不创建 `v1.10.2` 正式 Tag；修复后重建候选并产生新的 Setup SHA-256，
  旧证据全部作废。
- `GetNamedPipeClientProcessId` 在最低支持系统失败：记录 Win32 错误并停止发布，
  **不得**退回父 PID 判断。
- 标准账户跨凭据安装给了管理员账户：视为安全与数据归属失败，不得只修文案。
