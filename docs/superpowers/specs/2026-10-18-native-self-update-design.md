# 优计主义 Windows 原生自更新系统设计

日期：2026-10-18

状态：设计已逐节确认，等待书面规格复核

目标首发版本：1.9.0

自动升级演练版本：1.9.1

## 1. 文档目的

本文定义优计主义 Windows MSIX 版本的完整自更新子系统。它取代现有“查询 GitHub Release 后打开网页”的检查器，建立一条可恢复、可审计的完整链路：

```text
固定签名清单
→ 判断版本
→ 后台自动下载
→ 完整性与发布者校验
→ 左下角显示更新入口
→ 用户点击
→ 主程序安全退出
→ 独立更新助手执行 MSIX 原位升级
→ 启动新版
→ 新版健康确认
→ 清理或失败回退
```

本文是架构规格，不授权直接修改产品代码。后续必须先依据本文编写实施计划，再按计划开发和验证。

## 2. 用户目标与成功标准

### 2.1 用户目标

用户需要的不是“发现新版后打开 GitHub”，而是：

1. 软件联网后自动检查稳定版更新。
2. 发现新版本后自动在后台下载，不弹窗、不打开浏览器。
3. Wi-Fi、有线网络、手机热点和计费网络均可自动下载。
4. 下载并验证完成后，在软件左下角显示一个更新图标。
5. 用户点击图标后直接更新，不再出现第二个确认窗口。
6. 用户不点击时，不自动安装、不退出软件、不反复提醒。
7. 存在未保存编辑时，更新入口保留但禁用，并在界面内说明原因。
8. 更新失败不能损坏当前版本或丢失任务、日程、课程、设置等数据。
9. 正常流程不使用应用弹窗或 Windows 通知。
10. 专注功能不参与更新阻塞判断，不增加专门分支。

### 2.2 成功标准

完整功能只有同时满足以下条件才算完成：

- 不再依赖 GitHub Releases API 判断最新版。
- 请求失败、限流、空响应和无缓存的 `304` 不会显示“已经是最新版”。
- 新版本能够在任意网络上自动下载并断点续传。
- 清单、文件哈希、MSIX 签名、发布者和包身份均通过校验。
- 下载完成后左下角入口稳定可见。
- 点击入口后主程序安全退出并完成 MSIX 原位升级。
- 新版本按真实 AUMID 启动并完成健康确认。
- 安装失败保留旧版本；启动失败在满足安全条件时恢复旧版本和更新前数据。
- Windows 10、Windows 11真实升级矩阵通过。
- 发布流水线自动生成并验证清单，测试产物与发布产物一致。

## 3. 当前实现与已确认问题

### 3.1 当前版本事实

撰写本文时，项目配置为：

| 项目 | 当前值 |
| --- | --- |
| Flutter版本 | `1.8.1+45` |
| MSIX版本 | `1.8.1.0` |
| 包身份 | `ShuoZhuang.PersonalPlanner` |
| Publisher | `CN=Shuo Zhuang, O=Personal User, C=CN` |
| Package Family Name | `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` |
| AUMID | `ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner` |
| 架构 | x64 |

上述包身份、Publisher、包族名和 AUMID 是现有用户数据容器与覆盖升级的稳定边界，不能在本功能中改变。

### 3.2 当前更新链路

当前实现主要位于：

- `lib/platform/update/github_release_client.dart`
- `lib/application/update_service.dart`
- `lib/domain/models/app_update.dart`
- `lib/features/settings/update/update_page.dart`

它具有以下缺口：

1. 使用匿名 GitHub Releases API，会受到每个出口 IP 每小时额度限制。
2. `304 Not Modified` 返回空 Release 列表，调用层可能将其解释成“没有更新”。
3. 版本解析依赖 Tag 格式，项目曾使用的 `v1.8.1-build45` 无法按标准版本处理。
4. 更新页只检查版本并打开 GitHub，不下载、不校验、不安装。
5. 没有统一持久化状态机、断点续传、安装助手、健康检查和回退。
6. 网络失败与“确认无更新”没有被完全隔离，存在假成功风险。

### 3.3 架构结论

采用“签名结构化清单 + 后台下载器 + 独立原生更新助手”。不采用：

- 继续扩展 GitHub Releases API 解析；
- 只依赖 `.appinstaller` 的系统交互；
- 下载后打开系统安装器让用户继续点击；
- PowerShell、批处理或动态脚本更新；
- 主程序在自身进程内覆盖安装。

## 4. 范围与非目标

### 4.1 本期范围

- Windows x64 MSIX 稳定通道。
- 固定更新清单。
- 清单签名和严格解析。
- 自动检查和任意网络自动下载。
- ETag缓存、断点续传、磁盘检查和重试退避。
- MSIX多层校验。
- 全局左下角更新入口。
- 独立 C++/WinRT 更新助手。
- 主程序安全退出、数据快照、健康确认和受控回退。
- Release生成、签名、上传和发布门禁。
- 更新诊断、错误分类和完整测试矩阵。

### 4.2 非目标

- Microsoft Store更新通道。
- macOS、Linux、Android或iOS更新。
- Beta、Nightly或多通道灰度发布。
- 强制更新。
- 静默自动安装。
- 更新时修改或导入系统根证书。
- P2P分发、差分补丁或自建下载服务器。
- 为专注功能增加更新保护逻辑。
- 在本期设计远程遥测或上传诊断数据。

## 5. 总体架构

### 5.1 组件

系统由以下组件构成：

