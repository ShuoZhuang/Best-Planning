# 日历、计划预览与排程完整性修复 —— 验收记录

> 实施计划：`docs/superpowers/plans/2026-10-13-calendar-preview-and-scheduling-integrity-repair.md`
> 本文件只记录**实际执行过的命令、退出码、测试数与结论**。
> 未运行的项目写 `NOT RUN`，受环境阻断写 `BLOCKED`，不留空、不写"应该通过"。

## 0. 基线与环境

| 项目 | 值 |
| --- | --- |
| 工作树 | `G:\best-planing\.worktrees\native-implementation` |
| 分支 | `feature/native-implementation`（未 push、未 rebase） |
| 起始 HEAD | `9623858d`（`docs: add the course and protection acceptance checklist`） |
| 记录时的 HEAD | `6130a2d8`（本计划最后一次提交） |
| 本计划的提交 | `c2876380`（Task 1 测试基线）、`febb8692`（Task 2）、`37c85ee1`（Task 3）、`631bbf76`（Task 4）、`e0db23df`（Task 5）、`6eb80435`（Task 6）、`958f6071`（Task 7）、`03582360`（Task 8）、`dffddf0a`（集成夹具修正）、`6130a2d8`（Task 9） |
| Flutter | `3.47.5`（stable，Dart `3.13.4`），经 `G:\best-planing\.tooling\fx.ps1` 调用 |
| 算法版本 | `15` → **`16`** |
| 软件版本 | `version` **未改动**（仍 `1.8.0+44`）；**MSIX 第四段 `1` → `2`**（2026-10-14，用户明确要求：本机已装 `1.8.0.1` 且那是修复前的构建，`Add-AppxPackage` 不接受更低版本） |

**运行方式说明**：本会话里 `flutter.bat` 会在 `bin/internal/shared.bat` 处卡住（嵌套
PowerShell 不返回），因此全部命令都写成 `& G:\best-planing\.tooling\fx.ps1 <args>`
——它用 SDK 自带的 `dart.exe` 直接执行缓存的 `flutter_tools.snapshot`，与 `flutter.bat`
等价。下表记录的是等价写法。

**本计划对工作树的改动范围**（`git diff --stat 9623858d..HEAD`）：64 个文件、
+11888 / −1114。其中**触碰数据层的只有一处**：`lib/data/database/daos/analytics_dao.dart`
补上 JSON 规则路径缺失的 `breakfast → 早餐` 映射（计划 §2.5 要求），**不含任何 schema、
迁移、备份格式或包身份改动**。

## 1. 已确认缺陷的红灯 → 绿灯证据

每条都在 Task 1 用**行为断言**写下红灯（不是编译错误），并在所属 Task 修好后转绿。

