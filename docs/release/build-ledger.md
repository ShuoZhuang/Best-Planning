# 构建与发布台账

本文件记录候选构建和正式发布状态。只有满足 `version-policy.md` 第 7 节的全部条件并把状态改成
“已发布”，才算正式发布。

> **当前正式发布：`1.6.2+37` / MSIX `1.6.2.0`（2026-10-08，tag `v1.6.2-build37`）** —— 见下方 `1.6.2+37` 批次。
> **当前候选：`1.8.1+45` / MSIX `1.8.1.0`（2026-10-17）** —— 产物已就绪，**尚未发布**；见下方 `1.8.1+45 / MSIX 1.8.1.0` 批次。
> `1.8.0+44` / MSIX `1.8.0.2` 已被 `1.8.1+45` 取代（产物仍在 `release\` 下留档）。
> `1.8.0+44` / MSIX `1.8.0.1` 已被**同批次重打包**的 `1.8.0.2` 取代（前者是日历修复**之前**的构建；产物仍在 `release\` 下留档）。
> `1.8.0+43` / MSIX `1.8.0.0` 已被 `1.8.0+44` 取代（其产物仍在 `release\` 下留档）。
> `1.7.1+42` / MSIX `1.7.1.1` 已被 `1.8.0+43` 取代（其产物仍在 `release\` 下留档）。
> `1.6.2+37` 之前的所有批次都保持"候选构建"状态，未对外发布。

## 1.8.1+45 / MSIX 1.8.1.0 — 2026-10-17（`1.8` 发布线 · 容量感知分层排程修复批次）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建**（产物已就绪，**尚未发布**）——等待人工验收与 GitHub Release |
| 变更范围 | **容量感知分层排程修复**（计划 `docs/superpowers/plans/2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`）：① **逐日规则**——`DailySchedulingPolicy` 按本地日解析，每日上限／粒度／休息间隔／生活配额不再复制窗口首日（周末上限此前整周不生效）；② **单一容量账本**——`DayCapacityLedger` 成为"某天还能放多少"的唯一来源，且 `usedMovableMinutes` **包含锁定块**（修复前锁定 300 分钟、上限 360 的一天仍可再排 360）；③ **方案级字典序目标**——`ScheduleObjective` + `compareScheduleObjectives`，禁止加权和；④ **全局跨日分配**——`allocateTaskDays` 先按方案目标把分钟摊到 K 个日期（`K × chunk ≤ 目标`），引擎只在预算内放置；⑤ **引擎日内接线与动态重分**——预算落地失败由 K 计算与引擎遍历转让，**没有**多轮重分循环；⑥ **方案级改进闸门**——`PlanQualityValidator` + `_wholePlanIsBetter`，局部候选分更高也不能恶化整案；⑦ **既有块身份（ID 族）**——未锁定的既有块携带**原 id** 作为起点进入排程，`minimizeChangedBlocks` 不再空操作；⑧ **精力偏离解释**——`explanationCode` 由 `energy_offpeak`（「偏离精力偏好」）取代此前的 `priority`（「优先级较高」） |
| 版本段位 | `1.8.0+44` → **`1.8.1+45`**；MSIX `1.8.0.2` → **`1.8.1.0`**（第四段归零：本批**改了代码**，不是同批重打包）。按版本策略第 2 节判据，本批**全是修复**（无新增用户可感知功能），因此抬第 3 段 |
| 数据库 | **schema 未变，无迁移**；`drift_schemas/` 未改 |
| 排程算法 | **`16` → `19`**：17 = 容量感知分层排程（逐日规则／账本／方案目标／跨日分配）；18 = 既有块身份（ID 族）；19 = 精力偏离解释码 |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test`：**605 文件 0 改动**；`flutter analyze`：**No issues found**；`flutter test`：**2769 项通过 / 0 失败**（约 73 秒） |
| Windows 集成测试 | **未执行**——本环境 `flutter test integration_test` 因 `flutter-web-sdk.zip` 下载握手失败（网络受限），不是代码问题 |
| 人工验收 | 六项人工场景**已改为自动化覆盖**（`test/app/manual_scenarios_ui_test.dart` 6 条全绿），见 `docs/testing/capacity-aware-scheduler-acceptance.md` §9 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 **`1.8.1+45`**，产品名 `优计主义` |
| 启动冒烟 | 便携版在**临时副本**中启动成功：进程存活 10 秒、无错误输出（仅 Impeller 后端日志）、自动生成 `user-data\`（数据库初始化成功）。冒烟副本已删除，`user-data` **不在交付包内** |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.8.1-build45-windows-x64-20261017`（**12 个顶层条目**） |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.8.1-build45-windows-x64-20261017.zip`（**34737909 字节**，**34 条目**） |
| MSIX | 同目录内 `PersonalPlanner-1.8.1-build45-windows-x64-20261017.msix`；清单 `ShuoZhuang.PersonalPlanner` / **`1.8.1.0`** / x64（已解包核对 `<Identity … Version="1.8.1.0"`） |
| EXE SHA-256 | `BE4906C3BCB0623412C7B05F7CCC71F73C3D0DD10A6D7B6960E0B1C92D34C916`（EXE 只是启动器，Dart 代码改动不改变它——与 `1.8.0.2` 同值正是这个原因，**不能**拿它当内容判据） |
| app.so SHA-256 | `D8AB3AC2C0092B32995048F37D39CB9DC51A591905437B1DE430C167C0DEF698`（真正的 Dart 代码；与 `1.8.0.2` 的 `C474317B…` **不同**） |
| ZIP SHA-256 | `3FFC7D4463507240D2B1CE6D40C351384010B0762F6A0119B2DFA10FB7313F2C` |
| MSIX SHA-256 | `6ADCDF7AEBF6E4592716330E88D9D47A349E0AF9E016F8D4B2B595FBA35565CF` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与历次同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN` |
| 覆盖安装 | **`1.8.1.0` > 已装 `1.8.0.2`** ⇒ 可原位升级（安装前需先退出正在运行的应用，否则 `0x80073D02`）。**本次未执行任何本地安装**（按用户要求） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、一键安装器（`安装.cmd` + `install-planner.ps1`）、验收说明、`SHA-256.txt` 齐全；ZIP **34 条目**、**无** `user-data`／`.sqlite`／`.bak`／`.pfx`／`.key`／`.pem`／`.log`（已按条目名自检，计数为 0） |
| 隐私 | `.pfx` 与私钥不进版本库也不进交付包；交付包只带**公钥** `.cer` |
| 构建环境注意事项 | 本机构建需绕过一个 Flutter SDK 与 Windows 的交互缺陷：`Link.createSync` 未传 `ALLOW_UNPRIVILEGED_CREATE`，即使已开开发者模式也报 `errno 1314`。绕法＝**先用 PowerShell 预创建** `windows\flutter\ephemeral\.plugin_symlinks` 下的 6 个插件链接（Flutter 检测到已存在即跳过），再 `flutter build windows --release --no-pub` |
| 尚未完成 | **人工验收与 GitHub Release 未完成**；GitHub 正式 Release 与 tag 尚未创建/推送 |