1. **UpdateManifestRepository**：读取固定清单、处理缓存和 `304`。
2. **UpdateManifestVerifier**：严格解析结构并验证 Ed25519签名。
3. **UpdateOrchestrator**：唯一业务编排入口，推进状态机。
4. **UpdatePackageDownloader**：后台下载、断点续传和重试。
5. **UpdatePackageVerifier**：验证大小、SHA-256、MSIX签名和包身份。
6. **UpdateStateStore**：在业务数据库之外原子保存更新状态。
7. **UpdateSafetyCoordinator**：汇总未保存内容和不可中断写入状态。
8. **UpdateIndicator**：左下角图标及非模态状态卡片。
9. **WindowsUpdateBridge**：读取包身份、调用平台验证并启动助手。
10. **NativeUpdateHelper**：主程序退出后执行部署、启动、健康等待和回退。
11. **UpdateReleasePipeline**：生成、签名、验证和发布正式产物。

### 5.2 依赖方向

```text
UI
↓
UpdateOrchestrator
↓
领域模型与端口
↓
HTTP / 文件 / Windows 平台实现
↓
NativeUpdateHelper
```

领域模型不得依赖 Flutter、HTTP、文件系统或 Windows API。界面不得自行请求 GitHub、比较版本或拼接安装命令。

### 5.3 唯一事实源

- 当前安装版本：Windows包身份和版本信息。
- 最新稳定版本：经过签名验证的远端清单。
- 下载状态：`UpdateStateStore`。
- 安装结果：Windows包部署状态与实际已安装版本。
- 健康结果：新版本生成的健康确认。

任何缓存和界面字段都只是这些事实的投影。

## 6. 更新清单协议

### 6.1 地址

稳定版最新清单：

```text
https://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json
```

指定版本不可变清单：

```text
https://github.com/ShuoZhuang/Best-Planning/releases/download/v{SemVer}/update-manifest.json
```

最新清单用于发现目标版本；指定版本清单用于建立当前版本回退基线和审计历史。

### 6.2 信封结构

清单采用签名信封：

```text
root
├── payload
│   ├── schemaVersion
│   ├── channel
│   ├── release
│   ├── compatibility
│   ├── package
│   ├── presentation
│   └── revokedVersions
└── signature
    ├── algorithm
    ├── keyId
    └── value
```

签名规则固定为：

1. 按 RFC 8785 JSON Canonicalization Scheme 规范化 `payload`。
2. 对规范化后的 UTF-8字节使用 Ed25519签名。
3. `signature.algorithm` 必须等于 `Ed25519`。
4. `signature.keyId` 必须在客户端内置允许集合中。
5. Schema 1对未知字段采取严格拒绝，协议扩展必须提升 `schemaVersion`。

### 6.3 字段契约

| 字段 | 类型与约束 |
| --- | --- |
| `payload.schemaVersion` | 整数，首版固定为 `1` |
| `payload.channel` | 字符串，首版固定为 `stable` |
| `release.version` | 标准三段 SemVer，例如 `1.9.0` |
| `release.buildNumber` | 单调递增正整数 |
| `release.msixVersion` | 四段 Windows包版本，例如 `1.9.0.0` |
| `release.tag` | 必须严格等于 `v{release.version}` |
| `release.publishedAtUtc` | ISO 8601 UTC时间 |
| `compatibility.architecture` | 首版固定为 `x64` |
| `compatibility.minimumWindowsBuild` | 四段 Windows版本 |
| `compatibility.packageIdentityName` | 固定为 `ShuoZhuang.PersonalPlanner` |
| `compatibility.packageFamilyName` | 固定为 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` |
| `compatibility.publisher` | 固定为当前 Publisher全文 |
| `package.fileName` | 与实际 Release Asset完全一致 |
| `package.downloadUrl` | 指向同仓库、同 Tag、同文件名的不可变 URL |
| `package.sizeBytes` | 构建产物生成的正整数 |
| `package.sha256` | 构建产物生成的64位小写十六进制摘要 |
| `presentation.title` | 纯文本标题 |
| `presentation.summary` | 纯文本摘要，长度受限 |
| `presentation.releaseUrl` | 同仓库对应 Release页面 |
| `revokedVersions` | 可空数组，元素为四段 MSIX版本 |
| `signature.algorithm` | `Ed25519` |
| `signature.keyId` | 已登记签名公钥标识 |
| `signature.value` | Base64编码签名 |

展示文本只作为纯文本渲染，禁止注入 HTML、Markdown脚本或任意链接协议。

### 6.4 地址与重定向限制

- 初始清单和包地址必须是 `https://github.com/ShuoZhuang/Best-Planning/` 下的允许路径。
- 最多跟随5次重定向。
- Release Asset允许重定向至 GitHub官方资产域名，例如 `release-assets.githubusercontent.com`。
- 不允许重定向到非 HTTPS、IP字面量、其他仓库或未知域名。
- 包最终仍必须通过清单哈希和 MSIX签名验证；域名允许列表不能替代内容验证。

### 6.5 Release命名

| 项目 | 规则 | 示例 |
| --- | --- | --- |
| Tag | `v主.次.修订` | `v1.9.0` |
| Release标题 | 可读文本，不参与判断 | `Best Planning 1.9.0` |
| Flutter版本 | `主.次.修订+构建号` | `1.9.0+46` |
| MSIX版本 | 四段数字 | `1.9.0.0` |
| MSIX文件名 | 确定性命名 | `BestPlanning_1.9.0.0_x64.msix` |
| 清单文件名 | 固定 | `update-manifest.json` |