| 编号 | 红灯断言（修复前实测） | 修复 | 转绿位置 |
| --- | --- | --- | --- |
| R1 早餐显示成"保护时间" | `Expected: contains '早餐'` / `Actual: MappedListIterable<ScheduleViewItem, String>:['保护时间']` | `BusyInterval.protectedKind` + `protectedTimeKindLabel()`（`lib/design/protected_time_labels.dart`） | `test/features/calendar/schedule_view_source_test.dart` |
| R2 日视图卡片右边界不齐 | 四类卡片右边界 `Expected: <832.0>` / `Actual: <784.0>`（差 48 px ＝ 规则保护时间多一枚 `settings` 按钮） | 每行固定 48 px 操作槽 + 单个 `more_vert` 菜单（§2.7） | `test/features/calendar/day_view_test.dart` |
| R3 长任务最后一小段排不进去 | `Expected: [10, 30, 30, 30]` / `Actual: [30, 30, 30]` | `CandidateGenerator.generate(..., remainingMinutes:)`，引擎每轮重算候选（§2.1） | `test/scheduling/dynamic_short_tail_test.dart` |
| R4 最终校验不认唯一短尾 | 同上一条的 `PlanValidator.validate` 断言 | `validatePlannedChunkSet()` 按同任务整组块判唯一短尾（§2.2） | `test/scheduling/plan_validator_test.dart` |
| R5 最终原因来自旧轮次 | `Expected: not UnscheduledReasonCode.minimumChunkTooLarge` / `Actual: UnscheduledReasonCode.minimumChunkTooLarge` | 删除跨轮次 `rejectionEvidence`；最终原因由 `diagnoseTaskPlacement()` 依**最终块集合**重算（§2.3） | `test/scheduling/task_placement_diagnostics_test.dart` |
| R7 缺口数字互相矛盾 | 标题"还缺 25 分钟"、正文"还缺 130 分钟" | 删除 `_withNumbers()` 的 `constraintRequired − constraintAvailable` 推导；标题是唯一显示 shortage 的位置（§2.4） | `test/features/planning/unscheduled_display_test.dart` |
| R9 日历数据不会实时更新 | `Expected: a value greater than or equal to <2>` / `Actual: <1>`（真实生产源只发一次） | `RepositoryScheduleViewSource.watch()` 订阅 `tasks.watchAllTasks()` ＋ 失效总线，带合并、代际丢弃与取消清理（§2.6） | `test/features/calendar/schedule_view_source_test.dart` |
| R11 固定日程被标成"已完成" | `Expected: false` / `Actual: <true>` | `ScheduleViewItem.isCompleted` 收紧为**只表示任务完成** | `test/features/calendar/schedule_view_source_test.dart` |
| R12 "七日日历"实际有八列 | `Found 0 widgets with text "近期日历"`；空状态 `Found 2 widgets with text containing 七` | 标题改「近期日历」、空状态改「当前范围暂无安排」、教程写"昨天及未来七天"（保留 `index -1..6`） | `test/features/calendar/week_view_test.dart` |
| U5 规则保护时间三枚灰色操作 | `Found 1 widget with key 'delete-protected:breakfast:…'`（`disabled, disabled, disabled`） | 不可用动作**不渲染**；菜单只列可执行项 | `test/features/calendar/day_view_test.dart` |
| R8 异常提案可被误认为普通部分计划 | Task 1 未能独立建红灯（见 §4） | `hasEligibleCandidate && shortage > 0` ⇒ `unexplainedSchedulingFailure` ＋ `schedulingInvariantViolation`；`PlanApplicationService.apply()` 在 stale 检查后、validator 前先看 `proposal.conflicts`，非空直接 `invalid`（`allowPartial` 也绕不过） | `test/application/plan_application_service_test.dart` |
| R10 测试替身掩盖生产问题 | 不是独立红灯（它是 R9 的成因） | Task 7 Step 6 的真实源跨页面用例改用**真实** `RepositoryScheduleViewSource` ＋ 真实总线 | `test/features/calendar/week_view_test.dart` |

### 1.1 Review Focus 第 9 条的覆盖审计（本轮补测）

Review Focus 第 9 条要求"应用计划、撤销计划、编辑/删除日程、编辑课程、修改保护规则和完成任务后，
日视图、近期日历和今日页必须在同一进程内自动刷新"。它由两半组成，本轮做了一次覆盖审计：

| 环节 | 已有门禁 |
| --- | --- |
| "信号发了吗"（六个写入点各自成功发一次／失败发零次） | `test/application/schedule_view_invalidation_test.dart`（真实 drift 库） |
| "三个页面真的会跟着刷新吗" | `test/features/calendar/week_view_test.dart` 的跨页面用例（真实数据源 ＋ 真实总线 ＋ 三页同挂一棵树）＋ Windows 集成测试 |
| **真空档**：跨页面用例只驱动了"应用计划／编辑固定日程／完成任务"三条路径 | **本轮补上** `test/application/calendar_refresh_paths_test.dart`：删除日程、修改保护规则（按日例外）、保存配色、领域改名、撤销计划，**每条都要求真实生产数据源重新发一份"不同"的列表**（只断言"又发了一份"会被"原样重发"蒙过去） |

课程的保存／删除仍由 `schedule_view_invalidation_test.dart` 在真实 drift 库上覆盖（需要学期与
课表导入批次夹具），而"发信号 ⇒ 数据源完整重载"这条链与写入路径无关——因此没有重复搭一套学期夹具。

### 1.2 Review Focus 第 11 条（早餐标签）从数据层提到视图层

Review Focus 要求"早餐规则**在所有日历视图**中必须显示「早餐」"。此前只有两处数据层断言
（`schedule_view_source_test.dart` 的标题、`analytics_dao_test.dart` 的统计契约）——而计划说的是
"在所有日历视图中"。本轮补上 `week_view_test.dart` 的
「早餐规则在近期日历、日视图与今日页里都显示「早餐」（R1／人工场景 A）」：