## 1.8.0+44 / MSIX 1.8.0.2 — 2026-10-14（`1.8` 发布线 · 日历与排程完整性修复批次 · **同批重打包**）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建**（产物已就绪，**尚未发布**）——等待人工验收 |
| 变更范围 | **日历、计划预览与排程完整性修复**（计划 `docs/superpowers/plans/2026-10-13-calendar-preview-and-scheduling-integrity-repair.md`）：① **动态短尾**——候选按"当前剩余量"逐轮重算，100 分钟的任务第一次能排出 `30+30+30+10`（R3）；② **唯一短尾集合校验**——`validatePlannedChunkSet` 按同任务整组块判定，合法短尾不再被自己拒掉（R4）；③ **最终诊断只看最终计划**——删除跨轮次拒绝证据，原因由 `diagnoseTaskPlacement` 依最终块集合重算（R5/R6/R7）；④ **异常提案必为阻断**——`allowPartial` 也无法写库（R8）；⑤ **日历三视图自动刷新**——app-scoped 失效总线接上全部成功写入点（计划／撤销／日程／课程／规划规则／配色／领域，R9/R10）；⑥ **近期日历命名**——标题改「近期日历」、空状态改「当前范围暂无安排」（仍是八列，R12）；⑦ 日视图固定 48 px 操作槽、只显示可执行动作（R2/U5）；⑧ 预览恢复动作、部分应用降级、未使用空档证据、移除预览页自动调整开关（U1–U4）；⑨ 保护时间标签由类型承载（R1）、固定日程不再冒充「已完成」（R11）。另修掉两处既有缺陷：`withLinkedBlocks` 漏传 `adjustmentRequirement`；同时有阻断时警告分组丢掉「需要注意」级别 |
| 版本段位 | **仍为 `1.8.0`**、构建号**仍为 `+44`**（与 `1.8.0.1` 是**同一批代码**）；**MSIX 第四段 `1` → `2`**：`1.8.0+44` 已产出过 `1.8.0.1` 且**本机已安装它**，而 `Add-AppxPackage` 不接受更低版本、同版本覆盖不可靠——按"第四段 = 同一批次重打包计数"这条规则 +1（用户 2026-10-14 明确要求）。**代码、`version`、包身份均未变**；判定内容是否变化要看 `data/app.so` 指纹（本批 `C474317B…` vs `1.8.0.1` 的 `39FBB4C8…`） |
| 数据库 | **schema 仍为 v9，无迁移**；`drift_schemas/` 未改 |
| 排程算法 | **`15` → `16`**（候选按剩余量逐轮重算 ＋ 唯一短尾集合校验 ＋ 每日上限在放置阶段恢复为硬约束） |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：**585 文件 0 改动**；`flutter analyze --no-pub`：**0 问题**；`flutter test --no-pub`：**2496 项通过 / 0 失败** |
| Windows 集成测试 | `flutter test --no-pub integration_test/calendar_preview_consistency_test.dart -d windows`：**1 项通过 / 0 失败**（应用计划、编辑固定日程、完成任务后三个视图在同一进程内保持一致） |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.8.0+44` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261014`（13 个顶层条目） |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261014.zip`（**35094838 字节**，**35 条目**） |
| MSIX | 同目录内 `PersonalPlanner-1.8.0-build44-windows-x64-20261014.msix`；清单 `ShuoZhuang.PersonalPlanner` / **`1.8.0.2`** / x64（已解包核对 `<Identity … Version="1.8.0.2"`） |
| EXE SHA-256 | `8AAF66980C7AC6F97CA01F09FC5AC5FF24BBCAC7FA2C5D5A908F2FFDDB0A2D2B`（与 `1.8.0.1` **同值**：EXE 只是启动器，Dart 代码改动不会改变它——这正是不能拿它当内容判据的原因） |
| app.so SHA-256 | `C474317B53D7336A9318F01A39C4E042522089ED7602EB1087517F36D76A9719`（真正的 Dart 代码；与 `1.8.0.1` 的 `39FBB4C8…` **不同**） |
| ZIP SHA-256 | `28E981AE46ACE2C604D7B7F052D8536F23720036467C07EEE2EBA9AD4EB333D5` |
| MSIX SHA-256 | `7358D1F408433E25D7520EC59077D3247C11380296ADAFBAF8C342A369D93B05` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与历次同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN` |
| 覆盖安装 | **`1.8.0.2` > 已装 `1.8.0.1`** ⇒ 可原位升级（安装前需先退出正在运行的应用，否则 `0x80073D02`）。**本次未由自动化执行安装**：就地替换已安装包留给用户在人工验收时决定并执行 |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、一键安装器（`安装.cmd` + `install-planner.ps1`）、验收说明、`SHA-256.txt` 齐全；ZIP **35 条目**、**无** `user-data`／`.sqlite`／`.bak`／`.pfx`／`.key`／`.pem`／`.log`（已按条目名正则自检）。**一条实测提醒**：免安装版首次运行会在 exe 旁生成 `user-data\`（数据库 ＋ 诊断日志）——打包前做过一次启动冒烟测试，那个目录**已被删除**，不在交付包里 |
| 隐私 | `.pfx` 与私钥不进版本库也不进交付包；交付包只带**公钥** `.cer` |
| 尚未完成 | **人工验收未执行**（`manual-windows-checklist.md` §J 与 `docs/testing/calendar-preview-scheduling-integrity-acceptance.md` §3 的场景 A–F 每格仍为空）⇒ 按 `windows-release.md` 只能登记为**内部构建／候选**，不得登记为正式发布。GitHub Release、tag 亦未做 |

## 1.8.0+44 / MSIX 1.8.0.1 — 2026-10-13（`1.8` 发布线 · 课程与保护时间管理修复批次）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建**（产物已就绪，**尚未发布**）——等待人工验收与 GitHub Release |
| 变更范围 | **课程与保护时间管理修复**（用户 2026-10-12 提出）：① **课程资料第一次可改**（名称／教师／地点／领域／项目／每一段的星期与周次／每日还是单双周），保存前给**影响预览**（新增／改写／删除片段数、课次变化、会连带删掉的逐次例外数），用户确认后才**在一个事务里整体替换**；② **单双周多片段不再互相覆盖**（改一段只动那一段，星期集合与间隔不被丢成单值）；③ 聚合键是 `logicalCourseId`，**同名不同班不被一起改**；④ 保护时间改为**按系列**列出与编辑（此前按 180 天展开结果列行、只能删不能改）；⑤ **仅本次改名**真正生效（例外行此前只能换时间）；⑥ **早餐保护**可配置，老用户**默认关闭**（不被强开）、首次引导默认开启；⑦ 保护窗口**重叠在保存前拦截**并指出具体区间，不静默合并；⑧ 保存后的返回路径由入口决定（此前"从管理页进新建、保存后落在周视图、取消落在新建任务页"） |
| 版本段位 | **仍为 `1.8.0`** —— 这批全是修复，没有新的用户可感知行为变化需要抬段；构建号 `+43` → `+44`（**不随版本号归零**）；MSIX 第四段 `0` → `1`（`1.8.0.0` 已产出过，而 `Add-AppxPackage` **不接受更低版本**） |
| 数据库 | **schema 仍为 v9，无迁移**（`schema_migration_test.dart` 断言 `GeneratedHelper.versions.last == 9`）；备份往返逐项比对课程／规则／例外／早餐设置 |
| 排程算法 | **算法版本仍为 `14`**（`1.8.0+43` 时为 `13`，第一批修复抬到 `14`；本批**未再改动**算法） |
| 新增测试 | 全套 **2317 项通过**；另有 Windows 集成测试 **6 项通过** |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：**576 文件 0 改动**；`flutter analyze --no-pub`：**0 问题**；`flutter test --no-pub --concurrency=1`：**2317 项通过**，退出码 0 |
| Windows 集成测试 | `flutter test --no-pub integration_test/course_and_protection_management_test.dart -d windows`：**6 项通过 / 0 失败**（课程资料、同名不同 id、保护时间系列与例外、排程不占保护时间、早餐启用／关闭、重叠拦截） |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.8.0+44` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261013` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261013.zip`（**35062683 字节**，**34 条目**） |
| MSIX | 同目录内 `PersonalPlanner-1.8.0-build44-windows-x64-20261013.msix`；清单 `ShuoZhuang.PersonalPlanner` / **`1.8.0.1`** / x64 |
| EXE SHA-256 | `8AAF66980C7AC6F97CA01F09FC5AC5FF24BBCAC7FA2C5D5A908F2FFDDB0A2D2B` |
| ZIP SHA-256 | `FFDEF52C4F2D3F7E64C95BF6C40752C449C28333AB6CD35A4A2C29B462B1501D` |
| MSIX SHA-256 | `A54848D40A6A12209DD74F4B3AC8D38FF7F2B8E947E20A1BA63CC70E629C751A` |
| app.so SHA-256 | `39FBB4C8A5F7BC7E558227A615DABD85D765F97547785CED376333603A5F8072`（真正的 Dart 代码；EXE 只是启动器） |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与历次同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`，指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`，有效期至 2031-10-03 |
| 覆盖安装 | **`1.8.0.1` > 已装 `1.8.0.0`** ⇒ 可原位升级（安装前需先退出正在运行的旧版，否则 `0x80073D02`）。装前已核对已安装副本 `data\app.so` = `A6D5C3E1B760200DF68CAF55EC8DF970AE2FB3FAEC35A2A137CC689C81B77C9B`，正是 `1.8.0+43` 的值 |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、一键安装器（`安装.cmd` + `install-planner.ps1`）、安装说明、`SHA-256.txt` 齐全；ZIP **34 条目**、**无** `user-data`／`.sqlite`／`.bak`／`.pfx`／`.key`／`.pem`／`.log`／诊断日志 |
| 隐私 | `.pfx` 与私钥**不进版本库也不进交付包**；交付包只带**公钥** `.cer`（已核对 `HasPrivateKey=False`）。包内唯一的图片是应用自带的 6 张教程截图（`data\flutter_assets\assets\tutorial\`），**不是个人课表图片** |
| 安装说明更新 | `安装说明.txt` 改为 `1.8.0+44` / MSIX `1.8.0.1` 与真实文件名；"这个版本里有什么"整段换成本批五条改动（课程资料可改、单双周不牵连、同名不同班、保护时间可改名、早餐与重叠拦截），并如实写出四条已知限度 |
| 尚未完成 | **人工验收未执行**（`manual-windows-checklist.md` §7.1–7.10 每格仍为空）⇒ 按 `windows-release.md` 第 4 节，只能登记为**内部构建／候选**，不得登记为正式发布。GitHub Release、tag 与 SHA-256 对外清单亦未做 |


## 1.8.0+43 / MSIX 1.8.0.0 — 2026-10-12（`1.8` 发布线 · 核心工作流修复批次）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建**（产物已就绪，**尚未发布**）——等待人工验收与 GitHub Release |
| 变更范围 | **核心工作流修复**（用户 2026-10-11 提出、2026-10-12 复核）：① 延后改为**块级**（不再把同任务其他块一起推后）；② **稳定来源关联** `continuedFromId`（不复用数据库主键）；③ **当天优先 + 统一硬占用集合**（固定日程含课程缓冲／规则与自定义保护时间／**睡眠**／锁定块／已过去的块）；④ **未被本次调整碰到的确认块原位冻结**（§11.4 第 3、4 条最小改动）；⑤ 预览把"同一块换时间"报成**「移动」**而非删除＋新增；⑥ `localRepairCascade` 接入生产路径 + **有限候选择优**（上限 32）；⑦ `LocalRepairPlan.compare` 补上**第 6、7 级坏空档**；⑧ **精确拦截**"本次延后没兑现"（`requestedAdjustmentUnsatisfied`，**只针对当前调整请求**，不是全局 `unscheduled` 拦截） |
| 版本段位 | **`1.7.1` → `1.8.0`**（**用户 2026-10-12 裁定**）。抬第 2 段是因为这批含**用户可感知的行为变化**（延后作用域、当天优先、预览措辞、失败拦截）；构建号 `+42` → `+43`（**不随版本号归零**）；MSIX 第四段 `0` = 抬第 2 段时归零 |
| 数据库 | **schema v8 → v9 有迁移**（`calendar_events.kind`，保护时间与固定日程可分）；已在验收文档 §14 验证：事务内 `onUpgrade`、真实 `planner-backup.zip` 往返、向前兼容守卫 |
| 排程算法 | **算法版本 `11` → `13`**（内部排程算法版本，**不是软件版本号**）。`12` = 前四项改动；`13` = 当天优先／统一硬占用集合／原位冻结 |
| 新增测试 | 全套 **2068 项通过**（`1.7.1` 收口时为 1629 项） |
| 格式／分析／测试 | `dart format lib test`：**529 文件 0 改动**；`flutter analyze --no-pub`：**0 问题**；`flutter test`：**2068 项通过**，退出码 0 |
| Windows Release | `flutter build windows --release` 成功；EXE 文件版本与产品版本均为 `1.8.0+43` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.8.0-build43-windows-x64-20261012` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.8.0-build43-windows-x64-20261012.zip`（**34989489 字节**，**35 条目**） |
| MSIX | 同目录内 `PersonalPlanner-1.8.0-build43-windows-x64-20261012.msix`；清单 `ShuoZhuang.PersonalPlanner` / **`1.8.0.0`** / x64 |
| EXE SHA-256 | `E9845ACBEB678F9B2E1C412F82813F2CC632005DCA91122D11DC826E7937D12E` |
| ZIP SHA-256 | `E83B7FD38592AA78FD7ABAE522571CC7AB588E9E9BCA0BDC486BE5CBFD1093B3` |
| MSIX SHA-256 | `2FDCBBCE3BE1D33130D2710E337864F0964E2C537DADA2F06B26FC584557F6A0` |
| app.so SHA-256 | `A6D5C3E1B760200DF68CAF55EC8DF970AE2FB3FAEC35A2A137CC689C81B77C9B`（真正的 Dart 代码；EXE 只是启动器） |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与历次同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`，指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`，有效期至 2031-10-03 |
| 覆盖安装 | **`1.8.0.0` > 已装 `1.7.1.1`** ⇒ 可原位升级（安装前需先退出正在运行的旧版，否则 `0x80073D02`） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、一键安装器（`安装.cmd` + `install-planner.ps1`）、安装说明、`SHA-256.txt` 齐全；ZIP **35 条目**、**无** `user-data`／`.sqlite`／`.bak`／`.pfx`／`.key`／`.pem`／`.log`／诊断日志 |
| 隐私 | `.pfx` 与私钥**不进版本库也不进交付包**；交付包只带**公钥** `.cer` |
| 打包时清理 | 便携目录里删除了两项**不该出货**的内容：`user-data\`（本机运行痕迹，含 `personal_planner.sqlite`）与 `tray_icon_message_policy_test.exe`（原生测试程序）。**前者是真实数据库副本**，若随包发布就是数据泄漏 |
| 安装说明更新 | 随包的 `安装说明.txt` 此前仍是 **1.6.2** 的文案（`1.7.1` 包沿用了它），本轮改为 1.8.0 版本号与文件名，并把"这个版本里有什么"整段换成 1.8 的六条改动 |
| 尚未完成 | **人工验收未执行**（`manual-windows-checklist.md` §12.1–12.12 每格仍为空）⇒ 按 `windows-release.md` 第 4 节，只能登记为**内部构建／候选**，不得登记为正式发布。GitHub Release、tag 与 SHA-256 对外清单亦未做 |


## 1.7.1+42 / MSIX 1.7.1.1 — 2026-10-08（`1.7` 发布线 · 路线图全部 14 个任务合并交付）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建**（产物已就绪，**尚未发布**）——等待人工验收与 GitHub Release |
| 变更范围 | **路线图 `1.7.0` 批次的全部 14 个任务 + 用户 2026-10-08 追加的 Task 12A**：① 统计复盘重做（四页签、四项摘要、来源明细、横轴与单位修正）；② 日程详情导航（三类事项各自到正确页面）；③ 按周固定时长的周期目标（模型、生命周期、编辑、排程接入、提醒与统计）；④ 默认开启的 GitHub 更新检查；⑤ 可撤销动作、空状态下一步与长期提示一致性；⑥ **Task 12A：修复会让真实可用时间被误判为"容量不足"的发布阻断问题** |
| 版本段位 | **`1.6.2` → `1.7.1`**（**用户 2026-10-08 裁定：`1.7.0` 不单独发布，直接从 `1.6.2` 跳到 `1.7.1`**）。抬第 2 段是因为含用户可感知的新功能（统计复盘重做、周期目标、更新检查、课后缓冲）；抬第 3 段是因为交付验证阶段又修掉四处缺陷（周期目标不进排程、周期目标不在任何列表里、「删除」点了没有动作、外键清理不全）——按 `version-policy.md` 第 2 节的表，**第 3 段正是"批次里只有修复"**。构建号全局单调递增 `+40` → `+41`（**不随版本号归零**）；MSIX 第四段 `0` = 抬第 3 段时归零 |
| 数据库 | **schema v7 → v8 有迁移**：v7 新增两张周期目标表；**v8 修复存量的非法片段设置**（`min > max`，或片段上下限超过任务总时长）。v8 一个列都没加、一个表都没建，纯粹是数据修复——**只夹紧片段两列，剩余时长／截止时间／标题／备注／状态一律不动** |
| 排程算法 | **有改动**：新候选生成规则（最终余量短于最小片段时仍可安排）、窗口起点改为"现在"而非当天本地午夜、周期目标的允许星期与单日配额、未安排任务的结构化原因、**课表课程结束后的过渡缓冲**、周期目标"均匀分布"改由容量感知的按日均分器执行（1.7.1 修复批次） |
| 统计口径 | **未改动**；周期目标的完成分钟**单独一张卡**，不混进领域计划时长 |
| 新增测试 | 全套 **1629 项通过**（`1.6.2` 收口时为 1073 项）；八个集成测试文件合计 **10 项通过** |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：**459 文件 0 改动**，退出码 0；`flutter analyze --no-pub`：**0 问题**；`flutter test`：**1629 项通过**，退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功（109.0s）；EXE 文件版本与产品版本均为 `1.7.1+42` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.7.1-build42-windows-x64-20261008` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.7.1-build42-windows-x64-20261008.zip`（**34756637 字节**，**35 条目**） |
| MSIX | 同目录内 `PersonalPlanner-1.7.1-build42-windows-x64-20261008.msix`；清单 `ShuoZhuang.PersonalPlanner` / **`1.7.1.1`** / x64 |
| EXE SHA-256 | `E3B88DB6020D73A244014E4155BA57A0D7053402EC48EB94265BD1E657E6CD44` |
| ZIP SHA-256 | `F6B070D6CB75296D6636003DD7F2BE45373A15231C73576619B6C30F051F1B76` |
| MSIX SHA-256 | `93AC45A2ED7E96D4B04F582FBC8105467BB7177320BEA58B287CA9307C1A9737` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与历次同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`，指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13` |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、一键安装器、安装说明、`SHA-256.txt` 齐全；ZIP **35 条目**、**无** `user-data`／`.sqlite`／`.bak`／`.pfx`／`.key`／`.pem`／`.log`／诊断日志；`data/flutter_assets` 之外**无用户图片** |
| 隐私 | `.pfx` 与私钥**不进版本库也不进交付包**：签名按**指纹**从当前用户证书库选取（`signtool_options`），密码不出现在任何文件或命令里 |
| Release Notes | `docs/release/1.7.0-release-notes.md`（叙述版）· `docs/release/1.7.0-github-release-body.md`（**可直接粘贴的 GitHub Release 正文**）· `docs/release/1.7.1-build42-user-guide.md`（使用教程） |

### ⚠️ 同版本号重建的代价（2026-10-08 实测，必须记住）

重建时我把 MSIX 版本**保持为 `1.7.0.0`**，而它与先前那次构建是**同一个版本号**。
后果：Windows 认为"没有更新"，`Add-AppxPackage` 变成一次空操作，**用户机器上仍是旧文件**。
用户因此报告"装了新版却看不到修复"——而包本身是正确的。

**判定方法**（比看版本号可靠）：比对**已安装副本**与构建产物的 `data/app.so` 指纹。
EXE 的哈希在重建前后可能相同（它只是启动器），只看 EXE 会误判"没重新构建"。

```powershell
$pkg = Get-AppxPackage -Name "ShuoZhuang.PersonalPlanner"
Get-FileHash (Join-Path $pkg.InstallLocation "data\app.so") -Algorithm SHA256
```

**规则**：**内容变了就抬号。** 抬构建号 `+N`，同时抬 MSIX 第四段（`1.7.1.1` → `1.7.1.1`），
否则新包无法覆盖已装的同版本包。这条已写进 `version_consistency_test.dart` 的 reason 里。

**这条规则被踩了两次**：第一次重建保持 `1.7.0.0` 不变（用户报"装了新版却看不到修复"）；
第二次（删除修复）又从 `1.7.1.1` 抬到 `1.7.1.1`。**每次都抬，不要判断"算不算重打包"**——
判断错了的代价是用户装了却没变化，而那种情况从版本号上完全看不出来。


### 重建记录（2026-10-08，首次构建之后并入的修复）

首次构建（同日早先）之后，人工验收报了四条缺陷、另提了一条新需求，全部修好后**重建**了候选。
因此上面那些哈希对应的是**重建后**的产物，首次构建的产物已删除。

| 提交 | 内容 | 为什么算发布阻断 |
| --- | --- | --- |
| `5c2d2b78` | **保存周期目标后重新规划，计划里不显示它** | 生成"本周实例"的 `ensureCycles` 只在启动时跑过一次，而排程输入只读实例、读不到就静默跳过——会话中途新建的周期目标必须**重启程序**才生效。这是本批次主功能的"操作完成了但结果要重启"缺陷 |
| `c8c2b02f` | **周期目标不在任何列表里，无法管理** | 列表页只订阅普通任务，而周期目标在另一张表；其管理动作入口全在详情页，没有列表就没有入口——用户建完**再也回不去** |
| `1bdf0221` | **「删除这个周期目标」点了没有动作** | `router.dart` 的 `onDelete` 只写了 `context.go('/tasks')`——**只导航、不删除**；而服务与仓储**根本没有删除模板的能力**（只有归档）。那个按钮从一开始就是**渲染了却没有动作的死入口**，用户会以为删掉了而其实还在 |
| `dee15321` | 新增：**课后十分钟缓冲**（用户需求） | 不是阻断，是用户明确提出的新需求；只对课表导入的课生效 |
| `789f7ae5` | 课后缓冲**可在设置页改／关** | 补上 `dee15321` 留下的缺口：规则生效但用户无法调整 |
| `f87274bd` | 今日页**「延后本次」**（并行 agent 产出，本次提交收拢） | 不是阻断；补齐"这一块现在做不了就往后挪一刻钟" |

### 1.7.1 修复批次：周期目标「均匀分布」被集中到少数日期（用户 2026-10-08 报告）

用户实测：目标 210 分钟、均匀分布、周一至周日全允许，但计划被堆到周五（实测单日 130 分钟、
另一天 0 分钟）。实施计划 `docs/superpowers/plans/2026-10-08-v1.7.1-recurring-goal-even-distribution-fix.md`。

| 提交 | 内容 |
| --- | --- |
| `366634e7` | 用用户实测现象建立失败回归门槛（修复前：四天容量相同却排出 `90/90/30/0`）|
| `06b04b0b` | `AvailabilityBuilder` 不再按每日上限截断候选（实测 720 分钟空闲只返回 360）；每日上限改为在选块时判定 |
| `e756911e` | 新增容量感知的按日均分器 + `TaskDistributionPolicy` |
| `2c9c92fe` | 初次放置与局部改进共用按日预算；**旧的不均匀计划不再冻结偏斜** |
| `4e1017e1` | 节奏 → 策略映射；`algorithmVersion` 9 → **10**；删除 `_dailyQuota()` |
| `8e7d04c8` | 规模用例的等价剪枝 + 每日上限判定改为增量查表 |
| `e3aa2225` | 验收证据 `docs/testing/v1.7.1-recurring-even-distribution-acceptance.md` |

**验证**：`flutter test` **1629 通过 / 0 失败**；八个集成测试逐个跑 **8/8**；
真实库只读复核确认模板十项字段与计划一致、两个周期实例周界为本地周一、
当前已确认计划分布为 `30 / 130 / 0 / 50`（合计 210）。

**一处未达成的阈值**：计划要求取消候选截断后规模用例不超过原基线（1632 ms）两倍。
优化后约 2220 ms（3.25 s → 2.22 s），**仍未低于 3264 ms**。剩余成本在
`_overlapsAny` / `_violatesRestGap`（本质"候选数 × 块数"，需换区间树），属排程器核心重构，
计划 §6 明确不做。测试自带的 60 秒安全阈值以 27 倍余量通过。
重建后的验证：`flutter test` **1629 通过 / 0 失败**；`flutter analyze --no-pub` **0 问题**；
`dart format --set-exit-if-changed` **459 文件 0 改动**；MSIX `Get-AuthenticodeSignature` = `Valid`，
且 MSIX 的构建时刻**晚于** `data/app.so`（确认包内含最新代码）。


### 与 `1.6.2+37` 相比，本批次的四处**用户可见的实质变化**

1. **统计页从一条长列表变成四个页签**，并新增周期目标摘要卡（它明说"不计入上面的计划时长"）。
2. **周期目标**：可建"每周完成固定时长"的目标，按周生成普通任务实例交给既有排程器，
   带进度、跳过、暂停、提醒与容量缺口处置。**任务页有「周期目标」分组**，点进去能编辑、暂停、
   跳过本周、停止生成与**删除**（删除此前是个点了没反应的死入口）。
3. **修复"排不下的任务既不排也说不清原因"**：此前 15 分钟的任务配上默认片段 30–90 分钟会
   一个候选都产不出来（任务同时出现在"新增"和"未安排"里）；现在最终余量可短于最小片段，
   且未安排原因由引擎给出结构化说明（"任务要求连续 30 分钟，但截止前最长空档只有 20 分钟"），
   预览不再显示裸 UUID。
4. **课后十分钟缓冲**：课表导入的课程结束后默认留 10 分钟不排计划——上完课要离开教室，
   不可能直接接续。**只对课表导入的课生效**（自己建的会议不受影响），可在
   设置 → 规划规则 →「专注与任务片段」改动或填 0 关闭。

### 登记"已发布"的前提（尚未满足）

按 `version-policy.md` 第 7 节，本条目要改成"已发布"还需要：

- [ ] §8 人工脚本走完并保存结果（路线图 Task 13 Step 7）
- [ ] 已签名 MSIX 从 `1.6.2` **覆盖安装**成功、且不删用户数据库（Task 13 Step 10）
- [ ] 未安装环境**全新安装**成功（Task 13 Step 10）
- [ ] 候选包**用户体验确认**（§12 第 9 条）
- [ ] **GitHub Release 创建**、上传资产、下载后复核哈希（Task 13 Step 13，由用户执行）
- [ ] M1（详情导航返回位置）与 M8（关网与限流）的**人工核对**


## 1.6.2+37 / MSIX 1.6.2.0 — 2026-10-07（`1.6` 发布线收口）

| 项目 | 结果 |
| --- | --- |
| 状态 | **已发布**（2026-10-08）· GitHub Release [`v1.6.2-build37`](https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.6.2-build37) |
| MSIX 第四段为什么是 `0` | 收口期间我曾把它一路抬到 `.3`，**那是误用第 4 段**——三次改动（备份页路径泄漏、用户实测的两处反馈、M8 操作式引导）**都改了内容**，而第 4 段只用于"内容一字未改的重打包"。按用户 2026-10-08 的裁定撤回为 `1.6.2.0`，并在 `version-policy.md` **§4.02** 记下这条规则。撤回时因 Windows 不接受降级，走"卸载 → 重新安装"，**卸载前后数据库逐字节一致** |
| 变更范围 | **`1.6` 发布线的全部九个内部里程碑（M1～M9）合并交付**，**外加用户实测反馈的两处修复**：① **今天做完的事在今日与日历界面消失**——勾选完成→重排，已完成的块不再出现在新版本计划里，而"当天有当前版的块就只用当前版"这条规则让今天正命中，于是那条做过的记录整天消失；修法是当天在当前版之外再补上**已结束任务在过去时间里的块**（整段已过去、按任务去重、一版完整声明）；② 统计页时间范围**"自定义范围"常亮**——它写死成实心按钮，另三个是描边，于是不管选哪个都是它亮着；修法是由区间**反推**当前选中哪一个（`_rangeKindFor`）：任务状态筛选与真实卡片状态、可访问与可读基线、新建任务与领域项目闭环、今日执行与调整信任（含用户定义的「跳过本次」）、真实时间比例的周日历（时间轴模式）、课表导入错误恢复、统计与复盘（跨页面同色 + 图表对比度与图例）、设置页四组分组与当前值 + 未保存修改拦截、统一发布收口 |
| 版本段位 | **`1.6.1` → `1.6.2`**（抬第 3 段）：第二段被现行口径**固定为 `1.6`**（抬它就是 `1.7`，路线图 §13 禁止），因此第 3 段是唯一还剩的可用段位；收口批次首包，第四段 `0`；构建号全局递增 `+36` → `+37`。详见 `version-policy.md` §4.00 |
| 数据库 | **无结构变更、无迁移** |
| 排程算法 | **未改动**（M1～M8 均未改排程口径；「跳过本次」是既有的 `pendingSkips` 通道） |
| 统计口径 | **未改动**；只改了**取色来源**（改用共享解析器）与图表呈现方式（切片文字移到图例） |
| 新增测试 | 本轮 M5～M9、两处用户实测反馈、以及一处既有脆弱测试的修复合计新增 **113** 条（M5 33／M6 10／M7 27／M8 10／M9 版本一致性等），全套 **1073 项通过** |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：377 文件 0 改动，退出码 0；`flutter analyze --no-pub`：**0 问题**；`flutter test`：**1073 项通过**，退出码 0；**八条** Windows 集成测试逐条通过 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.6.2+37` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.6.2-build37-windows-x64-20261007` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.6.2-build37-windows-x64-20261007.zip`（34002961 字节，34 条目） |
| MSIX | 同目录内 `PersonalPlanner-1.6.2-build37-windows-x64-20261007.msix`；清单 `ShuoZhuang.PersonalPlanner` / `1.6.2.0` / x64 |
| EXE SHA-256 | `19EA3FF2520B9538D86D88BAF60137FFE204BDD9A62D7508FE7565FEA9DBC6D1` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与历次同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`，指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13` |
| 覆盖安装 | **成功**：从已装的 `1.6.1.0` **原位升级**到 `1.6.2.0`（未先卸载），包族名未变。**收口途中我曾把第四段抬到 `.1`/`.2`/`.3`，那是误用**（三次都改了内容，不属于"重打包"）——按用户 2026-10-08 的裁定撤回为 `1.6.2.0`；撤回时因 Windows 不接受降级，走"卸载 → 全新安装"，**卸载前后数据库 SHA-256 逐字节一致**，随后**全新安装**亦成功，两条路径下启动均 `Responding=True` |；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` **未变**（⇒ 数据容器路径不变）。升级前需先停掉在跑的旧进程（托盘常驻会让进程活着，否则 `0x80073D02`） |
| 全新安装 | **成功**：卸载到 0 个包之后 `Add-AppxPackage` 状态 `Ok` |
| 卸载保留数据 | **验证通过**：卸载前后数据库 SHA-256 **逐字节相同**（`B31E5BC8…`），文件仍在 |
| 启动检查 | 覆盖安装与全新安装两条路径下，从包目录启动后进程均 `Responding=True`（约 156 MB 工作集） |
| 用户数据 | 数据库 `F:\Documents\personal_planner.sqlite`，196608 字节，SHA-256 `B31E5BC813571F6221F9FE998FEE7CA597AB8B5E9FABDDA608DD353EEF2A8D7E`；20 张表，`tasks` 11 / `calendar_events` 21 / `areas` 5 / `plan_versions` 5 / `settings` 8。**安装、覆盖安装与卸载过程均未改动它** |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、一键安装器、安装说明、`SHA-256.txt` 与用户指南齐全；ZIP **34 条目**、**无** `user-data`／`.sqlite`／`.pfx`／诊断日志 |
| 隐私 | `.pfx` 与私钥**不进版本库也不进交付包**：签名按指纹从当前用户证书库选取，密码不出现在任何文件或命令里 |
| 用户指南 | `docs/release/1.6.2-build37-user-guide.md`（**已定稿**，九个里程碑逐节写明状态与限度） |
| Release Notes | `docs/release/1.6.2-release-notes.md`（叙述版）· `docs/release/1.6.2-changelog.md`（42 条逐条清单） |

### 登记"已发布"的依据（`version-policy.md` §7 四条逐条）

| §7 条件 | 落实 |
| --- | --- |
| 1. 选定唯一的最终便携包与已签名 MSIX | 便携目录 `PersonalPlanner-1.6.2-build37-windows-x64-20261007\` + ZIP + 同目录 MSIX（清单 `1.6.2.0`，签名 `Valid`） |
| 2. 补齐面向用户的更新说明 | `1.6.2-release-notes.md`（叙述版）、`1.6.2-changelog.md`（**42 条逐条清单**）、`1.6.2-build37-user-guide.md`（用户指南） |
| 3. 记录产物校验值和最终验证结果 | 见本批 `EXE／ZIP／MSIX／证书` 四个 SHA-256 与"格式／分析／测试"行 |
| 4. 在本台账登记"已发布" | **本行**（状态已改为"已发布"） |

路线图 §14「确认发布」要求的总人工清单，此前挂着的几项已在 2026-10-08 全部关闭：

- §13 第 3 条（导出与备份、被拒后可换位置重试）——**通过**
- §13 第 7 条（通知点击真实交互）——**用户人工验收通过**
- 覆盖安装的"记录数量一致"——**按正确顺序补做并通过**（先装 `1.6.1.0` 取基线 → 不卸载直接覆盖安装
  → **20 张表记录数与内容指纹全部一致**，`schema cookie` 未变）。此前标为"缺素材"的真实原因是
  **基线取晚了**（先装了新版才想取），而当时以为没有旧版包——实际上 `release\` 里
  `1.6.0-build35` 与 `1.6.1-build36` 都还在
- 用户对最终包的人工验收——**已完成**（M6 界面可改、M8 引导、M9 通知点击）
- GitHub Release 的创建与上传——**用户 2026-10-08 完成**

### 发布后核对（2026-10-08）

**不只信本地文件，而是把已发布的资产下载回来重新算哈希**：

| 资产 | 结论 |
| --- | --- |
| `PersonalPlanner-1.6.2-build37-windows-x64-20261007.zip` | 下载后 SHA-256 **与台账一致** ✅ |
| `PersonalPlanner-1.6.2-build37-windows-x64-20261007.msix` | 下载后 SHA-256 **与台账一致** ✅ |
| `PersonalPlanner-signing-cert.cer` | 下载后 SHA-256 **与台账一致** ✅ |

Release 状态：**非草稿、非预发布**，已标记为 **Latest**，tag `v1.6.2-build37`。

> Release 资产里另有一个 GitHub 建仓库时自动生成的 `default.txt`，与本项目无关，未删除。

## 1.6.1+36 / MSIX 1.6.1.0 — 2026-10-07

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 变更范围 | **"作息规律性"的范围不足状态**（纯展示修复）：统计页「今天」是默认范围，若该范围里只有一天有安排，这张图原先会画出一根横轴为那一天的柱子。现在改为说明"只有 1 天有安排，看不出作息规律"并指出把范围切到「本周」或「本月」；明细脚注保留 |
| 版本段位 | **`1.6.0` → `1.6.1`**（抬第 3 段）：批次里只有修复。`1.6.0.0` 已交付用户确认，不能再并入；新批次首包，第四段回到 `0` |
| 数据库 | **无结构变更、无迁移** |
| 排程算法 | **未改动** |
| 统计口径 | **未改动**：`RoutineMetric` 的计算一字未改，只有"范围里不足两天时怎么显示"变了 |
| 新增测试 | `analytics_review_sections_test.dart` 增两条：单日范围不画图且指出可用范围、两日以上照常画图。（先确认这两条在修前**红**：`Expected: no matching candidates / Actual: Found 1 widget with type "AnalyticsChart"`。） |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：345 文件 0 改动，退出码 0；`flutter analyze --no-pub`：**0 问题**；`flutter test`：**870 项通过**（上一批 868 + 新增 2），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.6.1+36` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.6.1-build36-windows-x64-20261007` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.6.1-build36-windows-x64-20261007.zip` |
| MSIX | 同目录内 `PersonalPlanner-1.6.1-build36-windows-x64-20261007.msix`；清单 `ShuoZhuang.PersonalPlanner` / `1.6.1.0` / x64 |
| EXE SHA-256 | `B98F4718E92C0FC9C8D973C1E34E21354079BE68F93AB775ECA1D06EBC13BDDE` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与上一批同值） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN` |
| 覆盖安装 | **成功**：从已安装的 `1.6.0.0` **原位升级**到 `1.6.1.0`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（第 14 次身份不变的覆盖安装）。升级前先关掉在跑的旧进程（`0x80073D02` 的前置条件） |
| 启动检查 | 升级后从开始菜单启动成功，进程持续运行 23 秒以上且 `Responding=True`（主窗口标题「智能日程」） |
| 用户数据 | 数据库 `F:\Documents\personal_planner.sqlite` 在升级前后**均为 196608 字节、修改时间未变**（安装过程未触碰数据） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、安装说明与一键安装器齐全；ZIP **33 条目**、**无** `user-data` |
| 尚缺 | **统计页新文案的人工确认**（切到「今天」时应看到说明而不是一根 10/7）由用户完成；该目录尚登记为候选构建，不是正式发布 |

### 复算时顺带确认的一件事：任务页应当是"全部 9 / 待安排 0 / 已安排 0 / 已完成 9"

用真实数据库算过：任务共 10 条，其中 **9 条 `completed`、1 条 `cancelled`**，**没有**任何 `open`／
`inProgress` 任务。因此任务页四个筛选应当是 `全部 9　待安排 0　已安排 0　已完成 9`。

**一个容易被误判成 bug 的点**：当前确认计划里那唯一一块（10/7 10:00–10:40）属于 `算法作业`，
而**该任务的状态是 `completed`**。按专项计划 §2.1，已完成任务即使残留时间块也归入"已完成"，
因此它会出现在「已完成」而**不是**「已安排」。这不是分类错乱，而是口径本身要求的行为——
人工核对时不要把这一条当成"已安排丢了"。

### 这个"bug"其实是一个正确但无用的图

用户报的是"作息规律性的表横轴日期都是 10/7"。查下来**计算是对的**：这张图按"有安排的本地日"
一天一根柱，而 `1.6.0` 之前**当前确认计划里只有一个时间块**（10/7 10:00–10:40），加上 10/7 当天
一场固定日程（19:00–20:00），于是"今天"这个默认范围里就只有 10/7 一天，图上自然只有一根柱。

**用真实数据库复算过**（只读，不改数据）：

| 范围 | 柱数 | 横轴标签 |
| --- | --- | --- |
| 今天（默认） | **1** | 10/7 |
| 本周 | 5 | 10/5、10/6、10/7、10/8、10/9 |
| 本月 | 22 | 10/1、10/2、10/5 … 10/30 |

问题因此不在计算，而在**一天之内的"作息规律"恒等于 0**（开工相差 0、收工相差 0）——这种图既
看不出规律，又让人以为横轴坏了。路线图 §11 已要求"空数据与单点数据使用专门状态"，本次正是兑现
那一条的第一个可交付切片。

### 顺带查清的两件事（本次不改，留档）

1. **计划侧数据比看上去少得多**：本月那 22 天里，**计划块只贡献 1 天**（10/7），其余全靠固定日程。
   已确认计划总共 1 个块、3 个旧版本各 1–3 个块（superseded，正确排除）。
2. **"删除这一次"的标记行是零长度的**（10/6 算法与数据结构、10/7 大学物理与最优化方法），
   `end_at_utc == start_at_utc`。统计侧已正确排除这类行（`_scheduledMinutes` 要求区间为正），
   日历页也不再返回它们，因此**不是数据损坏**——那是 `deleteOccurrence` 有意写的标记行。
   另外 `trend` 的日桶数比窗口多 1（本周 7 天返回 8 桶，含窗口前一天的 0），与"作息规律性"的
   日期口径不一致，值得在路线图 §11（统计与复盘）里单独核对。

## 1.6.0+35 / MSIX 1.6.0.0 — 2026-10-07

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 变更范围 | **任务清单的状态筛选**：新增「全部／待安排／已安排／已完成」四个筛选项（带数量、键盘可切、窄窗横向滚动）；卡片显示真实状态（`待安排 · 预计 50 分钟` / `已安排 · 13:00–14:30` / `已完成 · 实际投入 25 分钟`，逾期再加"已逾期 · 截止于…"）；任务页改为读取**全部**任务（此前只读未结束的，因此"已完成"永远是空的）；"是否已安排"只认**当前确认计划中尚未结束的时间块**；五种空状态各自说明原因；切换筛选退出多选、"已完成"里不提供多选 |
| 版本段位 | **`1.5.0` → `1.6.0`**（抬第 2 段）：批次含用户可感知的新功能，且向后兼容。`1.5.0.6` 已交付用户确认，不能再拿第四段当补丁计数器；新批次首包，第四段回到 `0` |
| 数据库 | **无结构变更、无迁移**：`watchAll` 只是新增一条查询，`schemaVersion` 未动 |
| 排程算法 | **未改动**：今日页、日历页、排程与统计行为均不变 |
| 新增测试 | `test/features/tasks/task_list_filter_test.dart`（31 条纯逻辑）、`test/features/tasks/task_list_status_filter_test.dart`（20 条 Widget）、`test/app/task_list_route_test.dart`（2 条路由装配）。**路由装配那两条做过变更验证**：把 `plans` 改成 `null` 后它立刻红（`已安排 1` → `已安排 0`），确认它真的守着"计划仓储被传进页面"这件事 |
| 格式／分析／测试 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：345 文件 0 改动，退出码 0；`flutter analyze --no-pub`：**0 问题**；`flutter test`：**868 项通过**（上一批 813 + 新增 55），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.6.0+35`（`FileDescription = 智能日程`） |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.6.0-build35-windows-x64-20261007` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.6.0-build35-windows-x64-20261007.zip` |
| MSIX | 同目录内 `PersonalPlanner-1.6.0-build35-windows-x64-20261007.msix`；清单 `ShuoZhuang.PersonalPlanner` / `1.6.0.0` / x64 / `CN=Shuo Zhuang, O=Personal User, C=CN` |
| EXE SHA-256 | `EE2A352635BF21A2B7309A406557D38F29DE7A1DDCFC08A6239C2AB240C09A61` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C`（与上一批同值；包内 `.cer` 仅公钥，`HasPrivateKey=False`） |
| MSIX 签名 | `Get-AuthenticodeSignature` = **`Valid`**（"已验证签名"），签名者与指纹未变（`9E157ECE535D16A224593CA39C084705A4FD3C13`） |
| 覆盖安装 | **成功**：从已安装的 `1.5.0.6` **原位升级**到 `1.6.0.0`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（第 13 次身份不变的覆盖安装）。首次尝试被 `0x80073D02`（"资源正在使用中"）拒绝，因为旧版进程仍在运行；关闭两个旧实例后即成功——这正是升级路径应有的行为，记录在此免得下次误判为打包问题 |
| 启动检查 | 升级后从开始菜单启动成功，进程持续运行 20 秒以上且 `Responding=True`（主窗口标题「智能日程」，工作集约 157 MB） |
| 用户数据 | 升级前 `F:\Documents\personal_planner.sqlite` = 196608 字节；升级后大小不变、文件未被替换。启动后因应用自身写入而更新（属正常） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、安装说明与一键安装器齐全；ZIP **33 条目**、**无** `user-data` |
| 尚缺 | **按新版界面的人工确认**（任务页筛选栏的实际显示与点击）由用户完成；该目录尚登记为候选构建，不是正式发布 |

### 这一批修掉的是一个"看得见但没人发现"的问题

任务页此前调用的是 `watchOpenTasks()`——**只返回未结束的任务**。于是"已完成"这一栏永远是空的，
用户做完一件事之后就再也看不到它、也无法把误完成的任务改回来；而与此同时，任务表里那些已完成、
已取消的记录一直躺在库里，没有任何界面能看到它们。这一批把读取口径换成 `watchAllTasks()`，
并把"是否已安排"从"任务表里的 `scheduled` 状态"改为**按当前确认计划的未来时间块现算**——
任务自身的持久化状态没有新增字段，仍然是同一份事实来源。

### 为什么"已安排"必须按时间块现算，而不能落库

`PlannerTask` 的注释里已经写过这条理由（`lib/domain/models/task.dart` 对 `TaskStatus` 的说明）：
`scheduled` 取决于"已确认计划中是否存在该任务的块"，与计划生命周期绑定。**一旦落库就会有两个
事实来源**——撤销、重排或换计划版本时必然有一个是旧的。这一批没有新增状态字段，而是每次按
`PlanRepository.current()` 重新算，因此"撤销后任务回到待安排"是自动成立的。

### 一个必须记住的测试陷阱（本次踩到并修掉）

Widget 测试的替身如果写成 `Stream.value(tasks.values.toList())`，它在页面重建时会**重放同一个
快照**：状态改了、界面看起来却没变。`task_list_status_filter_test.dart` 里的替身因此改成
**广播流 + 每次保存推一次全量**（与 `DriftTaskRepository` 同型），否则"取消完成后任务立即从已完成
里消失"那条断言是**假通过**。

## 1.5.0+34 / MSIX 1.5.0.6 — 2026-10-07

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 变更范围 | **只换了两张教程截图**（`01-today.png`、`04-calendar.png`），代码与 `+33` 完全相同。无逻辑、无数据库、无包身份变更 |
| 版本段位 | 仍是 `1.5.0`（用户已明确选择继续并入该未发布批次）；第 4 段 `5` → `6` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.5.0-build34-windows-x64-20261007` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.5.0-build34-windows-x64-20261007.zip` |
| MSIX | 同上目录内 `PersonalPlanner-1.5.0-build34-windows-x64-20261007.msix` |
| 新增证据 | `G:\best-planing\release\evidence-1.5.0-build33-BEFORE-duplicate-fix-today.png`（**修复前**的今日页：`算法作业` 出现 **3 次**，07:30、07:30、10:00）；`acceptance-1.5.0-build33-today-no-duplicate.png`（修复后只 1 次） |
| EXE SHA-256 | `E7F620DF536128B6A4629BD22A95CD2DB018F728A0E49780D56F087098894E27` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 格式／分析／测试 | `dart format --set-exit-if-changed` 340 文件 0 改动；`flutter analyze` 0 问题；`flutter test` **813 通过** |
| 覆盖安装 | 从 `1.5.0.5` 原位升级到 `1.5.0.6`，未先卸载（第 12 次身份不变的覆盖安装） |
| 包内教程图一致性 | 逐张比对构建输出与仓库 `assets/tutorial/`：**6 张全部一致**（哈希相等） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、安装说明与一键安装器齐全；ZIP **33 条目**、**无** `user-data`；签名 `Valid` |

### 为什么要为一个截图再出一个包

复核教程时发现 `assets/tutorial/01-today.png` 是**在 `1.5.0.3` 上拍的**——而那个版本正好有"已完成
待办重复"的缺陷。截图里 `算法作业` 出现 **3 次**（07:30、07:30、10:00）。**把一个已经修好的 bug
印进教程**，比截图过时严重得多：用户会以为那是正常效果。因此重拍并重新打包。

- 修复前的图**保留为证据**（`evidence-…-BEFORE-…png`），不是删掉了事——它同时是"用户的重复到底
  长什么样"的第一手材料。
- `04-calendar.png` 一并重拍（它同样是 `1.5.0.3` 拍的，且正好覆盖日历列改版）。

### 又一次被窗口状态坑到（记下来，避免第三次）

重拍时按老坐标点击，结果点到了错误页面、甚至截出一片空白。原因是**应用窗口被最小化了**：
`GetWindowRect` 返回 `-32000,-32000`（最小化的哨兵值），`PrintWindow` 随之失败并回落到全屏截屏，
而"点击"实际点在了别的窗口上。用 `ShowWindow(SW_RESTORE)` 恢复后窗口变成了**未最大化的
1280x720**（不是之前的 1920x1080），于是所有旧坐标同时失效。

**处理办法（已生效）**：先 `SW_MAXIMIZE` 回到已知布局；若仍不确定，就**在当前窗口状态下现场标定**
——逐个候选 y 点击、各截一张，把页面标题拼成一张图一次看完（这次标定出 350=今日 / 400=任务 /
450=领域 / 600=统计；150–300 与 550 之所以"都是日历"，是因为**点空时页面不变**，停在原页）。
标定花两张图的时间，远少于反复猜坐标。

## 1.5.0+33 / MSIX 1.5.0.5 — 2026-10-07（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`。**本次未提交**：工作树里带着用户既有的未提交改动 |
| 变更范围 | ① **改正** `+32` 的"已完成待办重复"修法（按本地日只取一版计划，不再跨版本求并集）；② 修 `+32` 引入的选择器**透光丢失**。无数据库结构变更、无包身份变更、无新功能 |
| 版本段位 | **仍是 `1.5.0`**（统计复盘改版批次，尚未发布）：本批含新功能，第 2 段已为该批次抬过；**第 3 位按 §2 保持 `0`**（它只用于"批次里只有修复"）。第 4 段 `4` → `5`。**用户 2026-10-07 明确选择"继续并入同一批次"**（当时 §2 的人工决定权在用户手上，且本批次只装过他一台机器） |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.5.0-build33-windows-x64-20261007` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.5.0-build33-windows-x64-20261007.zip` |
| Windows MSIX | `...\PersonalPlanner-1.5.0-build33-windows-x64-20261007\PersonalPlanner-1.5.0-build33-windows-x64-20261007.msix` |
| 验收截图 | `G:\best-planing\release\acceptance-1.5.0-build33-today-no-duplicate.png`（**今日里 `算法作业` 只出现一次**，实拍） |
| EXE SHA-256 | `7082824A5349E1043C63380FB14610496579A82E8DFFBF8EC35F8CCE76063CFF` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：340 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 完整测试 | `flutter test --no-pub`：**813 项通过**（`+32` 的 811 + 2：按本地日取一版的两种情形），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 版本 `1.5.0+33` |
| MSIX 清单／签名 | `ShuoZhuang.PersonalPlanner` / `1.5.0.5` / x64；`Get-AuthenticodeSignature` = `Valid`；发布者与指纹未变 |
| 覆盖安装 | 本机已从 `1.5.0.4` **原位升级**到 `1.5.0.5`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（第 11 次身份不变的覆盖安装） |
| 启动检查 | 升级后启动成功；今日页显示 `算法作业 10:00–10:40 · 学业` **一次**并带已完成对勾（实拍见验收截图）；"当前安排"随当前时刻推进到 12:00 的午餐时间 |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书、使用说明与**一键安装器**齐全；ZIP **33 条目**、**无** `user-data` |