`v1.9.0-build46`、`release-1.9.0`、`1.9-latest` 等格式不得用于新协议正式版。

### 6.6 版本判断

最终是否可更新只按 Windows包版本判断：

```text
候选 msixVersion > 当前已安装 msixVersion
```

SemVer、Tag、build number、文件名和 MSIX内部 Identity Version必须互相一致；它们用于验证，不得各自独立触发安装。相同版本判为已安装，较低版本判为降级并拒绝。

## 7. 检查、缓存与网络策略

### 7.1 检查时机

- 启动约10秒后执行一次后台检查。
- 运行期间距离上次成功检查超过24小时时检查。
- 网络从不可用变为可用时，经防抖后检查。
- 用户在设置页点击“立即重新检查”时检查。
- 下载失败达到下次重试时间时恢复相关流程。

多个触发同时到达只允许合并成一次检查。

### 7.2 自动更新总开关

保留现有自动检查开关作为明确的网络访问总开关，并默认开启：

- 开启：按本文自动检查并自动下载。
- 关闭：不执行后台检查和下载；用户仍可手动检查。
- 手动检查成功发现更新后，允许用户在状态卡片中明确开始下载。

总开关只控制是否自动联网，不改变签名、验证、安装和回退安全要求。

### 7.3 任意网络下载

自动更新开启时，有线、Wi-Fi、手机热点和 Windows计费网络均自动下载。不提供“仅 Wi-Fi”提示或确认框。

### 7.4 `304 Not Modified`

- `200`：验证新清单，成功后原子保存清单和 ETag。
- `304` 且缓存有效：读取完整缓存并继续版本比较。
- `304` 且缓存缺失或损坏：立即执行一次不带条件头的完整请求。
- 完整请求仍失败：结果为“暂时无法确认”，不能是“已经是最新版”。

### 7.5 缓存规则

只缓存已通过结构、来源和签名验证的清单。新请求失败时保留上次有效缓存，不用无效数据覆盖。界面明确区分“刚刚确认”与“上次确认”。

### 7.6 隐私边界

所有更新网络请求统一通过更新网络端口，且只发送协议所需标准头。不得发送：

- 任务、日程、课程或偏好内容；
- 用户名或本地路径；
- 数据库标识；
- 设备唯一标识；
- Cookie或GitHub访问令牌；
- 当前业务数据摘要。

现有“唯一更新出网口”的架构测试应调整为允许清单和安装包下载，但仍禁止更新目录以外的产品代码直接联网。

## 8. 后台下载器

### 8.1 存储布局

```text
%LOCALAPPDATA%\BestPlanning\Updates\
  state.json
  logs\
  1.9.1.0\
    update-manifest.json
    package.msix.partial
    package.msix.ready
    update-request.json
    helper-status.json
    health-confirmation.json
```

路径必须由本地规范化版本构造，不能直接使用远端字符串作为目录名。

### 8.2 下载规则

- 未完成文件只能使用 `.partial`。
- 下载完成后验证长度和全文件 SHA-256。
- 验证成功后原子重命名为 `.ready`。
- 更新助手只接受 `.ready`。
- 同一时间只有一个目标版本下载。
- 发现更高版本后停止旧下载并切换新版本。
- 一次请求失败不删除上次有效清单或已验证包。

### 8.3 断点续传

- 使用 `Range` 和 `If-Range`。
- `206`：从正确偏移继续。
- `200`：服务器不接受续传，清空旧分段后重下。
- `416`：先判断本地文件是否已经完整，否则重下。
- ETag或 Last-Modified改变：旧分段作废。
- 最终仍需对完整文件重新计算 SHA-256。

### 8.4 重试退避

建议节奏：

```text
约30秒 → 约2分钟 → 约10分钟 → 约1小时 → 最多每6小时一次
```

每次加入随机抖动。网络恢复、用户主动重试或目标版本变化可以重置等待。签名、身份、撤回或系统不兼容等确定性错误不得高频重试。

### 8.5 磁盘空间

下载前和安装前分别检查：

```text
目标包 + 当前回退包 + 数据快照 + 安装展开空间 + 安全余量
```

安全余量至少为 `max(500 MB, 安装包大小 × 2)`。空间不足时保留有效分段，不删除用户文件。

## 9. 持久状态机

### 9.1 状态

```text
idle
checking
upToDate
updateAvailable
downloading
downloadPaused
verifying
ready
temporarilyBlocked
preparingInstall
waitingForExit
installing
launchingNewVersion
waitingForHealth
succeeded
rollingBack
rolledBack
failed
```

### 9.2 正常流

```text
idle → checking → updateAvailable → downloading → verifying → ready
→ preparingInstall → waitingForExit → installing → launchingNewVersion
→ waitingForHealth → succeeded
```

无更新流为 `idle → checking → upToDate`。

### 9.3 禁止跳转

- `downloading → ready`
- `checking → installing`
- `failed → installing`
- `upToDate → ready`
- `temporarilyBlocked → installing`
- 未健康确认即 `succeeded`
- 无回退包即 `rollingBack`

非法跳转必须记录结构化错误且不改变当前安全状态。

### 9.4 状态存储

`state.json` 独立于业务数据库，采用临时文件、刷新磁盘和原子替换。至少记录当前阶段、安装与目标版本、清单摘要、ETag、下载进度、哈希、重试状态、回退基线、事务编号和最近错误。

状态只是恢复线索。启动时必须重新核对文件、进程、锁和实际已安装包。

### 9.5 崩溃恢复