- 走**真实装配链**：`SettingsService.saveUserRules`（真实 drift 库）→ `PlanningRuleResolver`
  → `ProtectedTimeExpander` → `RepositoryScheduleViewSource` → 三个页面同挂一棵树；
- 三个页面各自断言能读到「早餐」，并断言读不到英文枚举名 `breakfast`；
- 它同时是 R1 的端到端形式：修复前 `_protectedLabel()` 按 `intervalId.split(':')` 推断类别、
  早餐没有分支，三处都回落成「保护时间」。

### 1.3 计划示例表的逐行验证（§2.2）

`test/scheduling/plan_validator_test.dart` 把计划 §2.2 的示例表**逐行**写成用例，六行全部按表成立：

| required / min / granularity | 块集合 | 计划要求 | 实测 |
| --- | --- | --- | --- |
| 100 / 30 / 5 | 30,30,30,10 | 合法 | 合法 |
| 103 / 30 / 5 | 30,30,30,10 | 合法 | 合法 |
| 100 / 30 / 5 | 30,30,20 | 非法 | `belowMinimumBeforeTail` |
| 12 / 30 / 5 | 10 | 合法 | 合法 |
| 12 / 30 / 5 | 5 | 非法 | `shortTailMismatch` |
| 100 / 30 / 5 | 30,30,5,5 | 非法 | `multipleShortTails` |

## 2. 自动化验收（实际执行）

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 格式检查 | `dart format --output=none --set-exit-if-changed lib test integration_test tool` | `Formatted 585 files (0 changed)`，**exit 0** |
| 静态分析 | `fx.ps1 analyze --no-pub` | **No issues found!**（exit 0） |
| 全量测试 | `fx.ps1 test --no-pub` | **+2496 / 0 失败**（`00:59`） |
| Windows 集成测试 | `fx.ps1 test --no-pub integration_test/calendar_preview_consistency_test.dart -d windows` | **+1 / 0 失败**（`Building Windows application... 21.8s`；exit 0） |
| 构建候选（不发布） | `fx.ps1 build windows --release --no-pub` | 见 §2.2 |

### 2.1 全量测试的演进（每个 Task 提交后实测）

| 时点 | 通过 / 失败 | 说明 |
| --- | --- | --- |
| Task 1 提交后 | +55 / −13 | 13 条红灯分别命中 R1／R2／R3／R5／R7／R9／R11／R12／U5 |
| Task 4 提交后 | +377 / 0（定向门禁） | `test/scheduling` 与相关 application 用例全绿 |
| Task 5 提交后 | +2396 / −3 | 仅剩 R9 与 R12×2 |
| Task 6 提交后 | +2414 / −3 | 仅剩 R9 与 R12×2 |
| Task 7 提交后 | +1138 / −2（定向门禁） | 仅剩 R12×2 |
| Task 9 提交后 | **+2490 / 0** | 全绿 |
| 覆盖审计补测（`calendar_refresh_paths_test.dart` 5 条 + `week_view_test.dart` 早餐跨视图 1 条） | **+2496 / 0** | 全绿 |

### 2.2 构建候选（不发布）

见 §6「安全边界」：本计划**未获发布授权**，因此没有创建 tag、没有创建 GitHub Release、
没有上传任何产物。构建命令与结果记在 §6 的同一张表里，避免两处数字打架。

## 3. 人工验收场景 A–F

**全部 `NOT RUN`。** 计划 Task 10 Step 4–9 的六个场景要求**在真实 Windows 会话里用鼠标、
键盘、Narrator 与真实用户数据执行**（启用 breakfast 07:30–08:00、观察卡片右边界、
用 Narrator 朗读、在 100%–200% 缩放下目视、导出诊断等）。本会话没有可交互的桌面会话，
也不能接触真实用户的数据库，因此**没有任何一项被写成 PASS**。