### ④ "别人能不能装"——2026-10-07 用户提问后的核实结论

用户问"现在这个软件别人可以安装吗"。逐项核实（不是凭印象答）：

| 核实项 | 结果 |
| --- | --- |
| 签名证书性质 | **自签名**：`CN=Shuo Zhuang, O=Personal User, C=CN`，自签名=真，有效期至 2031-10-03 |
| 签名者指纹 | `9E157ECE535D16A224593CA39C084705A4FD3C13` |
| 随包 `.cer` 是否就是签名者 | **是**（指纹一致；台账里记的 `23FAE0…` 是**文件** SHA-256，不是指纹，此前措辞容易混淆） |
| 本机为什么能直接装 | 该证书已在 `CurrentUser\Root`、`CurrentUser\CA`、`LocalMachine\Root`；且 `AllowDevelopmentWithoutDevLicense=1`（开发者模式已开） |
| 别人直接双击会怎样 | 报"证书链已处理，但终止于不受信任的根证书"（`0x800B0109`）——**必须先安装证书** |
| 系统要求 | `MinOS 10.0.17763`（Win10 1809）；x64；**无** `PackageDependency`（不依赖 VCLibs 等框架） |
| 数据位置是否绑死本机盘符 | **否**：走 `getApplicationDocumentsDirectory()`（系统"文档"文件夹），便携版则写 EXE 旁的 `user-data`——换机器不会因为缺少 `F:` 盘而失败 |