| 崩溃前状态 | 恢复动作 |
| --- | --- |
| `checking` | 回到 `idle` 后重查 |
| `downloading` | 核对分段后续传 |
| `verifying` | 从头验证完整文件 |
| `ready` | 再次验证文件、哈希和签名 |
| `temporarilyBlocked` | 重新判断阻塞条件 |
| `preparingInstall` | 助手未启动则退回 `ready` |
| `waitingForExit` | 检查助手和主进程实际状态 |
| `installing` | 查询 Windows实际包状态 |
| `waitingForHealth` | 继续等待、确认或回退 |
| `rollingBack` | 恢复回退流程 |
| `succeeded` | 核对版本后清理 |
| `failed` | 保留原因并等待合法重试 |

状态文件损坏时不安装任何文件；先盘点更新目录、重新验证候选文件并重建状态。业务主界面仍应能够启动。

## 10. 安全验证

### 10.1 三层信任

安装前必须全部通过：

1. **清单可信**：固定来源、合法重定向、严格结构、Ed25519签名。
2. **文件完整**：大小、SHA-256和有效 MSIX结构。
3. **包身份可信**：MSIX签名、证书链、Publisher、Identity、PFN、架构和版本。

任何一层失败都不能出现“仍然安装”。

### 10.2 防止校验后替换

更新助手必须在安装前再次验证规范路径、所有者、大小、SHA-256、签名、身份、架构和版本。不得只接受主程序传入的“已验证”布尔值。

### 10.3 证书与密钥轮换

- 包身份和 Publisher保持不变。
- 清单签名使用带 `keyId` 的公钥允许集合。
- 新旧清单密钥至少重叠一个正式版本。
- 先发布同时信任新旧密钥的客户端，再使用新密钥签名。
- MSIX证书轮换必须先验证 Windows仍将其视为同一 Publisher身份。
- 更新流程不得自动导入根证书或绕过系统策略。

## 11. 用户界面与交互

### 11.1 全局入口

更新入口固定在主导航左下角，在“今日、任务、领域、日历、统计、设置”之间切换时位置和状态不变。

### 11.2 状态映射

| 内部状态 | 左下角表现 | 点击行为 |
| --- | --- | --- |
| `idle/checking/upToDate` | 不显示 | 无 |
| `updateAvailable/downloading` | 低强调下载图标和进度 | 展开非模态状态卡片 |
| `downloadPaused` | 灰色或警示下载图标 | 可重试时执行一次重试 |
| `verifying` | 校验动画 | 展示“正在验证” |
| `ready` | 高亮更新图标和标记 | 立即进入更新流程 |
| `temporarilyBlocked` | 图标可见但禁用 | 显示行内原因 |
| 可重试 `failed` | 警示图标 | 执行一次重试 |
| 不可重试 `failed` | 警示图标 | 只显示原因和诊断 |

### 11.3 无弹窗规则

正常流程禁止：

- 发现更新弹窗；
- 下载完成弹窗；
- 周期性催促；
- Windows通知；
- 自动打开浏览器或 GitHub；
- 点击更新后的二次确认；
- 用户未点击时自动退出或安装。

只有主程序无法启动且自动回退也失败时，允许独立助手显示最小恢复窗口。

### 11.4 未保存内容

以下编辑状态阻止安装但不阻止下载：

- 新建或编辑任务；
- 编辑周期目标；
- 编辑固定日程或保护时间；
- 修改课程；
- 修改设置；
- 其他已发生实际字段变化的表单。

更新图标保持可见但禁用，显示：

```text
请先保存或取消当前编辑，再进行更新。
```

不得自动保存、丢弃或猜测用户意图。仅查看页面不能被误判为未保存编辑。

### 11.5 临时业务阻塞

数据库事务、计划应用或撤销、课程导入、备份恢复等操作进行时，显示：

```text
正在完成数据操作，完成后即可更新。
```

操作结束后自动恢复可点击状态。专注功能不在阻塞集合中。

### 11.6 设置页

原“检查更新”页改为状态和诊断页，显示：

- 当前版本和构建号；
- 最新稳定版本；
- 上次成功检查时间；
- 下载与校验状态；
- 包验证结论；
- 立即重新检查；
- 可重试时重新下载；
- Release说明入口；
- 最近一次结构化失败原因。

它与左下角入口必须读取同一个状态源。

## 12. 安全退出与独立更新助手

### 12.1 实现选择

助手使用原生 C++/WinRT，并作为 Windows独立构建目标。它不依赖额外 .NET或 Dart运行时，直接使用 Windows包部署与应用激活接口。

### 12.2 更新请求

主程序原子生成一次性请求，包含：

- 状态结构版本；
- 更新事务编号；
- 当前与目标版本；
- 安装包规范路径；
- 期望大小和 SHA-256；
- 期望包身份、PFN与 Publisher；
- 主程序和托盘 PID及进程启动时间；
- 一次性随机令牌；
- 创建时间与有效期。

助手拒绝过期、重复、路径越界、令牌错误或字段不一致的请求。

### 12.3 安装前顺序

1. 状态进入 `preparingInstall`。
2. 禁止新的业务写入。
3. 等待已开始事务完成。
4. 刷新内存设置和日志。
5. 完成数据库检查点和一致性检查。
6. 生成更新前数据快照。
7. 写入恢复描述和更新请求。
8. 启动并验证更新助手。
9. 确认助手取得跨进程锁。
10. 正常关闭托盘与主程序。
11. 助手确认相关进程全部退出后才部署。

助手未确认启动前，主程序不得自行退出。