| 场景 | 内容 | 状态 | 未执行原因 |
| --- | --- | --- | --- |
| A | 早餐与布局（三视图显示"早餐"、卡片右边界一致、菜单无灰色无效项） | **NOT RUN** | 需要可交互 Windows 桌面与人工目视 |
| B | 动态短尾（100 分钟 30–30 粒度 5 排满；103 分钟只报 3 分钟缺口） | **NOT RUN**（自动化等价物见 §1 的 R3/R4 与 `dynamic_short_tail_test.dart`） | 同上；人工部分未执行 |
| C | 真实容量不足（需 40 分钟、最短 30、只剩 20 分钟空档） | **NOT RUN**（自动化等价物见 `dynamic_short_tail_test.dart` 的第 6 条） | 同上 |
| D | 跨视图刷新（应用计划／编辑日程／撤销／完成，三个视图自动刷新） | **NOT RUN**（自动化等价物见 §2 的 Windows 集成测试） | 同上 |
| E | 预览安全性（可解释缺口只有次要的部分应用；无法解释异常只能重新生成；预览无自动调整开关） | **NOT RUN**（自动化等价物见 `plan_preview_test.dart` 与 `plan_generation_safety_test.dart`） | 同上 |
| F | 时区与边界（Asia/Shanghai 周界与 23:55→00:05；America/New_York DST 周夹具） | **NOT RUN**（自动化等价物：`test/scheduling/schedule_engine_time_zone_test.dart`、`test/core/time_zone_test.dart` 保持全绿） | 人工部分未执行 |

**人工清单**：`docs/testing/manual-windows-checklist.md` §J 已按计划 Task 9 Step 5 追加
矩阵（J.1 缩放 13 行、J.2 宽度 10 行、J.3 键盘 9 行、J.4 语义 8 行、J.5 结论 5 行），
**实际结果栏与证据路径栏全部为空**，并显式标注 `NOT RUN`。

## 4. 与计划的偏差（逐条说明，均已核实）

以下六处**不是**"为了让测试变绿而放宽断言"，而是修正计划／Task 1 里不可达或与计划条文冲突的期望值。
每一处都在测试文件里写明了推导，并且都**替换成更强的判据**或与计划逐字一致的判据。

| # | 位置 | 原期望 | 改为 | 理由 |
| --- | --- | --- | --- | --- |
| 1 | `dynamic_short_tail_test.dart`「180 / min30 / max90」 | `[30,30,60,60]` | `[60,60,60]` | 三天各一个 60 分钟空档，`breakMinutes = 10` 对所有块生效 ⇒ **每个空档只能放一个块**（两个 30 分钟块首尾相接 gap 为 0 会被 `_violatesRestGap` 拒绝）。180 分钟容量的唯一解就是三个 60 分钟块。原期望不可达 |
| 2 | `dynamic_short_tail_test.dart`「每天 30 分钟额度、任务 210 分钟」 | 窗口终点 `at(3, 11)`，期望排 90 | 窗口终点 `at(3, 7)`，仍期望排 90 | 原窗口终点落在第 4 天 11:00，第 4 天 07:00–11:00 也是可用空档 ⇒ 按任务自己的每日额度正确答案是 4×30 ＝ 120。改窗口让夹具真的只有三天，与该用例声明的意图一致 |
| 3 | `short_remainder_test.dart` / `short_remainder_matrix_test.dart`「100 分钟」 | 断言**任何**块 ≥ 30 | 断言**最多一个**短块，且它恰好等于 `shortRemainderAllowance(required − 常规块之和, 粒度)`，且全部块 ≤ max、落在网格上 | 原判据把"最后那一段**合法**的短尾"也一并禁掉，与计划 §2.2 的示例表（`30,30,30,10` 合法）直接冲突。新判据仍拦得住"普遍放宽"（两个短块、任意长度的短块都不合法） |
| 4 | `week_view_test.dart` 空状态 | 断言空状态文案**含"八"** | 断言空状态是计划 Task 8 Step 1 指定的「当前范围暂无安排」且不含"七" | 计划的要求是"不得再声称只有七列"，而不是"必须写出八"。计划 Step 1 已把文案逐字定死 |
| 5 | `plan_validator_test.dart`「集合校验对单块至少与 isValidPlannedChunk 一样严」 | 禁止"单块检查接受而集合校验拒绝" | 禁止反方向（"集合校验接受而单块检查拒绝"），并单独钉住 `12 / min30 / 粒度 5` 的 5 分钟块 | 计划 §2.2 亲自把那个 5 分钟块判为**非法**，而单块快速检查只看"不超过宽免额度"因此接受它。集合校验**必须**能更严，否则 R4 会以另一种形态回来 |
| 6 | `plan_preview_issue_policy_test.dart` / `visible_free_time_preview_test.dart` | 断言正文含缺口分钟（如 `contains('25')`） | 断言标题就是 `… 还缺 25 分钟` | 计划 §2.4／Task 5 Step 5 明确"标题是唯一显示 shortage 的位置"，正文只描述约束 |

