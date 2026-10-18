# 离线单文件安装器验收记录

日期：2026-10-18
依据：`docs/superpowers/specs/2026-10-18-offline-bootstrap-installer-design.md`（下称"规格"）
实施计划：`docs/superpowers/plans/2026-10-18-offline-bootstrap-installer-implementation-plan.md`
目标版本：`1.10.0+47` / MSIX `1.10.0.0`

结论（规格 §18 口径）：**代码完成，发布验收未完成。**
自动化测试、真实构建、签名与门禁、以及一次真实的 `1.9.0.0 → 1.10.0.0` 原位升级都已完成；
Windows 10 与干净虚拟机矩阵、标准账户输入管理员凭据、以及故障注入矩阵尚未执行。

## 1. 环境

| 项目 | 值 |
| --- | --- |
| 系统 | Windows 11 x64 build 26200 |
| 会话 | 管理员（`ZS的ASUSROG\zs200`） |
| 安装前版本 | `ShuoZhuang.PersonalPlanner 1.9.0.0`（Status Ok） |
| 证书状态 | `9E157ECE535D16A224593CA39C084705A4FD3C13` 已在 `LocalMachine\TrustedPeople` |
| 用户数据 | `F:\Documents\personal_planner.sqlite`，569,344 字节 |

## 2. 构建与签名

| 产物 | 大小 | SHA-256 |
| --- | ---: | --- |
| `BestPlanning_Setup_1.10.0_x64.exe` | 19,004,248 | `396a3b0879858d8a0807fc0cff64650b57fc3b9e46cca43b56d79f157d78946f` |
| `BestPlanning_Portable_1.10.0_x64.zip` | 17,212,031 | `d04b0251632d626c1c670180e73071275ceddde7a5958a7ab02f4d579f6119a5` |
| `BestPlanning_1.10.0.0_x64.msix` | 18,566,202 | `5b710d1c388a6db6adddc13337c5a8baa0444c81d75c49ebac6346b64a9905a5` |
| `update-manifest.json` | 1,275 | `8f794c28d3df1dd5c60fb02a5ac9022cd1992094b6fe02f51543b4a8167e4154` |

- Setup 的 Authenticode 状态为 `Valid`，时间戳为 `DigiCert SHA256 RSA4096 Timestamp Responder 2026 1`。
- 先嵌入资源、后签名；签名之后文件未再被修改（§8.7）。
- 发布门禁（`tool/verify_release_assets.ps1 -RequireSignature`）：通过，`problems: []`。
  检查项包含文件名、Setup 文件版本、内嵌载荷、MSIX 身份/版本/架构/哈希、清单字段、
  `SHA256SUMS.txt` 覆盖与哈希、便携版内容、签名与时间戳。

## 3. 自动化测试

### 3.1 单元测试（`installer_tests.exe`，36 项）

```text
36 tests, 0 failures
```

覆盖：版本解析/比较/降级判定、身份与发布者/包族名派生、元数据校验（schema、身份、
发布者、架构、哈希格式、大小、版本）、状态机合法与非法跳转、终止状态、取消点、关键段、
退出码常量、错误码文案与退出码映射、共享稳定码映射、部署错误转换、证书解析（主题/指纹/
公钥/有效期）、不同证书不同指纹、空证书拒绝、证书存储可查询、证书回收判定、
真实 MSIX 的载荷校验（通过）、追加字节（大小不符）、篡改字节（哈希不符）、替换证书
（签名者不符）、版本不符、文件缺失、证书元数据不符。

### 3.2 组件测试（`tool/installer_tests.ps1`，10 组）

| 用例 | 期望 | 实测 |
| --- | --- | --- |
| 真实 MSIX 的 `--selftest` | 0 | 0 |
| 真实 Setup 的 `--verify-embedded` | 0 且哈希/包族名一致 | 通过 |
| `--plan` 不改变已安装版本 | 版本不变 | 通过 |
| 元数据哈希被改 | 30 | 30 |
| 内嵌 MSIX 被篡改 | 30 | 30 |
| 资源里换成另一张证书 | 30 | 30 |
| 证书与元数据自洽但不是签名者 | 30 | 30 |
| 元数据身份错误 | 30 | 30 |
| 无效提权会话（错误 nonce） | 非 0，且不写证书 | 非 0（握手前退出） |
| 普通流程不含 PowerShell/cmd | 二进制与源码均无 | 通过 |

## 4. 真实部署证据（本机，管理员会话）

### 4.1 `--plan`（不写系统）

```json
{"ok":true,"targetVersion":"1.10.0.0","appVersion":"1.10.0+47",
 "certificateTrusted":true,"wouldRequestElevation":false,
 "action":"upgrade","installedVersion":"1.9.0.0",
 "aumid":"ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner"}
```

### 4.2 原位升级 `1.9.0.0 → 1.10.0.0`

`--install-unattended`（同一控制器与状态机，仅不显示窗口）退出码 `0`，日志节选（来自 P0 落盘修复**之前**的构建；表 2 的哈希是最终产物，两者行为路径相同）：

```text
state INITIALIZING -> PREFLIGHT_CHECK
preflight ok build=26200
state PREFLIGHT_CHECK -> EXTRACTING
extracted payload bytes=18543445
state EXTRACTING -> VERIFYING_PAYLOAD
payload verified sha256=bc25798f9467cbac4fb7edee039a775b42a9341aaf8d1865e50026e464e955c7
certificate already trusted
state VERIFYING_PAYLOAD -> DEPLOYING_PACKAGE
state DEPLOYING_PACKAGE -> VERIFYING_INSTALLATION
installed 1.10.0.0 ShuoZhuang.PersonalPlanner_1.10.0.0_x64__v9555qkaxdyym
state CLEANING_UP -> COMPLETED
result Installed version=1.10.0.0
finalState Installed
```