### 12.4 助手限制

助手不得：

- 下载任意程序；
- 执行远端命令；
- 调用 PowerShell或批处理拼接安装命令；
- 安装非 MSIX载荷；
- 读取业务记录内容；
- 修改证书库；
- 接受更新目录以外的任意包路径。

助手可以把主程序生成的数据快照当作不透明文件执行受控恢复，但不得解析其中业务内容。

### 12.5 启动新版

助手使用真实 AUMID：

```text
ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner
```

通过 Windows应用激活接口启动，不猜测 WindowsApps目录，不写死版本化 EXE路径。

## 13. 数据快照、健康确认与回退

### 13.1 数据快照

更新前快照覆盖：

- 主数据库及必要辅助文件；
- 用户设置；
- 排程规则版本；
- 学习偏好数据；
- 更新状态；
- 数据格式版本。

快照在冻结新写入并完成数据库检查点后生成，具有完整性摘要。数据库迁移必须在事务中完成。

### 13.2 健康确认

新版本必须完成：

- 进程启动；
- 实际版本等于目标版本；
- 包身份正确；
- 主数据库可打开；
- 数据迁移成功；
- 核心仓储可读取；
- 主路由和界面初始化完成；
- 更新状态可读写；
- 启动期无未捕获异常。

完成后原子写入与事务编号匹配的健康确认。

初始健康等待为60秒；初始化未完成时新版本每10秒发送一次进度心跳，绝对上限为5分钟。超过绝对上限仍未确认则进入失败判定。

### 13.3 回退基线

1.9.0手动安装后，通过不可变的 `v1.9.0/update-manifest.json` 下载并验证自身正式 MSIX，建立初始回退基线。基线完成前可以下载新版本，但禁止安装。

以后每次成功更新时，本次目标包成为新的当前基线。新版本健康确认完成前保留直接上一版本包和数据快照。

### 13.4 自动回退条件

仅在以下条件全部满足时回退：

- 新包已安装但未健康确认；
- 新版本启动失败、超时或迁移失败；
- 直接上一版本包有效；
- 更新前快照完整；
- 新版本尚未产生需保留的新业务数据。

回退顺序：停止新版本、恢复更新前快照、重新验证旧包、使用 Windows受控版本恢复、启动旧版、记录失败并暂停同一目标版本。

### 13.5 灾难恢复例外

如果主程序无法启动且自动回退失败，助手可以显示唯一允许的恢复窗口，内容仅限：版本、简明原因、重试恢复、打开日志目录和退出。不得包含推广、催促或强制安装。

## 14. 错误模型

### 14.1 结果分类

每次检查只能是：

1. 已验证且确认无更新；
2. 已验证且发现更新；
3. 暂时无法确认；
4. 更新源或安装包异常。

只有第一类可以显示“已经是最新版”。

### 14.2 错误码

格式为 `UPDATE_<STAGE>_<REASON>`。首版至少覆盖：

#### 检查和清单

- `UPDATE_NETWORK_OFFLINE`
- `UPDATE_NETWORK_TIMEOUT`
- `UPDATE_NETWORK_TLS_FAILED`
- `UPDATE_NETWORK_HTTP_FAILED`
- `UPDATE_MANIFEST_NOT_MODIFIED_WITHOUT_CACHE`
- `UPDATE_MANIFEST_EMPTY`
- `UPDATE_MANIFEST_INVALID_JSON`
- `UPDATE_MANIFEST_SCHEMA_UNSUPPORTED`
- `UPDATE_MANIFEST_SIGNATURE_INVALID`
- `UPDATE_MANIFEST_SOURCE_NOT_ALLOWED`
- `UPDATE_MANIFEST_VERSION_INCONSISTENT`

#### 下载

- `UPDATE_DOWNLOAD_DISK_SPACE_LOW`
- `UPDATE_DOWNLOAD_PERMISSION_DENIED`
- `UPDATE_DOWNLOAD_RANGE_REJECTED`
- `UPDATE_DOWNLOAD_REMOTE_CHANGED`
- `UPDATE_DOWNLOAD_SIZE_MISMATCH`
- `UPDATE_DOWNLOAD_HASH_MISMATCH`
- `UPDATE_DOWNLOAD_CANCELLED_BY_NEW_VERSION`
- `UPDATE_DOWNLOAD_RETRY_EXHAUSTED`

#### 包验证

- `UPDATE_PACKAGE_FORMAT_INVALID`
- `UPDATE_PACKAGE_SIGNATURE_MISSING`
- `UPDATE_PACKAGE_SIGNATURE_INVALID`
- `UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED`
- `UPDATE_PACKAGE_PUBLISHER_MISMATCH`
- `UPDATE_PACKAGE_IDENTITY_MISMATCH`
- `UPDATE_PACKAGE_FAMILY_MISMATCH`
- `UPDATE_PACKAGE_ARCH_MISMATCH`
- `UPDATE_PACKAGE_OS_UNSUPPORTED`
- `UPDATE_PACKAGE_VERSION_SAME`
- `UPDATE_PACKAGE_DOWNGRADE_BLOCKED`
- `UPDATE_PACKAGE_VERSION_REVOKED`

#### 阻塞

- `UPDATE_BLOCKED_UNSAVED_CHANGES`
- `UPDATE_BLOCKED_DATABASE_TRANSACTION`
- `UPDATE_BLOCKED_PLAN_APPLYING`
- `UPDATE_BLOCKED_IMPORT_RUNNING`
- `UPDATE_BLOCKED_BACKUP_RUNNING`
- `UPDATE_BLOCKED_ROLLBACK_NOT_READY`
- `UPDATE_BLOCKED_DISK_SPACE_LOW`
- `UPDATE_BLOCKED_INSTALLER_BUSY`