**一处曾登记为"未查明"的偏差，本轮已查明并修掉**（详见 §6.7）：`_IssueGroup` 在"同时有
warning 与 blocking"时卡片标题取 `无法应用的问题`（源码即
`title ?? (blocking.isEmpty ? '需要注意' : '无法应用的问题')`），因此 `需要注意` 整屏不出现。
原因就是那一行三元表达式，不是渲染差异；修法是让 **warning 的分组标题**成为这一组固定的名字
（`需要注意：可以带着应用（会缺少一部分）`），不随同屏有没有阻断而变。

## 5. 安全边界

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 数据库 schema | **未改动** | `app_database.dart` 仍 `schemaVersion => 9`；`git diff --stat 9623858d..HEAD -- drift_schemas lib/data` 只有 `analytics_dao.dart` 的 12 行新增（补 `breakfast → 早餐` 映射） |
| 备份格式 | **未改动** | 同上（备份相关文件不在改动清单里） |
| 应用 identity / publisher / AUMID / 数据目录 | **未改动** | `git diff --stat 9623858d..HEAD -- installer windows` **为空**；包清单 `Identity Name="ShuoZhuang.PersonalPlanner"` 未变 |
| 软件版本 | `version` **未改动**（仍 `1.8.0+44`）；**MSIX 第四段 `1.8.0.1` → `1.8.0.2`** | 用户 2026-10-14 明确要求抬第四段；依据 `windows-release.md` §2「第四段只在同一批次重打包时 +1」。同时同步了 `output_name`、`test/app/version_consistency_test.dart` 的守卫期望、`manual-windows-checklist.md` 的候选标注与 `build-ledger.md` 的当前候选条目。**前三段、构建号、代码与包身份都没变** |
| 算法版本 | `15` → `16` | 这是内部排程算法版本，不是软件版本号（计划 §Global Constraints） |
| 真实用户数据 | **未使用** | 全部夹具使用匿名标题与固定 UUID-like 测试值；没有读取或写出用户的 SQLite、课程表或路径用户名 |
| 远程动作 | **无** | 未 push、未 rebase、未创建 tag、未创建 GitHub Release、未上传任何产物 |
| 新增第三方依赖 | **无** | `pubspec.yaml` 未改；失效合并使用 Dart SDK 的 `StreamController`／`StreamSubscription` |

## 6. 剩余风险与未完成项

1. **人工验收 A–F 全部未执行**（§3）。计划 §7「完成定义」明确：缺一项就不能写"修复完成"。
   因此本文件的结论是 **NOT COMPLETE**。