**结论**：可以装，但 MSIX 需要接收者先"安装证书到受信任人（本地计算机）"（需管理员）；或者直接用**便携版 ZIP**（无需证书，仅 SmartScreen 提示一次）。为此补了随包的 `安装说明.txt`。

### ⑤ 用户反馈"手动翻证书库好麻烦" → 补一键安装器，并做**真机端到端验证**

用户："我想用 MSIX，但是你现在说的操作起来好麻烦"。于是新增 `installer/安装.cmd` +
`installer/install-planner.ps1`（源码在仓库，随包各复制一份）：

- `安装.cmd` 只做一件事：用 `powershell.exe -ExecutionPolicy Bypass -File` 调起 ps1。**刻意保持纯 ASCII**——`.cmd` 按 OEM 代码页读取，写中文会在部分机器上变乱码；中文全部放在 ps1 里。
- `install-planner.ps1`：自提权（不是管理员就用 `-Verb RunAs` 重启自己）→ 把证书导入
  **本地计算机 → 受信任人**（幂等）→ `Add-AppxPackage` 安装/原位升级 → 报告结果。
  存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 ANSI 读，中文全变乱码。
  另支持 `PLANNER_INSTALLER_NO_PAUSE=1` 跳过收尾的"按回车关闭"，供自动化验证使用。

**真机端到端验证（不是只在我这台已受信任的机器上试）**：脚本
`G:\best-planing\.tooling\test-installer.ps1` 会先确认 `LocalState` 为空（应用状态全在用户
文档库的 SQLite 里，卸载不丢数据），然后**卸载应用 → 把证书从两个"受信任的根"库里移除**，
再走接收者会走的那条路（`cmd /c 安装.cmd` → Windows PowerShell 5.1）：