#### 助手、安装和回退

- `UPDATE_HELPER_MISSING`
- `UPDATE_HELPER_SIGNATURE_INVALID`
- `UPDATE_HELPER_VERSION_INCOMPATIBLE`
- `UPDATE_HELPER_LOCKED`
- `UPDATE_HELPER_LAUNCH_FAILED`
- `UPDATE_HELPER_REQUEST_INVALID`
- `UPDATE_HELPER_PROCESS_EXIT_TIMEOUT`
- `UPDATE_INSTALL_PACKAGE_IN_USE`
- `UPDATE_INSTALL_DEPLOYMENT_BUSY`
- `UPDATE_INSTALL_DISK_FULL`
- `UPDATE_INSTALL_CERTIFICATE_FAILED`
- `UPDATE_INSTALL_DEPENDENCY_MISSING`
- `UPDATE_INSTALL_POLICY_BLOCKED`
- `UPDATE_INSTALL_DEPLOYMENT_FAILED`
- `UPDATE_INSTALL_RESULT_UNKNOWN`
- `UPDATE_HEALTH_PROCESS_NOT_STARTED`
- `UPDATE_HEALTH_STARTUP_TIMEOUT`
- `UPDATE_HEALTH_VERSION_MISMATCH`
- `UPDATE_HEALTH_DATABASE_OPEN_FAILED`
- `UPDATE_HEALTH_MIGRATION_FAILED`
- `UPDATE_HEALTH_UI_INIT_FAILED`
- `UPDATE_ROLLBACK_PACKAGE_MISSING`
- `UPDATE_ROLLBACK_PACKAGE_INVALID`
- `UPDATE_ROLLBACK_DATA_RESTORE_FAILED`
- `UPDATE_ROLLBACK_DEPLOYMENT_FAILED`
- `UPDATE_ROLLBACK_SUCCEEDED`

### 14.3 重试边界

离线、超时、临时 HTTP错误、下载中断、安装服务忙和短暂文件占用可以重试。签名、Publisher、Identity、撤回版本、不兼容系统、启动失败和回退失败不得自动循环。

### 14.4 诊断与隐私

日志记录阶段、版本、时间、重试次数、哈希结论、签名结论和 Windows结果码。不得记录业务标题、备注、UUID、数据库正文、令牌或证书私钥。

单日志不超过2 MB，最多5个轮换文件。设置页允许清除日志，但清除日志不得删除安装包、回退包或快照。

## 15. 并发与资源管理

### 15.1 单实例操作

全系统同时最多存在一个检查、下载、验证、安装或回退事务。跨进程锁记录 PID、进程启动时间、操作类型、目标版本、事务编号和随机令牌。

判断陈旧锁必须同时核对 PID和进程启动时间，避免 PID复用误判。

### 15.2 重复点击

连续点击更新图标只接受第一次。后续点击读取同一事务状态，不启动新助手。

### 15.3 清理

可删除：被更高版本取代的分段、哈希错误包、孤立临时文件、过期请求和超限日志。

不可删除：当前目标包、当前回退基线、正在安装的文件、唯一有效快照和尚未完成分析的失败证据。

默认仅保留当前稳定版本回退包和最新目标版本包。

## 16. 代码边界

建议布局：

```text
lib/domain/update/
  update_manifest.dart
  update_state.dart
  update_failure.dart
  update_version.dart
  rollback_baseline.dart

lib/application/update/
  update_orchestrator.dart
  update_policy.dart
  update_safety_coordinator.dart
  update_health_service.dart

lib/infrastructure/update/
  http_update_manifest_repository.dart
  file_update_state_store.dart
  resumable_package_downloader.dart
  update_package_verifier.dart
  file_update_lock.dart
  update_log_store.dart
  rollback_package_store.dart

lib/platform/update/
  windows_update_bridge.dart
  windows_package_info.dart
  windows_update_helper_launcher.dart

lib/features/shell/
  update_indicator.dart
  update_status_card.dart

lib/features/settings/update/
  update_page.dart
  update_diagnostics_panel.dart

windows/update_helper/
  CMakeLists.txt
  main.cpp
  update_request.cpp
  package_verifier.cpp
  package_deployer.cpp
  app_launcher.cpp
  health_monitor.cpp
  rollback_controller.cpp
```

最终文件名可按仓库命名习惯微调，但依赖方向和职责边界不得合并回单一巨型服务。

现有 `github_release_client.dart` 只在迁移期保留。新链路完成后删除旧 API、旧 Tag猜测、打开网页作为主要更新方式及重复版本比较。

## 17. 发布流水线

每次稳定发布严格执行：

1. 确定 SemVer和递增 build number。
2. 同步 Flutter版本和 MSIX版本。
3. 构建 Release x64 MSIX和原生更新助手。
4. 使用正式证书签名全部可执行产物和 MSIX。
5. 从成品包读取 Identity、Publisher、PFN、Version和Architecture。
6. 计算最终大小和 SHA-256。
7. 生成清单 payload并按 RFC 8785规范化。
8. 使用登记的 Ed25519密钥签署 payload。
9. 创建草稿 Release并上传 MSIX与清单。
10. 从 GitHub重新下载资产并复核大小、哈希、签名和身份。
11. 在旧版本 Windows虚拟机执行原位升级和数据验证。
12. 全部通过后发布正式 Release。
13. 验证 `latest/download/update-manifest.json` 指向新清单。
14. 使用真实旧版客户端完成发布后冒烟。