2. **候选已打包、未发布**：release 构建与签名 MSIX 都已完成并组装成交付包（见下表）；
   本计划未获发布授权，因此没有创建 tag／Release，也**没有安装到本机**——安装由用户在执行
   人工验收时自行完成。

   | 命令 | 结果 |
   | --- | --- |
   | `fx.ps1 build windows --release --no-pub` | `Building Windows application... 41.5s` → `√ Built build\windows\x64\runner\Release\personal_planner.exe`，**exit 0** |
   | `fx.ps1 pub run msix:create` | `msix created: build\windows\x64\runner\Release\personal_planner_1.8.0.2_x64.msix`，**exit 0**（第四段抬到 `2` 后重打） |
   | MSIX 签名 | `Get-AuthenticodeSignature` → **Valid**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN` |
   | 包清单自检 | 解包 `AppxManifest.xml`：`<Identity Name="ShuoZhuang.PersonalPlanner" Version="1.8.0.2"`（**身份未变**，只有版本第四段变了） |
   | 交付目录 | `G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261014\`（便携目录 ＋ 已签名 MSIX ＋ 公钥证书 ＋ 安装脚本 ＋ `验收说明.txt` ＋ `SHA-256.txt`） |
   | 交付 ZIP | `G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261014.zip`（**35094838 字节**，35 条目） |
   | 产物对应的生产代码 | `9e8be775`（本计划最后一次改动 `lib/` 的提交；与 `1.8.0.1` 同一批代码） |
   | 便携版能否启动 | 实测启动后进程存活 8 秒、stderr 只有 Impeller 后端提示，随后已显式关闭、无残留进程 |
   | 免安装版的副作用 | 首次运行会在 exe 旁生成 `user-data\`（`personal_planner.sqlite` ＋ 诊断日志）。该目录**已从交付包里删除**，ZIP 条目名自检确认不含 `user-data`／`.sqlite`／`.log` |
   | 安装到本机 | **未执行**（就地替换已安装包留给用户在人工验收时执行） |
   | 创建 tag / GitHub Release | **未执行**（未获发布授权） |

   **产物哈希（SHA-256）**——注意 `personal_planner.exe` **不是**代码身份的判据：
   Windows 上 Dart AOT 代码在 `data\app.so` 里，EXE 只是启动器，因此**改了 Dart 代码 EXE 的哈希
   可以完全不变**（本批与 `1.8.0.1` 的 EXE 哈希就完全相同）。本文件早先只记了 EXE 的哈希，
   那一条不具备区分能力，此处更正为把真正承载代码的 `data\app.so` 一起记：

   | 文件 | SHA-256 |
   | --- | --- |
   | `personal_planner.exe` | `8AAF66980C7AC6F97CA01F09FC5AC5FF24BBCAC7FA2C5D5A908F2FFDDB0A2D2B` |
   | `data\app.so`（真正的代码） | `C474317B53D7336A9318F01A39C4E042522089ED7602EB1087517F36D76A9719` |
   | `PersonalPlanner-1.8.0-build44-windows-x64-20261014.msix`（MSIX `1.8.0.2`） | `7358D1F408433E25D7520EC59077D3247C11380296ADAFBAF8C342A369D93B05` |
   | `PersonalPlanner-1.8.0-build44-windows-x64-20261014.zip` | `28E981AE46ACE2C604D7B7F052D8536F23720036467C07EEE2EBA9AD4EB333D5` |
   | `PersonalPlanner-signing-cert.cer` | `23FAE03376B8D05022A82B6C47D284117AB37D3100F9ECD1E3D9AB10C1A24A3C` |

   **一处必须交代的环境事实**：本机此前**已安装** `ShuoZhuang.PersonalPlanner 1.8.0.1`，
   而那是**修复之前**的构建——上一批候选 `PersonalPlanner-1.8.0-build44-windows-x64-20261013`
   的 `SHA-256.txt` 记录的 `data\app.so` 是 `39FBB4C8A5F7BC7E558227A615DABD85D765F97547785CED376333603A5F8072`，
   与已安装包的 `data\app.so` **逐字节相同**，与本批的 `C474317B…` 不同。
   因此人工验收**必须安装本批候选**，否则看到的是修复前的行为。
   **本批已按用户要求把 MSIX 第四段抬到 `1.8.0.2`**：`1.8.0.2 > 1.8.0.1`，安装是一次正常的
   原位升级。若报 `0x80073D02` 需先完全退出应用（含托盘）；仍不行则先 `Remove-AppxPackage`
   ——数据库在真实「文档」已知文件夹、不经 MSIX 重定向，卸载不会删数据。
   （免安装版不同：它把数据放在 exe 旁的 `user-data\`。）

3. **`plan_preview_page` 的"查看未使用空档"在未传时区时不渲染**（Task 6 的刻意选择：
   拿不到时区就只能印 UTC，那会让用户去找一段实际空闲的时间）。生产装配两处都传了时区。
4. **`excludedGaps` 里的 `occupiedByFixedSchedule`／`occupiedByProtectedTime`／`occupiedByLockedBlock`**
   在真实诊断路径上很少出现：固定日程与保护时间会被 `AvailabilityBuilder` 从空闲里扣掉，
   空档起点总落在它们之后。Task 5 没有为了"矩阵好看"伪造起点，而是让这三个 code 的**映射与分类**
   由放置循环也会调用的同一个 `evaluateCandidateEligibility` 逐条钉住（见
   `test/scheduling/task_placement_diagnostics_test.dart`）。

### 6.7 本轮顺带修掉的两处既有缺陷（经用户确认后实施）

这两处**先于本计划存在**，实施时发现并登记，本轮经用户明确要求后修掉。两者都先写了能因目标缺陷
失败的红灯（把修复临时回退后实测变红），再恢复修复：

| # | 缺陷 | 修复前的**实测**红灯 | 修法 | 修复后 |
| --- | --- | --- | --- | --- |
| ① | `ScheduleProposal.withLinkedBlocks` 漏传 `adjustmentRequirement`（同文件的 `withRuleOverride`／`withAdjustmentRequirement` 都传了） | `test/scheduling/schedule_engine_test.dart` 的「with* 包装原样传递诊断」：`Expected: <Instance of 'AdjustmentRequirement'>` / `Actual: <null>` | `withLinkedBlocks` 补上 `adjustmentRequirement: adjustmentRequirement`；并把该用例的夹具从 `withAdjustmentRequirement(null)` 改成**先附上一个真实要求再包装**——传 `null` 的写法根本观察不到"某一层把它丢了" | 绿 |
| ② | `_IssueGroup` 在同时有阻断时，warning 分组只剩后果、丢掉「需要注意」级别 | `test/features/planning/plan_preview_test.dart` 的「两组问题的严重级别都读得出来」：`Expected: true` / `Actual: <false>` | warning 的分组标题写全为 `需要注意：可以带着应用（会缺少一部分）`，让它成为这一组**固定**的名字 | 绿 |

**关于 ① 的影响，此处更正实施过程中的一处夸大**：当时登记为"建立来源关联后就会丢掉延后要求"，
但生产调用链 `PlanningService.createProposal` 是
`withRuleOverride → withLinkedBlocks → withAdjustmentRequirement`，附加动作排在**最后**，
而那一刻该字段本来就是 `null`——因此**当时没有任何生产路径被咬到**。它是"只要有人调整这三行的
顺序、或在带要求的提案上再关联一次来源就会静默丢字段"的陷阱，属于真实但未发作的不一致。
本节的措辞以此处为准。

修复后的复验：`test/scheduling/schedule_engine_test.dart`、
`test/features/planning/plan_preview_test.dart`、`test/features/planning/plan_preview_issue_policy_test.dart`、
`test/features/planning/unscheduled_display_test.dart`、`test/app/visible_free_time_preview_test.dart`、
`test/application/plan_application_service_test.dart`、`test/application/plan_generation_safety_test.dart`、
`test/application/planning_service_test.dart` 共 **117 通过 / 0 失败**；全量 **+2496 / 0 失败**；
`analyze` 0 问题；Windows 集成测试 **+1 / 0 失败**。

## 7. 结论

```text
Status: NOT COMPLETE
```

已完成的：Task 1–10 的全部代码与测试改动、两处既有缺陷的修复、全量自动化（格式 0 改动、
analyze 0 问题、**+2496 通过 / 0 失败**、Windows 集成测试 **+1 / 0 失败**），以及**可安装的
候选交付包**（已签名 MSIX ＋ 便携目录 ＋ ZIP ＋ 公钥证书 ＋ 验收说明，哈希见 §6.2）。
未完成的：人工验收场景 A–F（NOT RUN），因此**不能**声明"修复完成"或"发布就绪"。
交付包位置：`G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261014\`
（与同名 `.zip`）。

## 8. 执行交接（计划 §8 模板，按真实结果填写）

```markdown
## Calendar / Preview / Scheduling Integrity Repair — Handoff