| 步骤 | 结果 |
| --- | --- |
| 卸载 | 已移除 |
| 移除根信任后 | 根信任条数 `0`、受信任人条数 `0` |
| 此时裸装 MSIX | **失败**（`0x80073CF0`）——反证"证书这一步确实必需" |
| 跑 `安装.cmd` | 证书已导入受信任人（指纹 `9E157ECE…`）；**安装成功，版本 `1.5.0.5`** |
| 复核 | 受信任人 `1` 条、应用 `1.5.0.5` |
| 第二次运行（升级场景） | "已经受信任…跳过导入"，版本仍 `1.5.0.5`，**证书未堆重复项**（仍 `1` 条） |
| 收尾 | 启动成功 `Responding=True`；根信任已还原（`2` 条）；用户数据库 `F:\Documents\personal_planner.sqlite` 完好 |

**这次验证抓到一个真 bug，值得记下**：第一版 ps1 用
`Import-Certificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'`，在
`powershell.exe`（Windows PowerShell 5.1）+ `-NoProfile` 下直接报
**「Cannot find drive. A drive with the name 'Cert' does not exist.」**——那个会话里证书提供程序
尚未加载，而 `-CertStoreLocation` 的参数值只是一个字符串，解析不到 `Cert:` 盘。因为此前只在
"证书早就受信任"的机器上手动跑过（那条路径根本没被执行），差点把不能用的安装器交付出去。
**改用 .NET 的 `X509Store` API**，与宿主、与提供程序加载顺序都无关。

**教训**：给别人的安装器，必须在"和对方一样的初始条件"下试过——在自己已经配置好的机器上点通，
证明不了任何事。这条与 ①（没看用户数据就下结论）是同一类错误：**验证条件不等于交付条件。**

**交付完整性（更新）**：ZIP 现为 **33 条目**（24 + 6 张教程图 + `安装说明.txt` + `安装.cmd` +
`install-planner.ps1`），**无** `user-data`。

### ① 重复：上一版规则本身是错的（用户当场发现"还是没有改善"）

用户报"已完成**待办**重复"后，`+32` 的做法是"按 (任务, 开始时刻) 去重 + 同一任务时间重叠再挡一次"。
用户复测后说"还是没有改善"。**把用户的真实库摊开看**（`tool/db_stats_probe.dart` 新增两段转储：
所有版本的计划块明细、同任务同开始时刻的重复候选），才看清两件事：

- `算法作业`：当前版 **10:00**、旧版 **07:30** —— 同一件事在**同一本地日**的两个不同时刻；
- `大物预习课`（已完成）：旧版 **50+90 分钟**、新版 **90+50 分钟** —— 同一件事在两版里各有一套，
  且时长与起止都被挪过。

于是按 id、按开始时刻、按"同任务重叠"都只能消掉一部分。**真正的错在方法上**：`+32` 把各版本的块
**求并集**，而"一版计划是对那段时间的完整声明"——求并集在语义上就是错的。

**改正后的规则（按本地日逐个决定）**：

1. 该本地日**当前确认版本有块** → 只用当前版本（今天/未来都走这一支，因此"改到别的时间"不会
   再同时显示新旧两个位置）；
2. 该本地日**当前版本没有块、且这一天已完整过去**（`dayEnd <= now`）→ 用"当天结束时在用的那一版"
   （`versionCreatedAtUtc <= dayEnd` 中最新、且当天确实排了块的那一版）——这是"当时排了什么"的还原；
3. 其余留空：今天/未来当前版本来就没排，就不该从历史里捞回来。

配套改动：端口 `PlanBlockHistory` 改为返回 `HistoricalPlanBlock`（块 + 所属版本 id + **版本生成
时刻**）——不带版本生成时刻，调用方就只能求并集。本地日按**本机时区零点**切（用 UTC 日界会让跨
零点的一晚同时落进两天）。

**测试**：两条用例直接照用户数据建模——"今天：当前版本说过的时间只算一次"（`算法作业` 07:30/10:00）
与"已经过去的那一天在两版里各有一套块时只显示当时在用的那一版"（`大物预习课` 50+90 / 90+50）；
另有一条守住"同一天拆成不重叠两段时两段都保留"，防止去重用力过猛。

**教训**：`+32` 是在**没有看用户数据**的情况下按推测修的，用户复测即打回。诊断类改动应当先把真实
数据摊开（这次补上了两段转储），再下结论。

### ② 选择器透光：`+32` 为修对比度把底色写成了实心色

用户："选择统计范围下面日历区域原先是有透明度的，可以看到下面，现在没了"。

成因：`ColorScheme.surface` 取的是**玻璃半透明色**（`PlannerGlassTheme.surface`，如 `0xcc142131`），
选择器日历区因此原本能透出下层界面；而 `+32` 的 `plannerPickerTheme` 把
`rangePickerBackgroundColor` / `backgroundColor` / `headerBackgroundColor` 都写成了**不透明**的
`PlannerPalette.surface` / `surfaceRaised`，并且额外覆盖了 `dialogTheme` 的底色——于是透光消失。

**修法**：底色一律从 `ThemeData.extension<PlannerGlassTheme>()` 取玻璃色，**只改对比度、不改透光**；
并**撤掉对 `dialogTheme` 的覆盖**（第一版把对话框形态也变成了实心板，而这次要的只是"按钮看得见"）。

**测试**：`planner_pickers_test.dart` 直接钉住 `alpha < 1`（选择器与时间选择器的底色、头部底色），
以后谁再把它写成实心色都会红。

### ③ 用户对版本号的质询与决定

用户问"这些都不用加在第三位版本号上吗？"。按 `version-policy.md` §2：第 3 位只在"批次里**只有修复**"
时 +1，而本批次含用户可感知的新功能（统计复盘矩阵，随后又并入新手教程与日历列改版），因此
**第 3 位保持 `0`**；第 2 段已为该批次抬过（`1.4.2` → `1.5.0`），同一批次重打包只动第 4 位。

同时如实指出：`1.5.0` 批次在宣告之后**内容已扩充**（新增新手教程、日历 昨天/今天/明天、设置页版本号），
按 §3 的 `1.4.2` 先例，未发布批次可以并入，但**这是 §2 保留给人工的决定**，因此把三个选项交给用户
选择。**用户选择"保持 `1.5.0+33` / MSIX `1.5.0.5`"**，即继续并入同一未发布批次。

## 1.5.0+32 / MSIX 1.5.0.4 — 2026-10-07（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动 |
| 变更范围 | ① 修日期／时间选择器按钮看不清（对比度 + 中文本地化两个原因，全库 9 处）；② 七日日历加"昨天"列并改成 昨天/今天/明天/周几；③ 设置页底部显示版本号；④ **新增新手教程**（真实截图 + 分步引导 + 首次启动触发 + 设置入口）；⑤ 修"重排后过去已完成的计划从视图消失"；⑥ 修⑤引入的"已完成待办重复"。无数据库结构变更、无包身份变更 |
| 版本段位 | **仍是 `1.5.0`**（统计复盘改版批次，尚未发布）；构建号 `+29` → `+32`，第四段 `1` → `4`。中间两次打包（`+30` / `1.5.0.2`、`+31` / `1.5.0.3`）**同批次内已被取代**，只在本机安装过 |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.5.0-build32-windows-x64-20261007` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.5.0-build32-windows-x64-20261007.zip` |
| Windows MSIX | `...\PersonalPlanner-1.5.0-build32-windows-x64-20261007\PersonalPlanner-1.5.0-build32-windows-x64-20261007.msix` |
| 验收截图 | `G:\best-planing\release\acceptance-1.5.0-build32-tutorial.png`（**首次启动自动弹出的教程**，实拍） |
| EXE SHA-256 | `99E7F8EA548245D1533A742AE6485C533F0726FF62E20A55E53E139F9FDA7AF4` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：340 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 完整测试 | `flutter test --no-pub`：**811 项通过**（比 `+29` +2：历史保留 + 去重回归），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 版本 `1.5.0+32` |
| MSIX 清单／签名 | `ShuoZhuang.PersonalPlanner` / `1.5.0.4` / x64；`Get-AuthenticodeSignature` = `Valid`；发布者与指纹未变 |
| 覆盖安装 | 本机已从 `1.5.0.3` **原位升级**到 `1.5.0.4`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（第 10 次身份不变的覆盖安装） |
| 启动检查 | 升级后启动成功；**首次启动自动弹出新手教程**（实拍见验收截图），教程进度、跳过、上一步禁用、下一步都正常 |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP **30 条目**（24 + 6 张教程图）、**无** `user-data`；`AssetManifest.bin` 里 6 张图都有登记，安装目录下的资产束与构建输出逐字节同尺寸 |

### ① 选择器按钮：一次修到"这一类"，而不是那一个

用户截图里那个飘着的 `Save` 是根因的**第二个**原因。诊断（`showDateRangePicker` 打开后 dump 屏上
全部文字）拿到的是：`Save, 选择统计范围, Oct 8, – , Oct 8`——**确认按钮是英文的 `Save`，月份是
`October 2026`**。两个原因：

1. **全局 `textButtonTheme` 把前景色设成 `PlannerPalette.textSecondary`**，而选择器的"取消／应用"
   正是 `TextButton` → 深色面板上几乎看不见。修法：`plannerPickerTheme` 给选择器套一层高对比主题
   （主文本色 + 填充 + 描边，实测对比度 12:1），并把选择器面板自身的配色也给全。
2. **应用从未配置 Material 本地化**，于是自带控件回落到英文。修法：加 `flutter_localizations`，
   `PlannerLocalization` 里钉死 `zh_CN`，两个 `MaterialApp`（路由形态与外壳形态）都接上；
   全屏形态的确认按钮用的是 `saveText`（不是 `confirmText`），因此显式传「应用」。

**修在 9 处调用点而不是 1 处**：统计范围、任务到期日、执行时间、学期日期、节次时间……它们继承
的是同一个主题，因此缺陷也是同一个。只修用户看到的那一个，等于把同类问题留给下一个用户发现。

**测试**：`planner_pickers_test.dart` 同时钉住"基础主题确实是灰的"（缺陷前提）与"选择器主题换成了
主文本色且对比度达标"；`analytics_page_test.dart` 在**真实调用点**上断言 `Save` 与 `October 2026`
都不再出现、`应用`出现、前景色是主文本色。

### ② 七日日历：昨天 + 今天起七天，像天气应用

用户原话："七日日历可以再'今天起 7 天'的基础上加上昨天，就像手机上的天气预报一样"，随后细化为
"要是昨天 今天 明天，然后后面就是周几周几"。

- 渲染下标改成 `-1..6`：`-1` 是昨天、`0` 仍是今天（因此既有的 `week-day-0` 用例与「查看当日」语义
  都不必改），`1` 是明天，`2..6` 显示周几。
- **订阅窗口左移一天**（`weekStart - 1 天` 起）：不少订阅这一天，昨天那一列会永远空白，看起来像
  "昨天没有安排"——假空比不显示更糟。
- 今天那一列用主色描边 + 更亮的底，八列里一眼能找到（天气应用同样会把今天标出来）。

### ③ 设置页底部显示版本号

`SettingsHubPage` 新增可选 `versionLabel`，由路由器传入 `appVersion`（`backup_assembly.dart` 的常量，
与 `pubspec.yaml` 的一致性由 `version_consistency_test` 守着）。这一页仍然不认识版本也不需要认识。
为空时整行不渲染，而不是显示"未知版本"。测试断言它在**所有入口卡片之后**。

### ④ 新手教程

七步（欢迎 + 六个主页面），每步一张**真实界面截图** + 标题 + 说明 + 要点；可前后翻、可跳过，
底部有进度条与`第 X / 7 步`。两个入口：**首次启动自动弹出**（`onboarding.tutorialSeen.v1`，
与首次引导同一条"设置键 + 版本比较"套路，排在引导之后——引导定默认值、教程讲用法），以及
**设置 → 新手教程**随时重看。

**截图是从发布构建上逐页采集的**（`.tooling/capture-planner.ps1`，`PrintWindow` + 程序化点击），
不是示意图；`pubspec.yaml` 按目录登记 `assets/tutorial/`。测试里有一条守卫：**步骤里写的每一张图
必须在仓库里真的存在**——否则"加了步骤忘了截图"要等到用户第一次打开教程才会发现。

**采集过程本身有两条教训**（都写进了 tools 注释）：① 截图比点击慢一拍，必须"一次点击、另一次
专门截图"；② 点击坐标与截图像素之间存在**随窗口位置变化**的偏移（实测同机先后差 40~66px），
因此先做一次"点四个候选 y、把页面标题拼成一张图"的标定，再批量采集。

### ⑤ 重排之后过去已完成的计划消失

用户原话："如果我后续的计划需要进行重排，已完成的计划在视图里就不需要改变了啊，像昨天已经完成
计划在我刚才调整计划后就都不见了"。

成因：`RepositoryScheduleViewSource` 只读 `plans.current()`（最新一版），而重排会新建版本并把旧版
标成 `superseded`——过去几天当时排了什么，只留在旧版本里。

修法：新增端口 `PlanBlockHistory.blocksInWindow`（`DriftPlanRepository` 实现，**不按 `status` 过滤**），
数据源把窗口内的历史块里**已经发生**的那些补进来。未来时段一律以最新计划为准，否则"把任务改到
别的时间"会同时显示新旧两个位置。依据是"已经发生的事不该被后来的计划改写"。

**为什么是新端口而不是加宽 `PlanRepository`**：与 `PlanHistoryRepository` 同一理由——全库有多个
测试替身只实现 `current()`/`applyProposal`，加宽会一次性牵动它们。

### ⑥ 紧接着的重复（⑤引入的回归，用户当场发现）

用户："为什么现在的已完成待办有重复的？"

成因：重排与撤销会给**同一个安排分配新的块 id**，而⑤只按块 id 去重 → 同一件事从新旧两版各出现一次。
修法：按 **(taskId, startUtc)** 去重（同一任务不可能同时出现在两个位置），并保留当前版本那一条。

**RED 已验证**：把键去重临时去掉，回归用例立刻报
`Expected: an object with length of <1> / Actual: [Instance of 'ScheduleViewItem', Instance of 'ScheduleViewItem']`
——正是用户看到的两条重复。

### 过程中的一次误判，如实记录

实现④的过程中，我在**电脑进入睡眠、我的会话拿不到交互桌面**时截出一片纯白的窗口，并据此怀疑是
`flutter_localizations` 在 release 下导致白屏，做了两次"改源码 + 重新构建"的实验（其中一次脚本
卡住、`finally` 没跑到，源码一度停在诊断改动上，已当场还原并复验）。

用户回到机器后说明"电脑开睡眠模式了"——**白屏是截图拿不到画面的假象，不是应用的问题**。教训：
在把某个现象当作代码缺陷之前，先确认观测手段本身是否有效（`CopyFromScreen` 报"句柄无效"就是
桌面不可用的直接证据，当时已经拿到却仍继续按代码缺陷推测）。