不得先发布空 Release后补传文件。

以下任一情况阻止发布：版本不一致、build未递增、MSIX不升序、身份或Publisher变化、签名无效、哈希不一致、清单签名失败、下载地址不可达、正式包与测试包不同、升级或回退测试失败。

## 18. 实施顺序

顺序不可颠倒：

1. 冻结协议、状态机、包身份、AUMID、错误码和签名密钥。
2. 实现并测试领域模型和严格清单解析。
3. 替换检查更新来源，消除假“最新版”。
4. 实现状态存储、后台下载和断点续传。
5. 实现 Windows包身份与签名验证。
6. 接入左下角入口和设置诊断页。
7. 实现并签名独立更新助手。
8. 接入业务安全协调、快照和健康确认。
9. 建立回退基线与自动回退。
10. 建立发布流水线和完整测试矩阵。
11. 执行 `1.9.0 → 1.9.1` 真实自动升级演练。
12. 删除旧更新实现并正式启用。

开发期使用内部功能开关 `nativeUpdaterEnabled`。正式版不暴露该开关；完整链路和回退未完成前默认关闭。正式启用时同时关闭旧更新入口，禁止两套逻辑并行。

### 18.1 实施计划拆分

本规格描述一个完整子系统，但代码实施必须拆成四个有先后依赖的里程碑，不能让多个写者同时修改同一更新主链：

1. **协议与检查器**：领域模型、清单签名、固定地址、缓存、`304`、错误分类和假“最新版”回归。
2. **下载与界面**：持久状态、断点续传、磁盘管理、左下角入口、设置诊断页和未保存状态协调。
3. **原生安装链**：Windows包验证、独立助手、进程退出、部署、AUMID启动和健康确认。
4. **恢复与发布**：数据快照、回退基线、自动回退、发布流水线、Windows矩阵和正式升级演练。

每个里程碑都需要独立测试门禁，但前三个里程碑不得单独对正式用户启用。第四个里程碑完成并通过 `1.9.0 → 1.9.1` 演练后，才允许打开正式功能开关。后续实施计划必须按这四个里程碑分组，并为共享文件指定单一顺序所有者，避免并行修改同一编排器、组合根或状态模型。

## 19. 过渡发布

当前1.8.0和1.8.1不具备下载器和独立助手，修改 GitHub Release不能让已安装旧版凭空获得这些能力。

因此：

```text
1.8.1 → 用户手动安装1.9.0
1.9.0 → 自动建立自身回退基线
1.9.0 → 自动发现并下载1.9.1
用户点击左下角入口
1.9.1自动安装、启动并健康确认
```

`1.9.0 → 1.9.1` 是首个完整自动更新功能的最终验收路径。

## 20. 测试策略

### 20.1 测试层级

- 单元测试：解析、版本、状态机、错误映射。
- 组件测试：缓存、状态存储、下载、界面投影。
- 集成测试：主程序、下载器、平台桥和测试 MSIX。
- 端到端测试：真实 Windows部署、启动、健康和回退。
- 发布冒烟：正式 GitHub Release到真实旧客户端。

### 20.2 核心回归

必须永久覆盖：

1. GitHub限流不显示最新版。
2. `304` 有缓存使用缓存。
3. `304` 无缓存重新完整请求。
4. 非标准历史 Tag不影响新协议。
5. 网络失败、空内容和解析失败不进入 `upToDate`。
6. Range续传、服务器忽略 Range、`416`和远端变更。
7. 文件长度、哈希、签名、Publisher、Identity、PFN、架构和版本不一致均阻止安装。
8. 主程序验证后替换文件能被助手二次验证发现。
9. 左下角图标在下载、验证、就绪、阻塞和失败状态正确。
10. 未保存编辑不丢失，纯查看不误阻塞。
11. 连续点击不启动多个助手。
12. 正常流程无应用弹窗、系统通知或浏览器跳转。
13. 安装失败保留旧版本。
14. 新版启动失败恢复旧包和更新前数据。
15. `1.9.0 → 1.9.1` 在 Windows 10和11均成功。

### 20.3 Windows矩阵

至少覆盖：

- 最低支持的 Windows 10 x64；
- 最新补丁 Windows 10 x64；
- 当前稳定 Windows 11 x64；
- 最新补丁 Windows 11 x64；
- 中文与至少一种非中文区域；
- 普通用户账户；
- 中文路径；
- 系统代理；
- 离线恢复；
- 手机热点和计费网络；
- 低磁盘空间；
- 托盘进程运行；
- 任务栏固定入口。

### 20.4 真实失败注入

必须验证：下载中断、断电式进程终止、状态文件损坏、磁盘满、包被占用、助手无法启动、主程序无法退出、部署失败、新版崩溃、迁移失败、健康超时、回退包损坏和快照恢复失败。

### 20.5 发布证据

每个正式版本保留：测试结果、产物 SHA-256、MSIX和助手签名结果、清单签名结果、包身份、Windows矩阵、原位升级日志、数据完整性对比、失败回退结果、正式 URL验证和发布后冒烟结果。

## 21. 可追踪验收要求