### Scope
- Implemented tasks: Task 1–10 全部——Step 1（格式／分析／全量测试）、Step 2（Windows 集成测试）、
  Step 3（构建候选并打包签名 MSIX，**未安装、未发布**）、Step 4–10 的人工场景 A–F
  **未执行**、Step 11（规范与验收记录）已完成。
- 额外完成：经用户确认后修掉两处既有缺陷（`withLinkedBlocks` 漏传延后要求；警告分组丢掉
  「需要注意」级别），见 §6.7。
- Deferred tasks and reason: Task 10 的人工场景 A–F（以及清单 §J）——需要在可交互的
  Windows 桌面会话里由人执行 Narrator 朗读、100%–200% 缩放与高对比主题目视、
  真实用户数据下的早餐与时区场景；本会话没有该环境，也不得接触真实用户数据库。
  **候选交付包已备好，用户可直接安装验收**（见 §6.2）。

### Root-cause evidence
- Dynamic remaining reproduction: `test/scheduling/dynamic_short_tail_test.dart`
  （修复前 `100 / min30 / max30` 只排出 `[30,30,30]`，期望 `[10,30,30,30]`）。
- Final-diagnostics reproduction: `test/scheduling/task_placement_diagnostics_test.dart`
  ＋ `test/scheduling/dynamic_short_tail_test.dart` 的 R5/R6 用例（修复前主原因是
  旧轮次的 `minimumChunkTooLarge`，而不是最终真实的 `dailyLimitReached`）。