## 1.5.0+29 / MSIX 1.5.0.1 — 2026-10-07（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动 |
| 变更范围 | **统计复盘按用户要求整体重做**：① 领域占比计入**固定日程**；② 移除页面上全部"计划/实际"内容（并在规格 §8.9.1 记录口径偏离）；③ 拆成"领域占比（横向）"与"时间总计（纵向）"两个可视化；④ 图表类型**逐卡片可选并持久化**；⑤ 新增 领域覆盖缺口、逾期率、休息时长(A)、作息规律性(C)、工作与休息比例(D)。无数据库结构变更、无包身份变更 |
| 版本段位 | **仍是 `1.5.0`**：与 `1.5.0.0` 属同一批次（统计复盘改版）且尚未发布，因此只抬第四段；构建号全局单调递增 `+28` → `+29` |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.5.0-build29-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.5.0-build29-windows-x64-20261006.zip` |
| Windows MSIX | `...\PersonalPlanner-1.5.0-build29-windows-x64-20261006\PersonalPlanner-1.5.0-build29-windows-x64-20261006.msix` |
| 验收截图 | **本次未能采集**——见下方"未采集到的证据" |
| EXE SHA-256 | `DDF922F58E04F33C570D9676EFBA25D7589383099A0200079770E719FF7C08E6` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：332 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 完整测试 | `flutter test --no-pub`：**787 项通过**（比上一版 +25），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.5.0+29` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.5.0.1` / x64；发布者未变 |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`；签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`；指纹同上。**未加时间戳**，与既有实测状态一致 |
| 覆盖安装 | 本机已从 `1.5.0.0` **原位升级**到 `1.5.0.1`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（第 8 次身份不变的覆盖安装） |
| 启动检查 | 升级后从开始菜单启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.5.0.1_x64__v9555qkaxdyym`，`Responding=True`；诊断日志 `2026-10-07T00:03:50` 干净启动并完成提醒同步（`scheduled=11 cancelled=0 canSchedule=true`） |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的**大小、修改时间与 SHA-256 完全一致**（`1CEF3DD0976FA8609021255C40452D757795DDC942E252BC8718CC6FFF9860B3`） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP 24 条目、**无** `user-data` |

### ① 领域占比此前漏掉了用户最大的一块时间（本轮最重要的一条）

用户 2026-10-06 的原话：**"领域时间分配为什么不把固定日程统计进去，有的固定日程不是也有领域的吗"**。

**这是我的漏项，而且原因比"忘了加"更具体**：`AnalyticsDataset` 里**根本没有日历事件**——只有
`tasks`／`plannedBlocks`／`actualEntries`／`events`。于是 `domainDistribution` 只统计任务计划块。
用户库里 **19 场固定日程（16 场带领域、学业占 15）**、每周 20 多小时课表，而计划块只有 6 块
（合计 180 分钟）——占比因此严重失真。

修法：把固定日程（按重复规则展开、已应用单次例外与"这一次被删除"标记）加进数据集，领域占比按
**计划块 + 固定日程**合计，并把两个来源分开记（界面写明"计划 X 分钟 + 固定日程 Y 分钟"），
免得用户以为那个大数字是自己排任务排出来的。矩阵排序也随之改用**总占用**而非实际投入——否则
"有课表但还没记实际投入"的领域会沉到底部，而那正是用户库里的情况。

**展开与例外处理刻意复用 `DriftCalendarRepository.occurrencesBetween`**：那套约定（重复、跨午夜例外、
零长度删除标记）只应有一份实现，统计层再抄一遍就是第二个"两端约定不一致"的坑（技术设计 §13.0 的 W5
踩过一次）。`AnalyticsDao` 因此改成**必填** `calendar` 参数——可选会让"忘了注入"表现为"固定日程
静默不计入领域占比"，而那正是本轮要修的缺陷本身。

### ② 移除"计划/实际"：这是一次**口径偏离**，已按 §20 记录

用户要求"和计划/实际相关的全部去掉，这个程序原先的本质就是计划"。但 `FR-STAT-03`（"展示计划时长、
实际投入、完成率、按期完成率、延期率和预计偏差"）与 `FR-STAT-09`（"明确区分计划数据、实际数据和
推断结论"）是规格里的硬性要求，而规格 §20 明确写着"**改变统计口径须重新获得明确确认并更新本文档**"。

因此本轮**没有**悄悄删掉了事：在规格新增 **§8.9.1 2026-10-06 统计口径变更**，逐条写清 FR-STAT-03／
04／05／09 各受什么影响、哪些保留（完成率／按期／逾期／FR-STAT-06 全部不变），并更新了
`docs/testing/manual-windows-checklist.md` 的 7.3 验收项（其原文正是"计划时长与实际投入分开显示"）。

**范围严格限定在统计页**（用户明确选择"只从统计页拿掉，其他功能不动"）：专注计时、补录、导出
（仍区分计划与实际）、`time_entries` 表、`AnalyticsDataset.actualEntries` 管道**全部保留**，
将来要收回这次偏离只需改呈现层。

页面里那句"计划、实际投入和推断结论分别展示"的口径说明也一并改了——留着一句介绍用户看不到的东西，
比没有介绍更糟。

### ③ 图型可选（用户："各个统计的图表类型可以由我来选择"）

- `ChartKind`（饼图／柱状图／条形图／折线图）+ `AnalyticsChartSlot`（5 个位置）。
- **可选项按数据形状给**：占比类不提供折线（会让人以为它在讲趋势），时间序列不提供饼图。
  给得出但画出来看不懂不算选择自由。`allowedKinds` 与 `defaultKind` 写在一处，`switch` 不写默认分支，
  将来加位置时编译器会指到每一处需要补的地方。
- **持久化**在 `analytics.chartTypes.v1`；非法值／不存在的类型／对该位置不合法的类型一律回落到默认，
  读取失败也回默认——"打开统计页就崩"不是处理脏数据的合理方式。写入前校验该位置是否允许该类型。
- **切换时先改界面再持久化**：写设置可能失败，而"点了一下没反应"比"选择没被记住"更让人困惑。
- **"条形图"是手绘的**：`fl_chart` 没有横向柱状图，硬凑只能把纵向图 `RotatedBox` 转 90°（分类名也得
  跟着转，读起来要歪着头），而条形图真正的用处恰恰是分类名很长的时候。

### ④ 新增的三个"休息"指标与一个"规划"指标

用户先否掉了我最初列的 7 条**违规检测**类指标（"保护被侵占""空隙密度"…），改为**直接读数**；
下面四条是他确认后的清单：

| 指标 | 口径 |
| --- | --- |
| **休息时长（A）** | 各类保护窗口（睡眠／午餐／晚餐／固定休息）在范围内的容量，以及**被已确认计划块或固定日程占用**的分钟数；达成率 = 未被占用比例 |
| **作息规律性（C）** | 每天开工／收工时刻（本地）的**极差**与平均——看的是波动，不是"几点最密"（他那句"不是为了知道一周哪节课多这种谁都知道的东西"） |
| **工作与休息比例（D）** | 工作·学习 / 生活 / **空着的休息** / 未安排 四段划分，不重不漏覆盖整个范围。"空着的休息"是减去被安排占用之后的，所以把任务排进睡眠不会让报表显得"休息充足" |
| **领域覆盖缺口（#2）** | 哪些领域在范围内一个计划块、一场固定日程都没有。**必须带出全部领域**：零占用的那些不会出现在任何分布里，只看有数据的一侧永远算不出它们。用户库里 科研／竞赛／工作 正是零占用 |

三项休息指标**全部只读计划侧数据**，一条都不读 `actualByEntry`——这是"把实际投入从统计里拿掉"
在实现上的落点，测试里也刻意不喂实际记录（喂了就红）。

**同时修掉一处旧缺陷**：保护时段按天展开时从**范围首日**开始走，于是跨午夜保护段（睡眠默认
23:00–07:00）锚定在**前一天**的后半段（首日 00:00–07:00）被整个漏掉——7 天范围只报 2940 而不是
3360 分钟，界面上一除就成"平均每天只睡 6 小时"。旧口径下它淹没在一句长文案里，本轮把"休息时长"
提到显眼位置才暴露。末日边界也一并修正（`endUtc` 是排他上界，直接用它的日期会多算一天）。
展开逻辑抽成 `_protectedInstances` 供旧新三处共用——那段有两个踩过的坑（`endMinute == 1440` 会抛
参数错误、跨午夜必须用日历加法），只应有一份实现，抄第二份等于给下一个改代码的人准备一个
"只修好一半"的机会。

### ⑤ 全量测试净增 25 项

`test/application/analytics_review_metrics_test.dart`（9 条，四项新指标的口径）、
`test/application/analytics_chart_preference_service_test.dart`（8 条，可选项、回落、非法值）、
`test/features/analytics/analytics_review_sections_test.dart`（8 条，图型切换与持久化、休息三卡、
覆盖缺口、"计划/实际"确实不再出现），另有 `test/data/analytics_dao_test.dart` 与
`test/domain/area_period_matrix_test.dart` 各补 2 条固定日程用例。

**测试写过两次错、都由它自己抓出来**：① 断言"占比类菜单里没有折线图"时满页查找，结果命中了作息卡
选择器上显示的"折线图"三个字——改成只查弹出菜单里的项；② 全为 0 的周期仍画出了矩阵表，因为判据用了
`matrix.isEmpty`（领域仍在分布里、只是分钟数为 0），改成与图表空状态一致的 `totalMinutes > 0`。

### 未采集到的证据（如实记录）

本版的**验收截图没有采集到**，与上一版同一原因：`Graphics.CopyFromScreen` 报 `句柄无效`——当前会话
取不到交互桌面（屏幕锁定／会话断开），`PrintWindow` 因此也只能返回空白位图。空白图**已删除**，
不留在验收目录里冒充证据。

因此以下几条**只有 widget 测试覆盖，没有人眼确认**，请明早看一眼：

- 领域占比现在是否"看着对"（课表应当占大头）；
- 饼图/柱状/条形/折线四种画法的实际观感，以及默认类型是否合适；
- 休息那一节是否回答了"有没有好好休息"；
- 矩阵表的密度、各卡片图型选择器是否好点。

应用本身健康（`Responding=True`、诊断日志干净启动、`1.5.0.1` 已原位安装），因此这不影响"装得上、
打得开"的判断，只影响观感判断。

## 1.5.0+28 / MSIX 1.5.0.0 — 2026-10-06（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动 |
| 变更范围 | ① **新增**「领域 × 周期」矩阵（统计复盘的主视图改为领域时间分配）；② 移除口径重复的领域分布饼图，把"计划 / 实际"与"每日趋势"降为次要；③ 修「勾选完成后计划块变成『已安排任务』」；④ 新增「已完成」标记；⑤ 「领域与项目」页卡片补行间隔。无数据库结构变更、无包身份变更 |
| 版本段位 | **第 2 段 +1（`1.4.2` → `1.5.0`）**：本批次含用户可感知的新功能，按 `version-policy.md` 第 2 节属 Minor 而非 Patch |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.5.0-build28-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.5.0-build28-windows-x64-20261006.zip` |
| Windows MSIX | `...\PersonalPlanner-1.5.0-build28-windows-x64-20261006\PersonalPlanner-1.5.0-build28-windows-x64-20261006.msix` |
| 验收截图 | **本次未能采集**——见下方"未采集到的证据" |
| EXE SHA-256 | `929B7A0CD0CB64059FA09BC4093EA7A81E2C17B22DF2A2B0D589D49DFE168C6B` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：325 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 完整测试 | `flutter test --no-pub`：**758 项通过**（比上一版 +8），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.5.0+28` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.5.0.0` / x64；发布者未变 |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`；签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`。**未加时间戳**，与既有实测状态一致 |
| 覆盖安装 | 本机已从 `1.4.2.5` **原位升级**到 `1.5.0.0`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（第 7 次身份不变的覆盖安装）。Minor 抬段顺带把第四段归零，`1.5.0.0` 仍高于 `1.4.2.5`，因此不构成版本倒退 |
| 启动检查 | 升级后从开始菜单启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.5.0.0_x64__v9555qkaxdyym`，`Responding=True`；诊断日志 `2026-10-06T23:23:19` 干净启动并完成提醒同步（`scheduled=11 cancelled=0 canSchedule=true`） |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的**大小、修改时间与 SHA-256 完全一致**（`68DCF2AB51482BB71067B81C348AB829BAEBDB0B4BC8287FE0E396396863EAC5`） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP 24 条目、**无** `user-data` |

### ① 领域 × 周期矩阵（本版的重点）

用户的原话是"现在的统计都聚焦在计划和实际的对比上，这不符合我的个人需求，我希望是领域时间分配的
横向纵向对比"，并在确认时选定"领域 × 周期矩阵（堆叠柱 + 矩阵表）"、口径选"计划块时长"。

- **纯数据层** `lib/domain/models/area_period_matrix.dart`：`buildAreaPeriodMatrix` 把若干
  `(周期标签, 报告)` 组装成矩阵。领域取各周期出现过的**并集**（"上周做了、这周没做"必须成行，
  否则纵向对比会缺掉最该看见的那一格），缺失周期补 0，行按合计降序、同合计按名称升序（顺序可复现）。
  **只读 `plannedMinutes`**，刻意不暴露 `actualMinutes`——免得下一个做的人顺手混进来。
- **页面**：矩阵固定取上周 / 本周 / 本月三个周期（不随上面的范围选择漂移），列在 `_Overview` 之前。
  周期边界一律走本机时区日界，与页面既有口径一致。
- 6 条纯单测钉住排序、并集、补零、占比、空周期不除零、以及"只取计划块"。

**页面测试改编过程中的两处真实发现**：

1. 插入矩阵后 **`find.text('本月')` 不再唯一**（范围按钮 + 矩阵表头 + 柱状图坐标轴各一个），
   既有测试的 `tester.tap(find.text('本月'))` 变成"找到 3 个"而失败。四个范围按钮因此各加了 key
   （`analytics-range-today/week/month/custom`），测试改按 key 点击。
2. **空状态判据一开始写错了**：`matrix.isEmpty` 判的是"没有行"，但领域仍会出现在报告的分布里
   （只是计划块为 0），所以行是存在的——一张全 0 的表没有信息量。改成按**合计为 0** 判定，并留下
   一条专门喂"实际投入不为 0、计划块为 0"的测试。

### ② 移除领域分布饼图（一次判断，理由写在这里）

原饼图按**实际投入**统计，新矩阵按**计划块**统计。两者都叫"领域分布"却数字不同，并排摆着只会让人
怀疑哪个是真的。既然用户要的是领域时间分配成为主视图，饼图**移除**、领域视角只留矩阵一个入口；
「计划 / 实际」与「每日趋势」保留但降到矩阵下面。这是**可逆**的（代码在提交历史里），若你觉得还想
要实际投入的领域视角，可以按"实际 vs 计划"做成矩阵的第二组列。

### ③ 完成后不再变成「已安排任务」

`RepositoryScheduleViewSource` 只从 `watchOpenTasks()` 取标题与领域。已确认的计划块不会因为勾选完成
而消失（只有重排才会去掉），但任务已经离开"未结束"集合，于是标题回退成字面量 `'已安排任务'`、
领域退化成「无领域任务」→ **卡片颜色跟着变**。修法：对查不到的 block id 逐个补查一次
`tasks.getById()`。

**RED 已实测**：把补查临时改成空操作，测试报 `Expected: '已经做完的事' / Actual: '已安排任务'`。

### ④ 「已完成」标记

`ScheduleViewItem` 新增 `isCompleted`，两个来源：任务计划块（所属任务 `completed`）与固定日程
（`range.endUtc` 已过）；保护时间不参与。判定用可注入的 `Clock`，测试因此能固定"现在"。
三个页面各画一个 muted 色对勾，并写进无障碍语义。