| ID | 要求 | 主要证据 |
| --- | --- | --- |
| UPD-001 | 使用固定签名清单，不调用 Releases API判断最新版 | 网络架构测试 |
| UPD-002 | `304` 有缓存时恢复完整清单 | manifest repository test |
| UPD-003 | `304` 无缓存时重新完整请求 | manifest repository test |
| UPD-004 | 失败和无更新是不同结果 | orchestrator test |
| UPD-005 | 只有有效清单比较后才能显示最新版 | UI state test |
| UPD-006 | 清单按 RFC 8785规范化并验证 Ed25519 | signature tests |
| UPD-007 | 未知字段和不支持 Schema被拒绝 | parser tests |
| UPD-008 | 地址和重定向受允许列表约束 | transport tests |
| UPD-009 | 自动更新开启时任意网络自动下载 | network policy tests |
| UPD-010 | 下载支持 Range续传 | downloader tests |
| UPD-011 | `200/206/416`分别正确处理 | downloader tests |
| UPD-012 | 新版本替代旧下载且文件不混用 | orchestration test |
| UPD-013 | 磁盘不足暂停且保留有效分段 | disk-space test |
| UPD-014 | 完整文件大小和 SHA-256均匹配 | verifier tests |
| UPD-015 | MSIX签名和证书链有效 | Windows verifier test |
| UPD-016 | Publisher、Identity、PFN和架构完全一致 | Windows verifier test |
| UPD-017 | 候选包版本严格高于当前版本 | version tests |
| UPD-018 | 撤回版本不能下载或安装 | revocation test |
| UPD-019 | 状态文件原子保存且损坏可恢复 | state store tests |
| UPD-020 | 非法状态跳转被拒绝 | state machine tests |
| UPD-021 | 跨进程锁阻止并发更新 | lock integration test |
| UPD-022 | 左下角入口在所有主页面保持一致 | widget/integration test |
| UPD-023 | 更新就绪前不可点击安装 | UI state test |
| UPD-024 | 点击就绪图标不显示二次确认 | interaction test |
| UPD-025 | 用户不点击时不自动安装 | time-based integration test |
| UPD-026 | 正常流程无弹窗、通知和浏览器跳转 | no-popup acceptance |
| UPD-027 | 未保存编辑禁用安装且内容不丢失 | form integration tests |
| UPD-028 | 纯查看页面不误判为脏状态 | dirty-state test |
| UPD-029 | 业务事务完成后自动解除阻塞 | safety coordinator test |
| UPD-030 | 专注状态不参与更新阻塞 | safety coordinator test |
| UPD-031 | 助手请求有有效期、令牌和规范路径 | helper request tests |
| UPD-032 | 助手在安装前执行独立二次验证 | helper verifier test |
| UPD-033 | 主程序和托盘退出前不部署 | process coordination test |
| UPD-034 | 通过真实 AUMID启动新版 | Windows activation test |
| UPD-035 | 安装前创建一致性数据快照 | snapshot test |
| UPD-036 | 数据迁移在事务内完成 | migration failure tests |
| UPD-037 | 健康确认包含实际版本和核心初始化结果 | health tests |
| UPD-038 | 健康失败且条件满足时自动回退 | rollback E2E |
| UPD-039 | 同一失败目标不会无限自动安装 | retry policy test |
| UPD-040 | 回退失败时只显示最小恢复窗口 | recovery E2E |
| UPD-041 | 更新日志不含业务内容或敏感信息 | privacy scan |
| UPD-042 | 发布流水线从成品生成大小、哈希和清单 | release pipeline test |
| UPD-043 | 草稿 Release完整验证后才发布 | release gate |
| UPD-044 | 测试产物与正式上传产物哈希一致 | artifact audit |
| UPD-045 | Windows 10和11完整升级通过 | Windows matrix |
| UPD-046 | 1.8.1手动升级1.9.0后数据完整 | bootstrap acceptance |
| UPD-047 | 1.9.0自动升级1.9.1成功 | final updater acceptance |
| UPD-048 | 新链路启用后旧更新实现被删除 | architecture audit |

实施计划必须把 UPD-001至 UPD-048逐项映射到具体测试名或人工门禁记录。“相关测试通过”不能代替逐项证据。

## 22. 风险与控制

| 风险 | 控制 |
| --- | --- |
| GitHub限流或不可用 | 不用 Releases API；缓存有效签名清单；退避重试 |
| 清单或下载被替换 | Ed25519清单签名 + SHA-256 + MSIX签名与身份校验 |
| 更新时文件仍被占用 | 助手等待主程序和托盘实际退出 |
| 主程序退出但助手未启动 | 助手握手成功后主程序才退出 |
| 更新中断 | Windows部署状态核对 + 持久状态机 |
| 数据迁移失败 | 更新前快照 + 事务迁移 + 健康门禁 |
| 新版无法启动 | 直接上一版回退包 + 数据恢复 |
| 证书轮换断链 | 新旧信任重叠版本 |
| 多次点击并发安装 | 跨进程锁和事务编号 |
| 半成品进入正式版 | 默认关闭功能开关 + 发布门禁 |

## 23. 最终完成定义

以下条件全部成立后，才能将本规格标记为已实现：

- UPD-001至 UPD-048均有明确证据；
- 单元、组件、集成和端到端测试全绿；
- Windows 10和11真实升级通过；
- 安装失败不破坏当前版本；
- 启动失败的安全回退演练通过；
- 用户业务数据逐值保持；
- 正常更新流程没有弹窗和系统通知；
- 发布流水线可以生成并验证正式清单；
- `1.9.0 → 1.9.1` 正式通道升级成功；
- 旧 GitHub Releases API更新链路已删除；
- 验收记录中不存在把 `NOT RUN` 标记为通过的条目。