- Production refresh reproduction: `test/features/calendar/schedule_view_source_test.dart`
  （修复前真实生产源在 5 秒内只发 1 份列表，期望 ≥ 2 份且第二份含新写入的内容）。

### Verification
- Targeted tests: 每个 Task 的定向门禁均实测通过（数字见 §2.1 与各 Task 提交）。
- Full test count: `+2496` 通过 / `0` 失败（`fx.ps1 test --no-pub`，`00:59`）。
- Analyze: `No issues found!`（exit 0）。
- Format: `Formatted 585 files (0 changed)`，exit 0。
- Windows integration: `integration_test/calendar_preview_consistency_test.dart`
  → `+1 / 0 失败`；`Building Windows application... 21.8s`，exit 0。
- Release build: `√ Built build\windows\x64\runner\Release\personal_planner.exe`（41.5s，exit 0）；
  `fx.ps1 pub run msix:create` → `msix created: …personal_planner_1.8.0.2_x64.msix`（exit 0），
  签名 **Valid**（`CN=Shuo Zhuang, O=Personal User, C=CN`）。
- 交付包：`G:\best-planing\release\PersonalPlanner-1.8.0-build44-windows-x64-20261014\`
  （便携目录 ＋ 已签名 MSIX ＋ 公钥证书 ＋ 安装脚本 ＋ `验收说明.txt` ＋ `SHA-256.txt`），
  同名 `.zip` **35094838 字节 / 35 条目**；便携版实测可启动（存活 8 秒、无残留进程）。
  **未安装、未发布**：本机已装的 `1.8.0.1` 是**修复前**的构建
  （`data\app.so` = `39FBB4C8…`，本批 = `C474317B…`）；本批候选已把 MSIX 抬到 **`1.8.0.2`**，
  因此安装是一次正常的原位升级——安装动作留给用户在人工验收时执行，未创建 tag／Release。
- Manual scenarios A–F: **NOT RUN**（见 §3）。

### Safety
- Schema unchanged: 是（`schemaVersion => 9` 未动；`drift_schemas` 未动）。
- Backup format unchanged: 是。
- Product version unchanged: 是（`pubspec.yaml` 的 `version` 仍 `1.8.0+44`）。
  **一处例外并已获授权**：MSIX 第四段 `1.8.0.1` → `1.8.0.2`（用户 2026-10-14 明确要求，
  原因是本机已装 `1.8.0.1` 而它是修复前的构建、`Add-AppxPackage` 又不接受更低版本）。
  依据 `windows-release.md` §2「第四段只在同一批次重打包时 +1」；同步改了 `output_name`、
  版本守卫测试、人工清单的候选标注与 `build-ledger.md`。**代码、构建号与包身份都没变。**
- No user data used: 是（全部为匿名夹具）。
- No remote action performed: 是（未 push、未 rebase、未建 tag、未建 Release）。

### Remaining risk
- 人工验收 A–F 未执行 ⇒ 目视、Narrator、200% 缩放与高对比主题的实际观感尚未被人工确认。
- `excludedGaps` 的三种"被占住"code 在真实诊断路径上很少出现（固定日程／保护时间会被
  `AvailabilityBuilder` 从空闲里扣掉），其映射由共同判定函数钉住而非端到端复现。

### Status
- NOT COMPLETE（计划 §7 的"Windows 人工验收 A–F 有真实记录"未满足）
```