**这条测试还抓到了一个真缺陷**：今日页会把条目**拷贝**成"按当天裁剪过区间"的副本，第一版漏拷
`isCompleted`，于是标记在这一页永远不显示——测试当场报 `Found 0 widgets`。已补上并加注释。

### ⑤ 「领域与项目」页卡片间距

全局 `cardTheme.margin` 是 `EdgeInsets.zero`，三处列表直接连续铺 `Card`，相邻卡片的圆角边框因此
贴在一起（实测上一张下边框 `y=522`、下一张上边框 `y=523`）。三处各补 `margin: EdgeInsets.only(bottom: 8)`。

**断言方式值得记下**：量像素试了三种写法都不成立——对 `Card` 取 rect 会把它内部的 `margin` 一起算
进去（间隔恒读成 0）；量内层 `Material` 抓到的不是卡片表面；量彩色圆点按钮时去掉外边距后读数
**完全不变**（28 → 28），是假绿。最终改为直接钉"声明的下边距"，**RED 已实测**：去掉边距后
`Actual: <null>`。

### 未采集到的证据（如实记录）

本版的**验收截图没有采集到**。尝试时窗口渲染为空白，定位结果是**环境问题而非应用问题**：

- `Graphics.CopyFromScreen` 报 `句柄无效`——当前会话已取不到交互桌面（屏幕锁定或会话断开）；
- `PrintWindow` 因此也拿不到内容，返回空白位图；
- 同时应用本身健康：进程 `Responding=True`，诊断日志显示干净启动并完成提醒同步。

那张空白图**已被删除**，不留在验收目录里冒充证据。因此矩阵的实际观感（堆叠柱的颜色搭配、表格密度、
8px 间隔是否够）**只有 widget 测试覆盖，没有人工视觉确认**——请你打开统计页看一眼。
`release\acceptance-1.4.2-build26\` 仍可作为配色基线。

**为什么还不是正式发布**：用户尚未完成界面体验确认（`version-policy.md` 第 7 节第 2、4 条）。

## 1.4.2+27 / MSIX 1.4.2.5 — 2026-10-06（未发布，已并入 1.5.0）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动 |
| 变更范围 | ① 修「勾选完成后计划块变成『已安排任务』且丢掉领域色」；② 新增「已完成」标记（任务勾选完成、固定日程时间已过）；③ 「领域与项目」页卡片补 8px 行间隔。不改数据结构、不换包身份 |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.4.2-build27-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.4.2-build27-windows-x64-20261006.zip` |
| Windows MSIX | `...\PersonalPlanner-1.4.2-build27-windows-x64-20261006\PersonalPlanner-1.4.2-build27-windows-x64-20261006.msix` |
| 验收截图 | **本次未能采集**——见下方"未采集到的证据" |
| EXE SHA-256 | `EF05AEA7E624DAF7469475E52E88921BE97342A08C2D50D91B0B8D9F8958B51D` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：323 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 完整测试 | `flutter test --no-pub`：**750 项通过**（比上一版 +6），退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.4.2+27` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.4.2.5` / x64；发布者未变 |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`；签名者同上；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`。**未加时间戳**，与既有实测状态一致 |
| 覆盖安装 | 本机已从 `1.4.2.4` **原位升级**到 `1.4.2.5`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变（这是同批次第 6 次身份不变的覆盖安装） |
| 启动检查 | 升级后从开始菜单启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.4.2.5_x64__v9555qkaxdyym`，`Responding=True`；诊断日志 `2026-10-06T23:09:31` 干净启动并完成提醒同步（`scheduled=11 cancelled=0 canSchedule=true`，说明包身份正常） |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的**大小、修改时间与 SHA-256 完全一致**（`58FB2DD35ECDCC9ED9CF35E4893E44C51762821E441D046B854F3FD986F03983`） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP 24 条目、**无** `user-data` |

### ① 完成后不再变成「已安排任务」

`RepositoryScheduleViewSource` 只从 `watchOpenTasks()` 取标题与领域。已确认的计划块**不会**因为
勾选完成而消失（只有重排才会去掉），但任务已经离开"未结束"集合，于是 `titles[block.taskId]` 查不到
→ 标题回退成字面量 `'已安排任务'`，同时 `areaIds[block.taskId]` 为 null → 分类退化成「无领域任务」
→ **卡片颜色跟着变**。用户看到的正是"勾完之后任务变成了另一个分类"。

修法：对查不到的 block id **逐个补查一次** `tasks.getById()`，保留真实标题与领域；只补查缺的，
正常情况下一次都不会走到。测试同时覆盖了"完成与未完成同领域必须同色"。

**RED 已实测**：把补查临时改成空操作，测试报 `Expected: '已经做完的事' / Actual: '已安排任务'`。

### ② 「已完成」标记

`ScheduleViewItem` 新增 `isCompleted`，两个来源：

- **任务计划块**：所属任务 `status == completed`；
- **固定日程**：`range.endUtc` 已过（固定日程没有"勾选"动作，它的完成就是时间过去）；
- **保护时间不参与**：它不是待办。

判定用可注入的 `Clock`（默认 `SystemClock`），这样测试能固定"现在"，不会跟挂钟走。三个页面各画一个
muted 色对勾（今日 `today-schedule-completed-*`、七日 `week-schedule-completed-*`、
单日 `day-schedule-completed-*`），并写进无障碍语义。

**这条测试抓到了一个真缺陷**：今日页会把条目**拷贝**成"按当天裁剪过区间"的副本，我第一版漏拷
`isCompleted`，于是标记在这一页永远不显示——测试当场报 `Found 0 widgets`。已补上并加注释。

### ③ 「领域与项目」页卡片间距

全局 `cardTheme.margin` 是 `EdgeInsets.zero`，而「领域」「特殊日程颜色」「项目」三处列表都是直接
连续铺 `Card`，于是相邻卡片的圆角边框**贴在一起**（实测上一张下边框 `y=522`、下一张上边框
`y=523`）。三处的 `Card` 各补 `margin: EdgeInsets.only(bottom: 8)`。

**这条断言刻意钉"声明的下边距"而不是量像素**：量像素试了三种写法都不成立——对 `Card` 取 rect 会把
它内部的 `margin` 一起算进去（间隔恒读成 0）；量内层 `Material` 抓到的不是卡片表面；量彩色圆点按钮
时去掉外边距后读数**完全不变**（28 → 28），是假绿。契约本身就是"这三处卡片各留一段行间隔"，直接钉
它既准确又不会骗人。**RED 已实测**：去掉边距后 `Actual: <null>`。

### 未采集到的证据（如实记录）

本版的**验收截图没有采集到**。尝试时窗口渲染为空白，定位结果是**环境问题而非应用问题**：

- `Graphics.CopyFromScreen` 报 `句柄无效`——当前会话已取不到交互桌面（屏幕锁定或会话断开）；
- `PrintWindow` 因此也拿不到内容，返回空白位图；
- 同时应用本身健康：进程 `Responding=True`，诊断日志显示干净启动并完成提醒同步。

那张空白图**已被删除**，不留在验收目录里冒充证据。因此"已完成标记看起来如何""8px 间隔够不够"
这两条**只有 widget 测试覆盖，没有人工视觉确认**——请你在界面上看一眼。本版之前的
`release\acceptance-1.4.2-build26\` 仍可作为配色基线。

**为什么还不是正式发布**：用户尚未完成界面体验确认（`version-policy.md` 第 7 节第 2、4 条）。

## 1.4.2+26 / MSIX 1.4.2.4 — 2026-10-06（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动，计划要求不重置、不覆盖、不整理无关文件 |
| 变更范围 | **公式级修订**：卡片底色从「往表面色按比例混」改为「取色相 + 限饱和度 + 二分求解明度到统一亮度」。不改数据、不换包身份、不新增功能 |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.4.2-build26-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.4.2-build26-windows-x64-20261006.zip` |
| Windows MSIX | `...\PersonalPlanner-1.4.2-build26-windows-x64-20261006\PersonalPlanner-1.4.2-build26-windows-x64-20261006.msix` |
| 验收截图 | `G:\best-planing\release\acceptance-1.4.2-build26\`（今日） |
| EXE SHA-256 | `F18DFF380076B798AEE289E85F5647D59245857FA33FFEE8898F5ED15F6CBCB1` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：323 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 定向测试 | 共享派生器 + 材质模式 + 七日 + 单日 + 今日 五个套件：60 项通过 |
| 完整测试 | `flutter test --no-pub`：**744 项通过**，退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.4.2+26` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.4.2.4` / x64；发布者 `CN=Shuo Zhuang, O=Personal User, C=CN`（未变） |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`；签名者同上；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`。**未加时间戳**，与既有实测状态一致 |
| 覆盖安装 | 本机已从 `1.4.2.3` **原位升级**到 `1.4.2.4`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变。此前已完成 `1.4.1.0 → 1.4.2.0 → 1.4.2.1 → 1.4.2.2 → 1.4.2.3`，五次都保持同一身份 |
| 启动检查 | 升级后从开始菜单启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.4.2.4_x64__v9555qkaxdyym`，窗口响应正常 |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的**大小、修改时间与 SHA-256 完全一致**（`FE628D6658A8BD1EA4AE45C73691D3C2D29C725757A352D82FAB006ADBBC8090`） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP 24 条目、**无** `user-data` |

**为什么必须换公式，而不是继续调比例**：用户第四轮的反馈是"**颜色比老版的浅还淡，看着还亮**"。
把它拆开看，`lerp(表面色, 分类色, t)` 这种派生把两件事绑死了——**越往深混，彩度掉得越干净**：

| 阶段 | 琥珀色填充 | HSV 彩度 | 八色填充亮度 |
| --- | --- | ---: | --- |
| `lerp(…, 0.26)` | `#4e473c` | 23% | 0.040 ~ 0.062 |
| `lerp(…, 0.18)` | `#3c3b39` | 7% | 0.0325 ~ 0.0447 |
| `lerp(…, 0.12)` | `#2f3336` | **13%** | 0.0254 ~ 0.0326 |
| **色相+彩度+亮度（当前）** | **`#463011`** | **83%** | **0.0335 ~ 0.0348** |
| 旧版（1.0.11）保护时间 | `#49371f` | 58% | 0.0425 |

所以前三次"降比例"只会让卡片**更灰**：`0.12` 的琥珀 `#2f3336`（R47 G51 B48）就是一块中性灰——
既没有彩度（"淡"），又是被提亮的灰（"浅""亮"）。而旧版卡片底色的实测彩度是 **58% ~ 79%**，性格是
"**深 + 有彩度**"。要同时满足两者，色相/彩度与明度必须分开控制。

**公式**：`toneAtLuminance(c, target)` = 取 `c` 的色相；饱和度取 `min(饱和(c), 0.60)`；二分求解明度，
使 `computeLuminance()` 等于 `target`。`fill` 用 `0.034`、`border` 用 `0.065`。

两个取舍都记在这里：① 明度用二分**求解**而不是固定一个明度值——同样的明度下黄色比蓝色亮得多，
固定明度会让八张卡重量散到 `0.0108 ~ 0.0274`（2.54 倍），求解后是 `0.0335 ~ 0.0348`（1.04 倍）；
② 饱和度取 `min(原色饱和度, 0.60)` 而不是直接套 `0.60`——本来就灰的色板色（灰蓝 `#7f92b2`）不该
被硬拉成彩色。

**像素实测（今日，同一位置三对照）**：

| 卡片 | 1.0.11 旧版 | `1.4.2.3`（混 12%） | `1.4.2.4`（当前） |
| --- | --- | --- | --- |
| 无领域任务 | `#2B353C` 亮度 0.0339 彩度 28% | `#212F40` 0.0273 彩度 48% | `#2A3546` **0.0348** 彩度 40% |
| 保护时间 | `#1B3543` 0.0318 彩度 60% | `#1D3547` 0.0326 彩度 59% | `#113843` **0.0335** 彩度 **75%** |
| 生活（用户自定义 `#C07A8C`） | — | `#292C3C` 0.0260 彩度 32% | `#512631` **0.0336** 彩度 **53%** |

亮度和旧版对齐（**不比旧版亮**），彩度从"灰"恢复到"有彩度"。

**已知代价**：八张卡的**色相差**比旧版大（RGB 曼哈顿距离最大 164；旧版今日页 23、七日页 83）。
这是语义决定的——旧版底色只服务三种任务类型且刻意挑成几乎同色，现在要承载八个领域色。分类身份
因此由左侧强调条、图标与图例共同承担。

**为什么还不是正式发布**：用户尚未完成界面体验确认（`version-policy.md` 第 7 节第 2、4 条）。

## 1.4.2+25 / MSIX 1.4.2.3 — 2026-10-06（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动，计划要求不重置、不覆盖、不整理无关文件 |
| 变更范围 | 按用户反馈"配色的主要问题是太亮了"压暗卡片：填充比例 `0.18` → `0.12`，描边比例 `0.32` → `0.16`。不改数据、不换包身份、不新增功能 |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.4.2-build25-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.4.2-build25-windows-x64-20261006.zip` |
| Windows MSIX | `...\PersonalPlanner-1.4.2-build25-windows-x64-20261006\PersonalPlanner-1.4.2-build25-windows-x64-20261006.msix` |
| 验收截图 | `G:\best-planing\release\acceptance-1.4.2-build25\`（今日） |
| EXE SHA-256 | `EEE05E3308557730DB81C2F9A98698E98406E968D0059E5BB8D7E729793DD39E` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：323 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 定向测试 | 共享派生器 + 材质模式 + 七日 + 单日 + 今日 五个套件：60 项通过 |
| 完整测试 | `flutter test --no-pub`：**744 项通过**，退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.4.2+25` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.4.2.3` / x64；发布者 `CN=Shuo Zhuang, O=Personal User, C=CN`（与 `1.4.1.0` 完全相同） |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`；签名者同上；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`。**未加时间戳**，与既有实测状态一致 |
| 覆盖安装 | 本机已从 `1.4.2.2` **原位升级**到 `1.4.2.3`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变。此前同一台机器已完成 `1.4.1.0 → 1.4.2.0 → 1.4.2.1 → 1.4.2.2`，四次都保持同一身份 |
| 启动检查 | 升级后从开始菜单（AUMID `…!personalplanner`）启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.4.2.3_x64__v9555qkaxdyym`，窗口响应正常 |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的**大小、修改时间与 SHA-256 完全一致**（`01CBB09F120F882A6DC25DDA50FE03946B0AA415399CC9961E9BB827DC6B3990`） |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP 24 条目、**无** `user-data` |

**判定依据是实测亮度，不是主观描述**。用户的原话是"配色的主要问题是太亮了"，把它换算成数字后
确认成立——对照旧版（1.0.11）实测卡片底色 `#2C353E` / `#1C3743`（即 `0.0338 ~ 0.0343`）：

| 构建 | 比例 | 八色填充亮度 | 八色描边亮度 |
| --- | --- | --- | --- |
| `1.4.2+24` | `0.18` / `0.32` | 0.0325 ~ **0.0447** | 0.0850 ~ 0.1239 |
| `1.4.2+25` | `0.12` / `0.16` | **0.0254 ~ 0.0326** | **0.0610 ~ 0.0771** |
| 旧版实测参照 | — | 0.0338 ~ 0.0343 | 0.0420 ~ 0.0907 |