安装后查询：`Version 1.10.0.0`、`Status Ok`。

数据保留（§16.4 的机器可核对部分）：

| 项目 | 安装前 | 安装后 |
| --- | --- | --- |
| 数据库大小 | 569,344 | 569,344 |
| 数据库 SHA-256 | `5f5a5c8bba2a7299e6ee7701211c1b2d90bdf368d84225c4a242095843d0fce0` | 相同 |
| 数据库修改时间 | 2026-10-18T16:15:35.3521683+08:00 | 相同 |
| 证书 | 已信任 | 仍信任（未重复导入） |

> **关于构建版本**：这次升级使用本轮同一份源码构建的 Setup；之后源码只增加了两个**无界面**
> 验收开关（`--launch` / `--reinstall`），部署与校验路径未改。最终签名的
> `BestPlanning_Setup_1.10.0_x64.exe`（`101e8422…`）已经重新执行过真实部署
> （§4.4 重新安装、§4.5 证书导入）以及内嵌自检与发布门禁。

> 逐项业务字段（任务、课程、保护时间、偏好、特殊日）的核对需要应用内验收，本记录只证明
> 安装过程没有触碰数据库文件。

### 4.3 相同版本：启动

`--install-unattended --launch` 退出码 `0`。日志：

```text
same-version detected 1.10.0.0
state PREFLIGHT_CHECK -> COMPLETED
launch-only completed
```

应用进程被 AUMID 启动（窗口标题「优计主义」），证明 AUMID 来自实际登记结果。

### 4.4 相同版本：重新安装

`--install-unattended --reinstall` 退出码 `0`。日志包含：

```text
same-version reinstall requested
deploying (same-version reinstall)
installed 1.10.0.0
finalState Installed
```

重新安装没有先卸载，也没有清除数据。

### 4.5 证书信任链：导入后复验

移除 `LocalMachine\TrustedPeople` 中的发布证书后：

- `--plan` 输出 `certificateTrusted=false`、`wouldRequestElevation=true`；
- `--install-unattended --reinstall`（会话本身已是管理员，因此跳过无意义的 UAC）退出码 `0`：

```text
certificate not trusted yet
state VERIFYING_PAYLOAD -> REQUESTING_ELEVATION
elevation skipped: process already elevated
state REQUESTING_ELEVATION -> TRUSTING_CERTIFICATE
certificate imported
state TRUSTING_CERTIFICATE -> REVERIFYING_PAYLOAD
payload re-verified with trusted chain
state REVERIFYING_PAYLOAD -> DEPLOYING_PACKAGE
installed 1.10.0.0
```

- 结束后证书重新出现在 `TrustedPeople`，且只写入了这一张。

### 4.6 拒绝降级

用同一套代码为 `1.9.1.0` 生成 Setup，`--plan` 退出码 `60`：

```json
{"ok":false,"errorCode":"INSTALLER_DOWNGRADE_REJECTED","detail":"installed 1.10.0.0 > target 1.9.1.0"}
```

## 5. 本轮发现并修复的问题

| 问题 | 现象 | 修复 |
| --- | --- | --- |
| 资源写入参数顺序写反 | 载荷写成了"类型=101、名字=10"，安装器读不到 | `UpdateResourceW(h, RT_RCDATA, MAKEINTRESOURCEW(101), …)` |
| `GetSecurityDescriptorDacl` 传入 NULL | 在设置目录 ACL 时访问冲突（本机实测） | 传真实的 `BOOL defaulted` 变量 |
| 待重启判定过宽 | 本机有 14,814 条 `PendingFileRenameOperations`，安装被误判为"需要重启"（exit 42） | 只认 CBS `RebootPending` 与 WU `RebootRequired` |
| 开发机文件沙箱 | 仓库内的进程无法在系统临时目录建目录，测试出现假失败 | 所有验收脚本把被测 EXE 暂存到仓库外再运行 |
| 会话令牌可被重复签发清空 | 第二次 `IssueToken` 清掉已签发的令牌 | 已签发时直接返回空，不再清空 |
| 同版本"重新安装"名不副实 | `ForceUpdateFromAnyVersion` 返回成功但**不替换**已安装文件 | 改为**修复安装**（`RegisterPackageByFullNameAsync` 重新登记），界面与 README 写明不替换文件；真实安装态验证退出码 0、版本与文件均不变 |

## 6. 未执行项（`NOT RUN`）

- Windows 10（最新受支持版本）真实部署矩阵。
- Windows 11 干净虚拟机与快照。
- **标准账户输入管理员凭据**、验证"包仍安装给发起用户"。
- 交互式 UAC 弹窗路径（本会话本身已是管理员，走的是"已提权直接导入"分支）。
- 故障注入：UAC 被拒绝、证书写入失败、应用未关闭时的界面等待、部署中途失败、
  虚拟机强制中止、AUMID 查询失败、自动启动失败、磁盘空间不足、临时目录不可写、
  GitHub 限流与下载中断（后两项属于应用内更新，见另一份验收记录）。
- 图形界面的截图证据（本轮真实部署使用 `--install-unattended`，界面只做了编译与代码复核）。

## 7. 下一步（发布前必须完成）

1. 在 Windows 10 与 Windows 11 干净虚拟机上执行规格 §16.3 的矩阵，包含标准账户场景。
2. 按规格 §16.5 逐项执行故障注入，并记录用户提示、系统改变、旧版状态、证书状态与退出码。
3. 完成应用内数据逐项核对（§16.4）。
4. 采集准备页/等待关闭/进度/完成/错误五类界面的真实截图。
5. 上述证据齐备之前，不得把本版本标记为"正式完成"（规格 §18）。