**`0.18` 的问题在"亮端"而不是平均值**：它的平均亮度 0.0389 只比旧版高约 14%，看起来"差不多"，
但**最亮的那几张（青蓝 `0.0447`、琥珀 `0.0438`、青绿 `0.0429`）比旧版亮约三成**——用户看到的
就是这几张。`0.12` 让八色**逐色**落在旧版之下（各色降幅 21% ~ 27%）。

描边一并降到 `0.16` 是被填充连带的：`0.32` 的描边亮度 `0.0850 ~ 0.1239` 比旧版更亮，且填充变暗后
它相对更抢眼，卡片的"亮"会转移到边线上。`0.16` 落回旧版区间，同时保持"可辨认但不发光"。

**像素实测（今日·保护时间卡，原来最亮的一张）**：

| 构建 | 左缘（边框 / 强调条 / 底色） |
| --- | --- |
| `1.4.2+24` | `3B6880` / `5EC8E5`×4px / `213F51`（0.0447） |
| `1.4.2+25` | `325268` / `5EC8E5`×4px / `1D3547`（0.0326） |

**强调条刻意保持满强度**（`5EC8E5` 未变）：它就是分类身份的载体，压暗它等于把颜色信息一起丢掉。

**为什么还不是正式发布**：用户尚未完成界面体验确认（`version-policy.md` 第 7 节第 2、4 条）。

## 1.4.2+24 / MSIX 1.4.2.2 — 2026-10-06（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动，计划要求不重置、不覆盖、不整理无关文件 |
| 变更范围 | 修掉今日页两处**装饰件被量成 0 高、根本画不出来**的缺陷：① 卡片左侧分类强调条；② 有安排时的今日容量条。**配色未改动**（仍为 `_fillMix = 0.18`），不改数据、不换包身份、不新增功能 |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.4.2-build24-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.4.2-build24-windows-x64-20261006.zip` |
| Windows MSIX | `...\PersonalPlanner-1.4.2-build24-windows-x64-20261006\PersonalPlanner-1.4.2-build24-windows-x64-20261006.msix` |
| 验收截图 | `G:\best-planing\release\acceptance-1.4.2-build24\`（今日、七日日历） |
| EXE SHA-256 | `249DC64AE93666FB950B5FB2C50B2357391B6E7EFBE54A7FFE32EE6E62AD13CF` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：323 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 定向测试 | 今日页套件 13 项通过（含 2 条新增的"装饰件必须有面积"回归断言） |
| 完整测试 | `flutter test --no-pub`：**744 项通过**，退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.4.2+24` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.4.2.2` / x64；发布者 `CN=Shuo Zhuang, O=Personal User, C=CN`（与 `1.4.1.0` 完全相同） |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`；签名者同上；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`。**未加时间戳**，与既有实测状态一致 |
| 覆盖安装 | 本机已从 `1.4.2.1` **原位升级**到 `1.4.2.2`，**未先卸载**；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变。此前同一台机器已完成 `1.4.1.0 → 1.4.2.0 → 1.4.2.1`，三次都保持同一身份 |
| 启动检查 | 升级后从开始菜单（AUMID `…!personalplanner`）启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.4.2.2_x64__v9555qkaxdyym`，窗口响应正常 |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的**大小、修改时间与 SHA-256 完全一致**（`9CD5427F5F47B08F3F78EB3233EFDE530FEA342160D9D0A124559A12B4CD725F`）。升级并启动后 `tool/db_fingerprint.dart` 逐表指纹为 **20 张表 / 95 行**：20 张表全部存在，其中 19 张行数与上一轮完全相同，仅 `settings` 由 5 增至 6——来自应用自身在两次取样之间的正常使用，**不是丢失** |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书与使用说明齐全；ZIP 24 条目、**无** `user-data` |

**这次修的是什么（以及为什么此前没被测出来）**：两个装饰件在代码里都"存在"，但都被量化成了
**零面积**控件：

- `ColoredBox` 没有子节点，**内在高度为 0**；
- 它所在的 `Row` 用的是默认的 `CrossAxisAlignment.center`，因此不会被拉伸。

结果是 `tester.widget<ColoredBox>(…).color` 这类**只断言颜色**的测试照样通过，屏幕上却什么都
没有。用户正是这样发现的——**"断言了正确的值"不等于"断言了看得见"**。

| 装饰件 | 修前（像素实测） | 修后 |
| --- | --- | --- |
| 今日卡片左侧强调条 | 高度 `0.0`（左缘只有边框、没有彩色条） | 高度 `70.0` = 卡片内区高；左缘实测 `45576F`(边框) → `7F92B2`×4px → `273548`(底色) |
| 今日容量条（有安排时） | 每段高度 `0.0`（整条不可见） | 每段高度 `7.0`；截图可见按分类占比的实色分段 |

两者的回归断言都改为**断言尺寸**（竖条须铺满卡片内区、容量条各段须铺满容器给的 7 像素），且
参照值从控件自身声明的 `margin`/`border` 推导，而不是写死常数。

**尚未实施的用户决定（写在这里以免丢失）**：用户已选择按「只把填充比例降到 `0.12`」处理卡片底色
（当前仍为 `0.18`），但要求本轮**先单独交付竖条修复**。因此该配色变更**不在本构建内**；实施时必须
同步改 `lib/features/calendar/schedule_category_card_style.dart`、八色常量表与规格 §7，并按版本
规则抬升后重新构建。

**为什么还不是正式发布**：用户尚未完成界面体验确认（`version-policy.md` 第 7 节第 2、4 条）。

## 1.4.2+23 / MSIX 1.4.2.1 — 2026-10-06（同批次内已被取代）

| 项目 | 结果 |
| --- | --- |
| 状态 | **候选构建，等待用户体验确认**（**不是**正式发布） |
| 分支／工作树 | `feature/native-implementation`，HEAD `9cac630`。**本次未提交**：工作树里带着用户既有的未提交改动，计划要求不重置、不覆盖、不整理无关文件 |
| 变更范围 | 日程卡片配色纠偏。新增 `lib/features/calendar/schedule_category_card_style.dart`；改动今日页、七日日历、单日详情三个页面；配套 4 个测试文件与新增材质模式测试。**不改数据库结构、不改领域色板、不换包身份、不新增功能** |
| Windows 目录 | `G:\best-planing\release\PersonalPlanner-1.4.2-build23-windows-x64-20261006` |
| Windows ZIP | `G:\best-planing\release\PersonalPlanner-1.4.2-build23-windows-x64-20261006.zip` |
| Windows MSIX | `G:\best-planing\release\PersonalPlanner-1.4.2-build23-windows-x64-20261006\PersonalPlanner-1.4.2-build23-windows-x64-20261006.msix` |
| 验收截图 | `G:\best-planing\release\acceptance-1.4.2-build23\`（7 张：今日 × 无玻璃／极致、七日日历 × 无玻璃／极致、单日详情 × 极致、升级后安装版今日、三代对比图） |
| EXE SHA-256 | `34E2D6BCD1250D64AB4E95685420347967AC5C5E1851E4180A613C30F5307E85` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool`：322 个文件，0 个改动，退出码 0 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题，退出码 0 |
| 定向测试 | `flutter test --no-pub`（共享派生器 + 材质模式 + 七日 + 单日 + 今日 五个套件）：59 项通过 |
| 完整测试 | `flutter test --no-pub`：**743 项通过**，74 秒，退出码 0 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.4.2+23` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.4.2.1` / x64；发布者 `CN=Shuo Zhuang, O=Personal User, C=CN`（与 `1.4.1.0` 完全相同） |
| MSIX 签名 | `Get-AuthenticodeSignature` = `Valid`（“已验证签名”）；签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13`。**未加时间戳**，与 `1.4.1.0` 的实测状态一致（`signtool_options` 未含 `/tr`） |
| 覆盖安装 | 本机已从 `1.4.2.0` **原位升级**到 `1.4.2.1`，**未先卸载**：`Add-AppxPackage` 成功；包族名 `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` 未变。此前同一台机器还完成过 `1.4.1.0` → `1.4.2.0` 的原位升级，两次都保持同一身份 |
| 启动检查 | 升级后从开始菜单（AUMID `ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner`）启动成功；进程来自 `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.4.2.1_x64__v9555qkaxdyym`，窗口响应正常，三个页面均按新深色卡片渲染 |
| 本地数据保留 | 安装前后 `F:\Documents\personal_planner.sqlite` 的大小、修改时间与 SHA-256 **完全一致**（`F00905673D0EEB16A8FD0FA16425B8E1392DC8883FBD36AC6D44AE56EA008624`）；`tool/db_fingerprint.dart` 的逐表行数指纹升级＋启动后仍为 **20 张表 / 94 行**，逐表相等 |
| 交付完整性 | 便携目录、ZIP、已签名 MSIX、签名公钥证书（`PersonalPlanner-signing-cert.cer`）与使用说明（`使用前请读.md`）齐全；ZIP 内**无** `user-data` |

**这次批次修的是什么**：`1.4.1` 的卡片底色是 `分类色.withValues(alpha: 0.18)`、描边是
`分类色.withValues(alpha: 0.72)`，且三个页面各写了一套（今日 `0.10`）。半透明填充让底下的玻璃
面板透上来参与混色，于是卡片发白、亮度偏高、描边发光，同一事项在三个页面深浅不同，玻璃模式越
激进卡片越被冲淡。本批次把这件事收回一个共享派生器：

```text
accent = 分类色
fill   = lerp(PlannerPalette.surface, 分类色, 0.18)   // 完全不透明
border = lerp(PlannerPalette.outline, 分类色, 0.32)   // 完全不透明
```

**证据**：八色精确值、不透明度、填充亮度上限 `0.07`、强调色与文字对比度在三处测试里被钉住；
四种玻璃模式 × 三个页面共 13 条测试断言 `fill`/`border` 不随材质漂移；对升级后的真实窗口截图做
像素取样，同一张卡片在“无玻璃”和“极致”下都是 `#273548`（无领域任务）、`#213F51`（保护时间）、
`#333141`（生活），而旁边的玻璃面板本身在两种模式下不同（`#142131` / `#142431`）——**该变的变，
不该变的不变**。

**填充比例为什么最终是 `0.18` 而不是第一版的 `0.26`**：`1.4.2+22`（MSIX `1.4.2.0`）用 `0.26`
打包并安装后，用户看着实际界面反馈“仍然偏淡”。核对确认 `0.26` 只解决了“不透明、不漂移”，对色板
里较浅的颜色反而比修复前更亮。实测同一张「无领域任务」卡片：

| 版本 | 卡片底色 | 相对亮度 |
| --- | --- | ---: |
| `1.4.1`（半透明 `0.18`，会被背景影响） | `#213145` | 0.0295 |
| `1.4.2+22`（不透明 `0.26`） | `#303E52` | 0.0468 |
| `1.4.2+23`（不透明 `0.18`） | `#273548` | **0.0345** |
| 旧版按任务类型的卡片（用户 13:45 截图） | `#2D363F` | 0.0356 |

`0.18` 下八色填充亮度落在 `0.033–0.045`，与旧版 Material 深色容器 `#173e39` / `#163b67` /
`#49371f`（`0.039` / `0.043` / `0.043`）同一条带——这才是“回到旧版重量”。**描边比例不随之调整**：
填充越深描边只会越清楚，而“不发光”取决于描边的绝对比例。

**同批次内已被取代的构建**：`1.4.2+22` / MSIX `1.4.2.0`（填充比例 `0.26`），产物仍在
`G:\best-planing\release\PersonalPlanner-1.4.2-build22-windows-x64-20261006*`，仅在开发机安装过，
**不是**交付版本；第四段抬到 `1` 的完整判定见 `version-policy.md` 第 4 节。

**已知的诚实限度**：`fill = lerp(surface, 分类色, 0.18)` 是按**旧版亮度重量**对齐的，不是按色相
对齐。领域配色与旧的“按任务类型”配色本来就是两套语义（例如“保护时间”在旧版是深琥珀 `#49371f`，
现在是深青 `#213F51`），卡片看起来的颜色**不可能**逐张相同。派生器保证的是：不透明、不随材质漂移、
描边不发光、三个页面逐值一致、文字与强调色对比度达标。

**为什么还不是正式发布**：用户尚未完成界面体验确认（`version-policy.md` 第 7 节第 2、4 条）。

## 1.4.1+21 — 2026-10-06

| 项目 | 结果 |
| --- | --- |
| 状态 | **开发构建／待验收** |
| Windows 目录 | `PersonalPlanner-1.4.1-build21-windows-x64-20261006` |
| Windows ZIP | `PersonalPlanner-1.4.1-build21-windows-x64-20261006.zip` |
| Windows MSIX | `PersonalPlanner-1.4.1-build21-windows-x64-20261006.msix` |
| EXE SHA-256 | `8243C1623C7AE71410A128A3E7E5E7E3B935556AFF75019CA9355FF6EE82AECF` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| MSIX SHA-256 | `98BBCB95F7CE42877939D779792BDEC255D582A213FE617569B47A42382F8387` |
| 证书 SHA-256 | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test`：316 个文件，0 个改动 |
| 静态分析 | `flutter analyze --no-pub`：0 个问题 |
| 完整测试 | 721 项通过 |
| Windows Release | `flutter build windows --release --no-pub` 成功；EXE 文件版本与产品版本均为 `1.4.1+21` |
| MSIX 清单 | `ShuoZhuang.PersonalPlanner` / `1.4.1.0` / x64 |
| MSIX 签名 | `Valid`；签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`；指纹 `9E157ECE535D16A224593CA39C084705A4FD3C13` |
| 覆盖安装 | 本机已从 `1.4.0.0` 更新到 `1.4.1.0` |
| 启动检查 | 从已安装包目录启动，进程响应正常；安装前后现有数据库大小与修改时间一致 |
| 交付完整性 | 便携目录、ZIP、MSIX、签名公钥证书和使用说明齐全；ZIP 无 `user-data` |

本批次修正 `1.4.0+20` 只交付便携版、无法覆盖安装已存在 `1.4.0.0` 的问题，并从此要求每个可体验
版本同时提供便携版与已签名 MSIX。正式发布仍需用户完成界面与通知点击等人工验收。

## 1.4.0+20 — 2026-10-06

| 项目 | 结果 |
| --- | --- |
| 状态 | **开发构建／待验收** |
| Windows 目录 | `PersonalPlanner-1.4.0-build20-windows-x64-20261006` |
| Windows ZIP | `PersonalPlanner-1.4.0-build20-windows-x64-20261006.zip` |
| EXE SHA-256 | `73909020CA2ABDE9C0F17D583AB8543F30E3DE8CA25B45C5D84C88E5EF2FF851` |
| ZIP SHA-256 | `6CC6FD2AB26039AAFCADCD79D02106042AC48A4FB6112680B0252424BE028834` |
| 静态分析 | `flutter analyze --no-pub`：0 个问题 |
| 功能测试组 | 80 项通过 |
| 完整测试 | 721 项通过 |
| Windows Release | 构建成功；交付包仅包含本次便携构建，不包含输出目录中残留的旧 MSIX |
| 启动检查 | 便携 EXE 从交付依赖目录直接启动，进程响应正常；测试进程与临时数据已清理 |

本批次包含系统托盘与窗口后台行为，以及日程按领域、保护和无领域分类配色。以下情况均有自动化
回归覆盖：颜色保存与重新读取、三个日程页面共享分类来源、相同颜色的不同分类不合并、失效领域
分别回退为无领域任务或无领域固定日程、跨午夜容量裁剪。

正式发布仍需：确认候选包、完成界面人工验收，并把本条状态改为“已发布”。