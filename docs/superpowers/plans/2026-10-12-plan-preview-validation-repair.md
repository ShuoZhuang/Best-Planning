# Personal Planner 1.8 Plan Preview and Validation Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. **Do not use parallel agents for this plan.** The tasks intentionally share scheduling, proposal, validation, routing, and preview contracts; parallel edits would create incompatible intermediate states. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复“调整预览显示过去日期、重复容量不足、确认后必然失败”等问题，使排程提案、最终校验、预览展示和自动应用对“规划窗口、历史块、短余量、部分计划、阻断错误”使用同一套语义。

**Architecture:** 把已经结束的确认块从“未来排程输入”中剥离，历史展示继续由现有 `PlanBlockHistory` 提供；把提案状态明确分成“完整可应用／部分计划需确认／阻断不可应用”，并让引擎、应用服务与预览共同使用这项分类。校验器与候选生成器共享短余量和粒度规则，预览装配层保留结构化冲突、批量解析标题、过滤历史变化并去重容量缺口。

**Tech Stack:** Flutter / Dart、GoRouter、Drift / SQLite、现有确定性排程引擎、IANA 时区、Flutter widget tests、Windows x64 / MSIX。

**Spec:** `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md`（尤其 §11、§13、§15）；本计划的“冻结决策”是该规范针对 2026-10-12 实机故障的约束性补充。

## Global Constraints

- 本计划只处理本次“滚动规划窗口／调整预览／最终确认”故障链。托盘、通知、课程管理、日期时间选择器、保护时间入口等已由其他路线负责；本计划不得顺手修改，发现回归只记录并停止交付。
- 当前工作分支为 `feature/native-implementation`；开始前记录 `git status --short --branch` 与 `git rev-parse HEAD`，不得 reset、覆盖或清理用户改动。
- 当前候选为 `1.8.0+43` / MSIX `1.8.0.0`，尚未正式发布。本修复仍属于 **1.8 发布批次**，不得擅自改为 `1.8.1` 或 `1.9.0`。
- Tasks 1～8 不改软件版本号、不构建安装包。只有 Task 9 全部自动化和人工验收通过后，才按 `docs/release/version-policy.md` 分配下一个未使用 build；若期间无人占用，则为 `1.8.0+44`。
- 排程结果会变化，因此内部 `DeterministicScheduleEngine.algorithmVersion` 必须从 `13` 升到 `14`；它不是软件版本号。
- 单个实现代理、单个工作树、严格按 Task 1 → Task 9 串行执行。上一任务未完成验证和提交，不得开始下一任务。
- 每个任务开始前运行 `git status --short`。目标文件若存在不属于本计划的修改，停止并报告，不覆盖、不暂存、不清理。
- 所有生产代码修改必须先有能因目标缺陷而失败的测试；失败若来自夹具错误、编译错误或路径错误，不算红灯。
- 不修改数据库 schema，不迁移用户数据，不改变 MSIX identity、publisher、AUMID 或数据目录。
- 不新增第三方依赖、不增加联网权限、不读取用户计划内容用于遥测；测试数据必须为夹具或用户明确导出的副本。
- 不删除历史计划版本。过去日期的展示继续从 `PlanBlockHistory.blocksInWindow()` 读取，不得通过把过去块塞回当前提案来“保历史”。
- 不把 UUID、数据库主键或内部枚举名显示给用户；标题必须经一次批量 `TaskTitleLookup.titlesFor()` 解析。
- 不让 UI 猜排程失败原因。原因必须来自 `PlanningConflict` 或 `UnscheduledTask.primaryReason` 的结构化事实。
- 不为了让提案通过而挤占保护时间、移动锁定块、超排任务时长、放宽截止时间、改写用户任务属性或吞掉真实缺口。
- “容量不足”不是结构性错误：允许用户明确确认应用可安排部分；但自动应用不得静默接受部分计划。
- 提案存在任一阻断错误时，不得调用仓储写入，不得显示可点击的“确认应用”，不得记录成已应用历史。
- 代码变化后的每个交付候选都必须重新产生便携目录、ZIP、签名 MSIX、公钥 `.cer`、安装脚本、说明和 SHA-256；缺一项只能登记为内部构建。

## Review Focus

- 当前确认计划同时包含昨天、今天已结束、正在进行和未来块时，只允许正在进行与未来块进入前向提案；昨天和已结束块仍能在历史日历中看到。
- 规划窗口从当前时刻向上取整，且取整粒度必须来自 `problem.rules.granularityMinutes`；配置为 10 分钟时不能偷偷继续使用 5 分钟。
- 可拆分任务只剩 15 分钟、最小片段为 30 分钟时，15 分钟块应合法；100 分钟任务的普通片段仍不得小于 30 分钟。
- 连续任务只允许一个完整块，但不受可拆分任务的 `minChunkMinutes/maxChunkMinutes` 校验误伤。
- 只有 `unscheduled` 的提案进入“部分计划需确认”，只有 `conflicts` 的提案进入“阻断不可应用”；同一缺口不得在未安排与冲突中重复。
- 预览打开后输入变化时，应用阶段仍要返回 stale；不得把 stale 当作部分计划或普通阻断错误。
- 用户选择“应用可安排部分”前必须看到未安排任务标题、缺口分钟和结构化主原因；取消确认不得写库。
- “信任自动调整”仅自动应用完整、无冲突、无未安排项的提案；其余提案必须进入预览。
- 应用阶段若发现新的阻断错误，要显示具体任务与原因，并保持原计划逐字不变；按钮不得允许无限重复点击同一个必失败操作。
- 预览只显示非空变更组；没有变化但有问题时只显示问题，不用五张“无”卡片制造噪声。

---

## 1. 故障事实、根因与冻结决策

### 1.1 2026-10-12 实机故障

用户在“调整预览”看到：

- “新增”区域出现 `10-10`、`10-11` 等已经过去的时间块；
- 同一任务既显示“可用时间不足”，又显示“「蓝桥杯竞赛课」还缺 76 分钟”；
- 页面仍允许点击“确认应用”；
- 点击后只提示“计划未通过校验，未应用”，没有指出具体块与具体规则；
- 原计划没有应用，但页面仍停留在同一个可重复点击的失败状态。

### 1.2 已确认的代码根因

| 编号 | 根因 | 当前代码事实 | 用户后果 |
| --- | --- | --- | --- |
| R1 | 已结束块进入未来 `lockedBlocks` | `classifyConfirmedBlocks()` 把 `end <= now` 归为 `hardOccupied`，装配层把全部 `hardOccupiedIds` 放入 `lockedBlocksOut` | 提案携带规划窗口之前的块 |
| R2 | 引擎复制并计数全部锁定块 | `schedule_engine.dart` 以 `blocks = [...problem.lockedBlocks]` 开始，并把每块分钟加入 `scheduledByTask` | 历史安排污染当前剩余量、总时长与缺口 |
| R3 | 校验器又拒绝窗口外块 | `PlanValidator` 要求所有块的开始都包含于 `planningWindow` | 同一块先被当作有效计划，再被判“排程输入无效” |
| R4 | 候选与校验短余量规则冲突 | `CandidateGenerator` 允许 `required < minChunk` 的最后余量，`PlanValidator` 无条件拒绝 `duration < minChunk` | 引擎能生成、确认却必失败 |
| R5 | 连续任务被片段上下限误伤 | 候选生成明确“连续任务整段或零”，校验器仍逐块套用 min/max | 合法连续短任务可能被判 invalid |
| R6 | 容量缺口被重复建模 | 引擎同时输出 `UnscheduledTask` 和 `ConflictCode.insufficientCapacity`，路由又把 `unscheduled` 加进冲突列表 | 同一缺口重复两到三次 |
| R7 | 预览丢失结构 | `PlanPreviewModel.conflicts` 是 `List<String>`，路由只调用 `conflictLabel(code)` | 任务、块、数值和 invalid 原因全部丢失 |
| R8 | 可应用性没有进入 UI | 引擎有 `metrics.isFullyFeasible`，预览模型只保存 `isStale` | 明知阻断仍显示可点击确认 |
| R9 | 应用失败提示丢失结果 | `ApplyPlanResult.conflicts` 已有结构，路由统一显示“计划未通过校验” | 用户无法定位，也无法采取动作 |
| R10 | 测试固定了错误行为 | 现有测试要求同一缺口同时出现在“未安排”和“冲突”，且“过去块保留在提案”用例不检查冲突/可应用性 | 全量测试通过仍无法发现真实故障 |

### 1.3 冻结决策：时间块的三种时间角色

以 `planningWindow.startUtc` 为唯一边界，半开区间规则如下：

| 角色 | 条件 | 是否进入新提案 | 是否占用未来容量 | 是否参与 `scheduledByTask` | 历史如何保留 |
| --- | --- | --- | --- | --- | --- |
| 已结束 `historical` | `block.endUtc <= window.startUtc` | 否；除非它是本次明确调整目标 | 否 | 否 | 由现有 `PlanBlockHistory` 从旧版本读取 |
| 正在进行 `ongoing` | `block.startUtc < window.startUtc && block.endUtc > window.startUtc` | 是，原位且不可移动 | 只占窗口起点之后的相交部分 | 该块作为当前承诺计入一次，不得重复 | 当前提案与历史版本均可还原，展示端去重 |
| 未来 `future` | `block.startUtc >= window.startUtc` | 按锁定／冻结／可移动规则进入 | 是 | 是 | 当前提案 |

边界必须使用 `<=` 与 `>` 的上述组合：恰好在窗口起点结束的块属于历史，恰好在窗口起点开始的块属于未来。不得用 `isBefore` 留出一条端点缝隙。

### 1.4 冻结决策：短余量

- 可拆分任务：当且仅当 `task.requiredMinutes < task.minChunkMinutes` 时，唯一短片段宽免为 `floor(requiredMinutes / granularity) * granularity`；仍必须 `> 0` 且 `<= maxChunkMinutes`。
- `requiredMinutes >= minChunkMinutes` 时，每个生成片段继续满足 `[minChunkMinutes, maxChunkMinutes]`，不得把短余量宽免扩成普遍放宽。
- `requiredMinutes < granularity` 时不伪造片段，保留真实缺口。
- 连续任务：只允许零块或一个总时长不超过 `requiredMinutes` 的块；不套用可拆分任务的 min/max 片段检查。
- 候选生成、最终校验、测试夹具必须读取同一个 `problem.rules.granularityMinutes`。

### 1.5 冻结决策：提案处置状态

新增纯函数分类，不能由页面临时判断：

```dart
enum ProposalDisposition {
  fullyApplicable,
  partialRequiresConfirmation,
  blocked,
}

ProposalDisposition classifyProposal(ScheduleProposal proposal);
```

规则顺序不可调换：

1. `proposal.conflicts.isNotEmpty` → `blocked`；
2. 否则 `proposal.unscheduled.isNotEmpty` → `partialRequiresConfirmation`；
3. 否则 → `fullyApplicable`。

`ProposalMetrics.isFullyFeasible` 必须与该分类一致：只有 `fullyApplicable` 时为 `true`。测试要双向断言，防止两个事实源漂移。

### 1.6 冻结决策：按钮与自动应用

| 状态 | 主按钮 | 点击行为 | 信任自动调整 |
| --- | --- | --- | --- |
| fullyApplicable | `确认应用` | 直接二次校验并应用 | 可自动应用 |
| partialRequiresConfirmation | `应用可安排部分` | 先弹确认框，列出所有标题、缺口和原因；用户明确确认后以 `allowPartial` 模式应用 | 不自动应用，必须进预览 |
| blocked | `无法应用`，禁用 | 不调用应用服务；提供“重新生成计划” | 不自动应用，必须进预览 |
| stale | `无法应用`，禁用 | 只允许重新生成 | 不自动应用 |

阻断状态和 stale 都不得通过键盘、语义动作或程序化点击绕过。

## 2. 文件结构与职责

### 新建文件

| 文件 | 唯一职责 |
| --- | --- |
| `lib/scheduling/proposal_disposition.dart` | 根据结构化 `conflicts/unscheduled` 判定提案处置状态；不依赖 Flutter |
| `lib/features/planning/plan_preview_issues.dart` | 把结构化冲突与缺口转换为预览问题；批量标题表由调用方传入，不访问数据库 |
| `test/application/rolling_window_confirmed_blocks_test.dart` | 覆盖历史／端点／进行中／未来块穿过真实装配与引擎的行为 |
| `test/scheduling/proposal_disposition_test.dart` | 钉住三态分类与 metrics 一致性 |
| `test/features/planning/plan_preview_issue_policy_test.dart` | 钉住去重、标题、具体原因、严重级别和无 UUID |
| `test/application/plan_generation_safety_test.dart` | 钉住自动应用只接受完整可行提案，以及部分计划必须人工确认 |
| `test/app/plan_preview_regression_test.dart` | 复现截图的完整“过去块 + 缺口 + 阻断”装配行为 |
| `test/data/plan_block_history_test.dart` | 使用真实 Drift 仓储证明新提案不携带历史块时，旧版本历史仍可查询且不重复 |

### 修改文件

| 文件 | 修改责任 |
| --- | --- |
| `lib/application/confirmed_block_partition.dart` | 增加 `historical` 角色，统一端点和角色优先级 |
| `lib/application/repository_schedule_problem_source.dart` | 不把历史块送入未来提案；统一粒度；局部修复排除历史块但允许明确调整目标 |
| `lib/scheduling/schedule_proposal.dart` | 提案携带 `planningWindow`，所有 `with*` 完整复制 |
| `lib/scheduling/schedule_engine.dart` | 使用规则粒度；不生成重复容量冲突；算法版本升到 14 |
| `lib/scheduling/plan_validator.dart` | 窗口边界、进行中锁定块、短余量和连续任务规则与生成器一致；invalid 原因类型化 |
| `lib/application/plan_application_service.dart` | 加入 complete-only / allow-partial 防线，阻断或未确认部分计划不写库 |
| `lib/application/plan_generation_flow.dart` | 自动应用前使用三态分类，部分或阻断提案返回预览而不是尝试写入 |
| `lib/features/planning/plan_preview_page.dart` | 结构化 blockers/warnings、正确按钮状态、部分计划确认、隐藏空组、阻止重复失败点击 |
| `lib/app/router.dart` | 使用统一预览装配与错误翻译；过滤历史 diff；应用失败显示具体原因 |
| `lib/scheduling/explanations.dart` | 根据完整冲突而非仅 code 输出可行动文案 |
| `lib/scheduling/preview_failure_lines.dart` | 与新的去重和结构化问题模型共用翻译，不再创建第二套冲突文案 |
| `test/application/confirmed_block_partition_test.dart` | 把“过去块是 hardOccupied”旧断言改为“过去块是 historical” |
| `test/application/defer_hard_occupancy_test.dart` | 删除错误的“过去块必须留在提案”断言，改验历史不参与未来提案且提案无 invalid |
| `test/scheduling/short_remainder_test.dart` | 除生成结果外增加最终校验与 `proposal.conflicts` 断言 |
| `test/scheduling/plan_validator_test.dart` | 覆盖短余量、连续任务、窗口端点和进行中块 |
| `test/features/planning/unscheduled_display_test.dart` | 删除“同一缺口必须出现在两组”的错误要求，改为只出现一次 |
| `test/features/planning/plan_preview_test.dart` | 按三态验证按钮、对话框、空组、自动调整开关 |
| `test/application/plan_application_service_test.dart` | 覆盖 complete-only、allow-partial、阻断与零写入 |
| `test/application/plan_generation_flow_test.dart` | 覆盖 trusted 模式下完整／部分／阻断三条路径 |
| `test/scheduling/engine_minimizes_changes_test.dart` | 算法版本断言改为 `14` 并写明原因 |
| `docs/testing/v1.8.0-core-workflow-acceptance.md` | 追加本事故的自动化证据与人工结果，不改写旧记录 |
| `docs/testing/manual-windows-checklist.md` | 增加本修复的真实数据库、预览和部分计划验收项 |

## 3. 任务依赖与停止条件

```text
Task 1 复现与契约测试
  └─ Task 2 时间角色与规划窗口
       └─ Task 3 候选／校验契约统一
            └─ Task 4 提案三态与容量去重
                 └─ Task 5 应用与自动应用安全边界
                      └─ Task 6 预览装配与界面
                           └─ Task 7 全链路回归
                                └─ Task 8 文档与人工验收
                                     └─ Task 9 候选构建与安装包
```

出现以下任一情况立即停止：

- 为保留过去日历，被迫重新把已结束块加入当前提案；这说明历史读取链未接通，必须先修历史链，不能恢复旧错误。
- 修复需要删除或重写现有计划版本；本计划不允许破坏历史。
- `allowPartial` 在没有用户明确确认的路径被传为 `true`。
- 任一阻断提案进入 `repository.applyProposal()`。
- 完整回归出现新的时间、通知、课程、保护时间或数据库迁移失败。
- 安装包内出现 `user-data`、SQLite、日志、`.pfx`、`.key` 或 `.pem`。
- 人工验收不能证明截图场景已通过；不得仅凭单元测试登记完成。

---

### Task 1: 固定真实故障与反向测试

**Files:**
- Create: `test/application/rolling_window_confirmed_blocks_test.dart`
- Create: `test/app/plan_preview_regression_test.dart`
- Modify: `test/application/defer_hard_occupancy_test.dart`
- Modify: `test/features/planning/unscheduled_display_test.dart`
- Modify: `docs/testing/v1.8.0-core-workflow-acceptance.md`

**Interfaces:**
- Produces: 后续任务必须共同满足的实机场景夹具和红灯。
- Does not modify: 任何生产代码、算法版本、软件版本。

- [ ] **Step 1: 记录执行基线**

Run:

```powershell
Set-Location 'G:\best-planing\.worktrees\native-implementation'
git status --short --branch
git rev-parse HEAD
flutter --version
flutter test --no-pub --concurrency=1 test/application/defer_hard_occupancy_test.dart test/features/planning/unscheduled_display_test.dart test/scheduling/short_remainder_test.dart
```

Expected: 记录 HEAD；现有测试全绿，但验收文档明确写出“它们没有证明提案最终可应用”。

- [ ] **Step 2: 写滚动窗口四角色失败测试**

在 `rolling_window_confirmed_blocks_test.dart` 使用固定时钟 `2026-10-12 09:30 Asia/Shanghai`，构造：

- `past-day`: 10 月 11 日 15:00–16:00；
- `boundary-past`: 10 月 12 日 09:00–09:30；
- `ongoing`: 10 月 12 日 09:15–09:45；
- `future`: 10 月 12 日 14:00–15:00；
- 四块属于仍为 open 的同一任务，当前确认计划同时包含它们。

断言：

```dart
expect(problem.lockedBlocks.map((b) => b.id), isNot(contains('past-day')));
expect(problem.lockedBlocks.map((b) => b.id), isNot(contains('boundary-past')));
expect(problem.existingBlocks.map((b) => b.id), isNot(contains('past-day')));
expect(proposal.blocks.map((b) => b.id), isNot(contains('past-day')));
expect(proposal.blocks.map((b) => b.id), isNot(contains('boundary-past')));
expect(proposal.blocks.map((b) => b.id), contains('ongoing'));
expect(proposal.blocks.map((b) => b.id), contains('future'));
expect(proposal.conflicts.where((c) => c.code == ConflictCode.invalidInput), isEmpty);
```

- [ ] **Step 3: 写截图级回归测试**

`plan_preview_regression_test.dart` 构造当前计划含 10-10、10-11 历史块和 10-12 未来块，提案含一个任务缺口。调用真实 `RepositoryScheduleProblemSource → PlanningService → preview assembly`，断言：

- 预览可见变化中不出现 `10-10`、`10-11`；
- 不出现“排程输入无效”；
- “蓝桥杯竞赛课还缺 76 分钟”只出现一次；
- 缺口被标为 warning，不是 blocker；
- 主操作为“应用可安排部分”，不是“确认应用”；
- 未确认前计划仓储写入次数为 0。

- [ ] **Step 4: 纠正两条错误测试契约**

只改测试期待，不改生产：

- `defer_hard_occupancy_test.dart`：把“过去块必须仍在提案里”改成“过去块不移动历史事实，但不进入未来提案；生成结果无 invalid”；
- `unscheduled_display_test.dart`：删除“同一缺口必须同时出现在未安排和冲突”的要求，改成整个页面只出现一次标题＋缺口＋主原因。

- [ ] **Step 5: 观察正确红灯**

Run:

```powershell
flutter test --no-pub --concurrency=1 test/application/rolling_window_confirmed_blocks_test.dart test/app/plan_preview_regression_test.dart test/application/defer_hard_occupancy_test.dart test/features/planning/unscheduled_display_test.dart
```

Expected: FAIL 必须指向历史块仍在提案、重复缺口、缺少结构化状态或按钮仍可应用；若因测试无法编译，先修夹具，不能进入 Task 2。

- [ ] **Step 6: Commit tests only**

```powershell
git add test/application/rolling_window_confirmed_blocks_test.dart test/app/plan_preview_regression_test.dart test/application/defer_hard_occupancy_test.dart test/features/planning/unscheduled_display_test.dart docs/testing/v1.8.0-core-workflow-acceptance.md
git commit -m "test: reproduce invalid rolling plan preview"
```

### Task 2: 分离历史块与前向排程块

**Files:**
- Modify: `lib/application/confirmed_block_partition.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/scheduling/schedule_problem.dart` only if comments/invariants require clarification; do not add a second historical collection
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `lib/application/planning_service.dart`
- Modify: `test/application/confirmed_block_partition_test.dart`
- Modify: `test/application/rolling_window_confirmed_blocks_test.dart`
- Modify: `test/application/defer_hard_occupancy_test.dart`
- Create: `test/data/plan_block_history_test.dart`

**Interfaces:**
- Produces: `ConfirmedBlockRole.historical`; `ScheduleProposal.planningWindow`;前向输入中不存在已结束块。
- Consumes: Task 1 的四角色场景。

- [ ] **Step 1: 给分区纯函数写精确边界测试**

新增断言：

- `end == now` → `historical`；
- `end < now` → `historical`；
- `start < now < end` → `hardOccupied`；
- `start == now` 且 unlocked → `existing`（无调整时）；
- past 块若是 `adjustedTargetId`，调整角色优先于 historical；
- 每个 ID 仍恰好一个角色。

- [ ] **Step 2: 观察分区测试失败**

Run: `flutter test --no-pub test/application/confirmed_block_partition_test.dart`

Expected: FAIL，因为当前没有 `historical` 且端点被归到 `hardOccupied`。

- [ ] **Step 3: 实现 `ConfirmedBlockRole.historical`**

保持现有优先级中的“排除／钉住／调整目标／被挤开”在 historical 之前；随后：

```text
end <= planningWindowStart → historical
locked 或 start < planningWindowStart < end → hardOccupied
调整成功时其余未来块 → frozen
其余未来块 → existing
```

将参数 `nowUtc` 重命名为 `planningWindowStartUtc`，所有调用点一起更新，禁止两个名字表示同一边界。

- [ ] **Step 4: 让装配层只消费前向角色**

`lockedBlocksOut` 和 `existingBlocksOut` 均不得消费 `historicalIds`。局部修复：

- 普通历史块不进入 `blocks`，也不进入 `immovable`；它们位于下界之前，不可能占用未来候选；
- 明确调整的 past target 仍可作为调整目标进入局部修复；
- 其他锁定／进行中／未来块保持既有语义；
- `confirmedBlocks` 可以继续携带完整确认计划用于来源关联，但来源关联与预览必须按 planning window 过滤，不能让历史重新出现。

- [ ] **Step 5: 让提案携带生成时的窗口**

在 `ScheduleProposal` 新增：

```dart
final TimeRange planningWindow;
```

构造器设为 required；`withRuleOverride`、`withAdjustmentRequirement`、`withLinkedBlocks` 必须逐值复制。引擎创建提案时传 `problem.planningWindow`。更新全部 16 处构造夹具，禁止填任意假窗口；每个测试使用自身 problem 的窗口。

- [ ] **Step 6: 防止历史数据丢失的反向测试**

在真实 Drift 仓储测试中应用一个不含 past 块的新提案，然后调用 `PlanBlockHistory.blocksInWindow()` 查询过去日期，断言旧版本的 past 块仍能读取一次且不会重复。不得把该块重新塞入新确认版本来满足测试。

- [ ] **Step 7: 运行任务测试**

```powershell
flutter test --no-pub --concurrency=1 test/application/confirmed_block_partition_test.dart test/application/rolling_window_confirmed_blocks_test.dart test/application/defer_hard_occupancy_test.dart test/data/plan_block_history_test.dart
```

Expected: PASS；提案中不含已结束块，历史读取仍含旧块。

- [ ] **Step 8: Commit**

```powershell
git add lib/application/confirmed_block_partition.dart lib/application/repository_schedule_problem_source.dart lib/scheduling/schedule_problem.dart lib/scheduling/schedule_proposal.dart lib/application/planning_service.dart test/application/confirmed_block_partition_test.dart test/application/rolling_window_confirmed_blocks_test.dart test/application/defer_hard_occupancy_test.dart test/data/plan_block_history_test.dart
git commit -m "fix: exclude historical blocks from forward planning"
```

### Task 3: 统一粒度、短余量与最终校验

**Files:**
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/scheduling/candidate_generator.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/plan_validator.dart`
- Modify: `test/scheduling/short_remainder_test.dart`
- Modify: `test/scheduling/plan_validator_test.dart`
- Create: `test/scheduling/granularity_contract_test.dart`

**Interfaces:**
- Produces: 生成器与校验器共同遵守的粒度和短余量契约；类型化 `InvalidInputReason`。
- Consumes: `ScheduleProposal.planningWindow` 与 Task 2 的前向块集合。

- [ ] **Step 1: 写短余量最终校验红灯**

扩展 `short_remainder_test.dart`：

- 15 分钟可拆分任务、min 30、max 90、粒度 5：生成一个 15 分钟块；`proposal.conflicts` 不含 invalid；`PlanApplicationService` 可完整应用；
- 12 分钟：生成 10 分钟，剩 2 分钟进入 `unscheduled`，但 10 分钟块本身不产生 invalid；
- 3 分钟：不生成块，缺口 3 分钟，不产生 invalid；
- 100 分钟：任何普通块仍不得小于 30；
- 15 分钟连续任务：一个 15 分钟块，不因 min 30 产生 invalid；两个块仍产生 `continuousBlockUnavailable`。

- [ ] **Step 2: 写粒度单一事实源红灯**

`granularity_contract_test.dart` 用规则粒度 10 分钟、当前时刻 09:33：

- planning window 从 09:40 开始；
- 所有候选起止和时长落在 10 分钟网格；
- 不出现 09:35 或 15 分钟等 5 分钟默认值残留；
- 校验器接受生成器产物。

- [ ] **Step 3: 观察失败**

```powershell
flutter test --no-pub --concurrency=1 test/scheduling/short_remainder_test.dart test/scheduling/plan_validator_test.dart test/scheduling/granularity_contract_test.dart
```

Expected: 当前至少因 short block 被 validator 拒绝、连续任务被 min/max 误伤、规则粒度仍使用默认 5 而失败。

- [ ] **Step 4: 类型化 invalid 原因**

在 `plan_validator.dart` 新增：

```dart
enum InvalidInputReason {
  unknownTask,
  startsBeforePlanningWindow,
  endsAfterPlanningWindow,
  chunkBelowMinimum,
  chunkAboveMaximum,
  offGranularity,
}
```

`PlanningConflict` 新增 `InvalidInputReason? invalidInputReason`；数字继续放 `details`。窗口外、未知任务、片段过短／过长、网格错误分别产生唯一原因，不再共用 `details['reason'] = 'chunkLength'`。

- [ ] **Step 5: 实现窗口边界例外**

默认规则仍是所有新块完全位于 planning window。唯一例外：

- 若块与 `problem.lockedBlocks` 中同 ID、同 task、同 range 的进行中块完全一致；
- 且 `start < window.start < end`；
- 则允许其开始早于窗口；
- 任意生成块、可移动块或伪造的同 ID 不得使用例外。

结束超出 window end 始终阻断。

- [ ] **Step 6: 实现短余量与连续任务规则**

抽取校验纯函数，签名固定为：

```dart
bool isValidPlannedChunk({
  required SchedulableTask task,
  required PlannedBlock block,
  required int granularityMinutes,
});
```

按 §1.4 执行。不得在 UI 或应用服务复制此逻辑。

- [ ] **Step 7: 统一粒度来源**

- `RepositoryScheduleProblemSource` 必须先解析 `resolvedRules`，再以 `resolvedRules.granularityMinutes` 计算 `startUtc`；
- 引擎每次生成时构造或调用使用 `problem.rules.granularityMinutes` 的 `CandidateGenerator`；
- validator 使用同一规则值；
- 删除“刻意固定 5 分钟”的旧注释，改写为规则是唯一事实源。

- [ ] **Step 8: 算法版本升到 14**

`DeterministicScheduleEngine.algorithmVersion = '14'`。更新守卫测试，原因写为“历史块不再计入前向计划 + 粒度与短余量契约统一会改变输出”。

- [ ] **Step 9: 运行任务测试**

```powershell
dart format lib/application/repository_schedule_problem_source.dart lib/scheduling/candidate_generator.dart lib/scheduling/schedule_engine.dart lib/scheduling/plan_validator.dart test/scheduling/short_remainder_test.dart test/scheduling/plan_validator_test.dart test/scheduling/granularity_contract_test.dart test/scheduling/engine_minimizes_changes_test.dart
flutter test --no-pub --concurrency=1 test/scheduling/short_remainder_test.dart test/scheduling/plan_validator_test.dart test/scheduling/granularity_contract_test.dart test/scheduling/engine_minimizes_changes_test.dart
```

Expected: PASS；所有生成块均可被 validator 接受。

- [ ] **Step 10: Commit**

```powershell
git add lib/application/repository_schedule_problem_source.dart lib/scheduling/candidate_generator.dart lib/scheduling/schedule_engine.dart lib/scheduling/plan_validator.dart test/scheduling/short_remainder_test.dart test/scheduling/plan_validator_test.dart test/scheduling/granularity_contract_test.dart test/scheduling/engine_minimizes_changes_test.dart
git commit -m "fix: align scheduling generation and validation"
```

### Task 4: 建立提案三态并移除重复容量冲突

**Files:**
- Create: `lib/scheduling/proposal_disposition.dart`
- Create: `test/scheduling/proposal_disposition_test.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `test/scheduling/infeasible_schedule_test.dart`
- Modify: `test/features/planning/unscheduled_display_test.dart`
- Modify: `test/scheduling/preview_failure_lines_test.dart`

**Interfaces:**
- Produces: `ProposalDisposition`、`classifyProposal()`；`ScheduleProposal.conflicts` 只含阻断错误，容量缺口只在 `unscheduled`。
- Consumes: Task 3 的合法提案与结构化 invalid 原因。

- [ ] **Step 1: 写三态纯函数测试**

分别构造：

- 无 conflict、无 unscheduled → fullyApplicable；
- 无 conflict、有 unscheduled → partialRequiresConfirmation；
- 有任一 conflict，无论是否有 unscheduled → blocked。

同时断言**引擎实际生成的** `metrics.isFullyFeasible == (disposition == fullyApplicable)`。`classifyProposal()` 只以 `conflicts/unscheduled` 为事实源，不读取 metrics，避免旧 metrics 反过来掩盖结构化问题；所有构造提案的测试 helper 必须从同一结构重新计算 metrics，不得手填相反值。

- [ ] **Step 2: 写容量单一来源测试**

对一个容量不足任务断言：

```dart
expect(proposal.unscheduled, hasLength(1));
expect(proposal.conflicts.where((c) => c.code == ConflictCode.insufficientCapacity), isEmpty);
expect(classifyProposal(proposal), ProposalDisposition.partialRequiresConfirmation);
```

- [ ] **Step 3: 观察失败**

Run: `flutter test --no-pub test/scheduling/proposal_disposition_test.dart test/scheduling/infeasible_schedule_test.dart test/features/planning/unscheduled_display_test.dart`

Expected: FAIL，因为引擎当前会为每条 unscheduled 再加一次 insufficientCapacity conflict。

- [ ] **Step 4: 实现纯分类并删除引擎重复循环**

删除 `schedule_engine.dart` 中把每个 `UnscheduledTask` 再转成 `PlanningConflict(insufficientCapacity)` 的循环。保留枚举值用于兼容应用服务“未确认部分计划”的返回结果，但正常引擎不再生成它。

- [ ] **Step 5: 更新失败摘要**

`previewFailureLines()` 先列每个 unscheduled 一次，再列真正 conflicts；不得再把同一 task shortage 作为 conflict 重复。顺序稳定：按提案列表顺序，最多三行的既有上限保持。

- [ ] **Step 6: 运行测试**

```powershell
dart format lib/scheduling/proposal_disposition.dart lib/scheduling/schedule_engine.dart lib/scheduling/schedule_proposal.dart lib/scheduling/preview_failure_lines.dart test/scheduling/proposal_disposition_test.dart test/scheduling/infeasible_schedule_test.dart test/features/planning/unscheduled_display_test.dart test/scheduling/preview_failure_lines_test.dart
flutter test --no-pub --concurrency=1 test/scheduling/proposal_disposition_test.dart test/scheduling/infeasible_schedule_test.dart test/features/planning/unscheduled_display_test.dart test/scheduling/preview_failure_lines_test.dart
```

Expected: PASS；每个容量缺口只有一个结构化来源。

- [ ] **Step 7: Commit**

```powershell
git add lib/scheduling/proposal_disposition.dart lib/scheduling/schedule_engine.dart lib/scheduling/schedule_proposal.dart lib/scheduling/preview_failure_lines.dart test/scheduling/proposal_disposition_test.dart test/scheduling/infeasible_schedule_test.dart test/features/planning/unscheduled_display_test.dart test/scheduling/preview_failure_lines_test.dart
git commit -m "refactor: separate partial plans from blocking conflicts"
```

### Task 5: 在应用服务和自动应用前建立不可绕过的安全边界

**Files:**
- Modify: `lib/domain/repositories/plan_repository.dart`
- Modify: `lib/application/plan_application_service.dart`
- Modify: `lib/application/plan_generation_flow.dart`
- Modify: `lib/app/router.dart`
- Create: `test/application/plan_generation_safety_test.dart`
- Modify: `test/application/plan_application_service_test.dart`
- Modify: `test/application/plan_generation_flow_test.dart`
- Modify: `test/application/adjustment_interception_test.dart`

**Interfaces:**
- Produces: `PlanApplyMode.completeOnly/allowPartial`；`ApplyPlanStatus.partialConfirmationRequired`；trusted 自动应用只接受 fullyApplicable。
- Consumes: Task 4 的 `classifyProposal()`。

- [ ] **Step 1: 写应用模式失败测试**

新增：

```dart
enum PlanApplyMode { completeOnly, allowPartial }
```

测试预期：

- fullyApplicable + completeOnly → applied；
- partial + completeOnly → partialConfirmationRequired，仓储调用 0；
- partial + allowPartial → validator 通过后 applied，仓储调用 1；
- blocked + 任意 mode → invalidProposal，仓储调用 0；
- stale + 任意 mode → staleProposal，仓储调用 0；
- requestedAdjustmentUnsatisfied + allowPartial 仍是 invalid，不能借部分模式绕过延后兑现校验。

- [ ] **Step 2: 写 trusted 自动应用失败测试**

`plan_generation_safety_test.dart` 断言：

- trusted + fullyApplicable：调用 apply 一次；
- trusted + partial：apply 零次，outcome 指向预览并提示“仍有未安排事项，需要确认”；
- trusted + blocked：apply 零次，outcome 指向预览并提示“计划存在需要处理的问题”；
- untrusted 三种状态都不自动调用 apply。

- [ ] **Step 3: 观察失败**

```powershell
flutter test --no-pub --concurrency=1 test/application/plan_application_service_test.dart test/application/plan_generation_flow_test.dart test/application/plan_generation_safety_test.dart test/application/adjustment_interception_test.dart
```

Expected: FAIL，因为当前 trusted 不看提案状态直接调用 apply，应用服务也没有 partial 授权参数。

- [ ] **Step 4: 扩展应用结果与模式**

`ApplyPlanStatus` 新增 `partialConfirmationRequired`，`ApplyPlanResult` 新增工厂：

```dart
factory ApplyPlanResult.partialRequired(List<PlanningConflict> shortages);
```

`PlanApplicationService.apply` 签名固定为：

```dart
Future<ApplyPlanResult> apply(
  ScheduleProposal proposal, {
  PlanApplyMode mode = PlanApplyMode.completeOnly,
});
```

执行顺序：重放输入与 hash → validator 阻断校验 → adjustment fulfilment → partial 授权检查 → repository write。顺序不可改变：结构错误不能被 partial 模式放行，stale 不能被误报为容量缺口。

- [ ] **Step 5: 生成部分计划的返回冲突**

`completeOnly` 遇到 unscheduled 时，为返回结果创建 `ConflictCode.insufficientCapacity`，每项携带 taskId 和 shortageMinutes；它只用于告诉调用者“需要明确允许部分计划”，不得写回 `proposal.conflicts`。

- [ ] **Step 6: 修正 `PlanGenerationFlow`**

在调用 apply 前使用 `classifyProposal()`：

- fullyApplicable + trusted → apply completeOnly；
- partial 或 blocked → `applied=false`、`requiresPreview=true`，不调用 apply；
- outcome 新增 `requiresPreview`，调用方不得再用“message 非空就 return”吞掉预览导航；
- 自动路径绝不传 `allowPartial`。

- [ ] **Step 7: 更新所有 switch 与调用点**

所有 `ApplyPlanStatus` switch 必须穷尽新增状态；禁止 `_ =>` 吞掉。路由、测试替身、特殊日恢复和重排协调器逐处决定：没有明确用户确认的路径一律 completeOnly。

- [ ] **Step 8: 运行任务测试**

```powershell
dart format lib/domain/repositories/plan_repository.dart lib/application/plan_application_service.dart lib/application/plan_generation_flow.dart lib/app/router.dart test/application/plan_application_service_test.dart test/application/plan_generation_flow_test.dart test/application/plan_generation_safety_test.dart test/application/adjustment_interception_test.dart
flutter test --no-pub --concurrency=1 test/application/plan_application_service_test.dart test/application/plan_generation_flow_test.dart test/application/plan_generation_safety_test.dart test/application/adjustment_interception_test.dart test/application/replanning_coordinator_test.dart
```

Expected: PASS；任一不完整或阻断提案在未确认时仓储调用为 0。

- [ ] **Step 9: Commit**

```powershell
git add lib/domain/repositories/plan_repository.dart lib/application/plan_application_service.dart lib/application/plan_generation_flow.dart lib/app/router.dart test/application/plan_application_service_test.dart test/application/plan_generation_flow_test.dart test/application/plan_generation_safety_test.dart test/application/adjustment_interception_test.dart test/application/replanning_coordinator_test.dart
git commit -m "fix: prevent unsafe automatic plan application"
```

### Task 6: 重建预览问题模型、装配和交互

**Files:**
- Create: `lib/features/planning/plan_preview_issues.dart`
- Create: `test/features/planning/plan_preview_issue_policy_test.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/scheduling/explanations.dart`
- Modify: `lib/scheduling/preview_failure_lines.dart`
- Modify: `test/features/planning/plan_preview_test.dart`
- Modify: `test/features/planning/unscheduled_display_test.dart`
- Modify: `test/features/planning/plan_preview_apply_test.dart`
- Modify: `test/app/plan_preview_title_test.dart`
- Modify: `test/app/plan_preview_regression_test.dart`

**Interfaces:**
- Produces: `PreviewIssueSeverity`、`PreviewIssue`、结构化 `PlanPreviewModel.issues`；历史 diff 过滤；三态按钮；页面确认回调固定接收 `PlanApplyMode` 并返回 `ApplyPlanResult`。
- Consumes: Task 2 的 `proposal.planningWindow`、Task 3 的 invalid 原因、Task 4 的 disposition、Task 5 的 apply mode。

- [ ] **Step 1: 定义预览问题类型并写纯函数测试**

接口固定为：

```dart
enum PreviewIssueSeverity { warning, blocking }

final class PreviewIssue {
  const PreviewIssue({
    required this.key,
    required this.severity,
    required this.title,
    required this.message,
  });

List<PreviewIssue> buildPreviewIssues({
  required ScheduleProposal proposal,
  required Map<String, String> titleByTaskId,
});
```

断言：

- 每个 unscheduled 产生一条 warning，标题、shortage 和 primaryReason 都存在；
- 每个 conflict 产生一条 blocking；
- 相同 taskId + shortage 不重复；
- 标题缺失回落 `未命名任务`；
- 任何字段不含 UUID；
- invalid 原因分别翻译为“时间块早于本次规划范围”“时间块晚于本次规划范围”“任务已不存在”“片段短于允许值”等，不再只有“排程输入无效”。

- [ ] **Step 2: 观察问题模型测试失败**

Run: `flutter test --no-pub test/features/planning/plan_preview_issue_policy_test.dart`

Expected: FAIL，因为文件与结构类型尚不存在。

- [ ] **Step 3: 实现单一翻译链**

`explanations.dart` 新增接收完整冲突的函数：

```dart
String planningConflictMessage(
  PlanningConflict conflict, {
  required String taskTitle,
});
```

`plan_preview_issues.dart` 和 `preview_failure_lines.dart` 都调用它，禁止复制 switch。对 unknown block/task 只显示用户可理解的对象和动作，不显示 relatedEntityIds。

- [ ] **Step 4: 替换 `PlanPreviewModel.conflicts`**

改为：

```dart
final List<PreviewIssue> issues;
bool get hasBlockingIssues;
bool get hasWarnings;
ProposalDisposition get disposition;
```

不得同时保留 `List<String> conflicts` 作为第二事实源。所有测试夹具更新为 `issues` 或通过统一装配函数生成。

同时把页面确认回调由无参 `Future<void> Function()` 改为：

```dart
final Future<ApplyPlanResult> Function(PlanApplyMode mode) onConfirm;
```

页面只选择 `completeOnly` 或 `allowPartial`，不直接访问仓储；应用结果由页面交给统一结果处理函数，导航、错误面板和重试状态只保留一套。若项目为避免 feature 层依赖 repository DTO 而已有等价的 UI 结果类型，可以增加一个**单一适配器**，但不得退回 `void` 后靠 snackbar 猜结果。

- [ ] **Step 5: 过滤预览 diff 的历史块**

在路由装配前使用 proposal 的 planning window：

```dart
bool visibleToForwardPreview(PlannedBlock block) =>
    block.endUtc.isAfter(proposal.planningWindow.startUtc) &&
    block.startUtc.isBefore(proposal.planningWindow.endUtc);
```

对 current 与 proposed 两侧都过滤后再交给 `PlanDiffer`。进行中块保留；已结束块不形成 removed/added/moved。`PlanDiffer` 本身保持通用，不偷偷读取系统时钟。

- [ ] **Step 6: 标题批量解析覆盖所有问题与变更**

一次 `titlesFor()` 的输入集合必须包含：

- proposal.unscheduled taskIds；
- proposal.conflicts 的非空 taskId；
- 过滤后的 diff before/after taskIds。

去重后只调用一次。找不到标题统一为 `未命名任务`。

- [ ] **Step 7: 实现三态页面**

- blocked：显示阻断问题卡；主按钮文本“无法应用”且 `onPressed == null`；若 `onRecalculate != null` 显示“重新生成计划”；
- partial：每个 `UnscheduledTask` 只显示一条 warning，同一缺口不得再以 conflict 重复；主按钮“应用可安排部分”；点击后弹 `AlertDialog`，列出全部缺口，按钮为“取消”和“仍然应用”；只有后者调用 `onConfirm(PlanApplyMode.allowPartial)`；
- fullyApplicable：主按钮“确认应用”；
- stale 优先级高于三态，仍只允许重新生成；
- `_applying` 期间所有应用入口禁用；失败返回后 blocked 应转为不可重复点击状态或显示具体失败面板；
- 只有非空 `_ChangeGroup` 才渲染；全部为空时显示一条“没有计划时间变更”；
- warning 和 blocking 使用不同图标、标题和颜色，但不得仅靠颜色区分。

- [ ] **Step 8: 修正信任自动调整开关**

页面处于 blocked 或 partial 时不得把当前提案自动应用。开关仍代表未来偏好：

- 已开启时可允许用户关闭；
- 未开启时仍可修改偏好，但辅助文案明确“当前方案不会自动应用”；
- 无论开关显示为何值，Task 5 的应用层防线都不可绕过。

- [ ] **Step 9: 应用阶段显示精确结果**

路由 `_confirm` 必须读取 `ApplyPlanResult.conflicts`：

- stale → 原有过期文案并提供重算；
- partialConfirmationRequired → 不写库，回到部分确认流程；
- invalid → 通过同一 `planningConflictMessage` 格式化最多三条具体原因；超过三条显示“另有 N 项”；
- applied → 导航日历；
- 失败后不得只弹“计划未通过校验”。

- [ ] **Step 10: Widget tests**

必须覆盖：

1. blocker 时按钮禁用且 onConfirm 调用 0；
2. warning 时按钮名称正确，取消对话框调用 0，确认后以 allowPartial 调用 1；
3. clean 时直接调用 `PlanApplyMode.completeOnly`；
4. stale 时重算入口可用；
5. 5 类里只有有内容的组显示；
6. 缺口只出现一次；
7. 页面无 UUID；
8. invalid 原因可见；
9. 快速双击确认只发生一次写入；
10. 应用返回 invalid 后不能继续点击同一失败按钮。

- [ ] **Step 11: 运行任务测试**

```powershell
dart format lib/features/planning/plan_preview_issues.dart lib/features/planning/plan_preview_page.dart lib/app/router.dart lib/scheduling/explanations.dart lib/scheduling/preview_failure_lines.dart test/features/planning/plan_preview_issue_policy_test.dart test/features/planning/plan_preview_test.dart test/features/planning/unscheduled_display_test.dart test/features/planning/plan_preview_apply_test.dart test/app/plan_preview_title_test.dart test/app/plan_preview_regression_test.dart
flutter test --no-pub --concurrency=1 test/features/planning/plan_preview_issue_policy_test.dart test/features/planning/plan_preview_test.dart test/features/planning/unscheduled_display_test.dart test/features/planning/plan_preview_apply_test.dart test/app/plan_preview_title_test.dart test/app/plan_preview_regression_test.dart
```

Expected: PASS；截图中的三个重复／误导文案不能再出现。

- [ ] **Step 12: Commit**

```powershell
git add lib/features/planning/plan_preview_issues.dart lib/features/planning/plan_preview_page.dart lib/app/router.dart lib/scheduling/explanations.dart lib/scheduling/preview_failure_lines.dart test/features/planning/plan_preview_issue_policy_test.dart test/features/planning/plan_preview_test.dart test/features/planning/unscheduled_display_test.dart test/features/planning/plan_preview_apply_test.dart test/app/plan_preview_title_test.dart test/app/plan_preview_regression_test.dart
git commit -m "fix: make plan preview actionable and safe"
```

### Task 7: 全链路、反向和回归验证

**Files:**
- Modify: `integration_test/emergency_replan_flow_test.dart`
- Modify: `integration_test/first_plan_flow_test.dart`
- Modify: `docs/testing/v1.8.0-core-workflow-acceptance.md`
- Modify tests only if a real changed contract requires it; do not weaken unrelated assertions

**Interfaces:**
- Produces: 自动化证据，证明“生成能过、确认也能过”，不是只证明单层函数。
- Consumes: Tasks 2～6 全部接口。

- [ ] **Step 1: 增加完整应用链测试**

固定时钟与真实内存/临时 Drift 数据库：

1. 当前确认计划包含过去两天的块、今天已结束块、进行中块和未来块；
2. 新建一个 15 分钟、min 30 的任务；
3. 生成提案；
4. 打开预览；
5. 断言没有 blocker；
6. 确认应用；
7. 重新读取 current plan；
8. 断言新块存在、历史块未写入新提案、历史 API 仍可读旧块；
9. 再生成一次，结果不出现重复块或重复缺口。

- [ ] **Step 2: 增加部分计划链测试**

构造容量只能安排 30/60 分钟：

- trusted=true 仍不自动写；
- 预览显示一次“还缺 30 分钟”；
- 取消部分确认，current plan 不变；
- 再确认“仍然应用”，只写可安排 30 分钟，任务仍为待办，缺口不被伪造为完成。

- [ ] **Step 3: 增加阻断链测试**

直接构造一个含 `startsBeforePlanningWindow` 非锁定块的非法提案：

- 页面显示任务标题和“早于本次规划范围”；
- 主按钮禁用；
- 自动应用调用 0；
- 仓储写入 0；
- current plan 逐块相同。

- [ ] **Step 4: 运行相关子系统测试**

```powershell
flutter test --no-pub --concurrency=1 test/application test/scheduling test/features/planning test/app/plan_preview_title_test.dart test/app/replan_prompt_test.dart
```

Expected: PASS；不得通过删除测试或扩大 `skip` 达成。

- [ ] **Step 5: 运行格式、静态分析和全量单元测试**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
```

Expected:

- format exit 0，0 files changed；
- analyze 显示 `No issues found!`；
- test exit 0；
- 若出现既有 Drift 多数据库 warning，记录但不得把真实失败归为 warning；
- widget hit-test warning 必须修测试滚动/可见性，不得忽略。

- [ ] **Step 6: 运行 Windows 集成测试逐条模式**

按项目既有约束逐条运行，避免批量 debug connection 假失败：

```powershell
flutter test --no-pub integration_test/first_plan_flow_test.dart -d windows
flutter test --no-pub integration_test/emergency_replan_flow_test.dart -d windows
```

Expected: 两条分别退出 0；失败时保存完整日志，禁止只重跑到偶然通过。

- [ ] **Step 7: 更新验收证据**

在 `v1.8.0-core-workflow-acceptance.md` 追加：commit、命令、测试数量、退出码、场景结果。旧的 2068 项记录保留为上一候选证据，不覆盖成新结果。

- [ ] **Step 8: Commit**

```powershell
git add integration_test/emergency_replan_flow_test.dart integration_test/first_plan_flow_test.dart docs/testing/v1.8.0-core-workflow-acceptance.md
git commit -m "test: verify rolling plan preview end to end"
```

### Task 8: Windows 人工验收与发布阻断判定

**Files:**
- Modify: `docs/testing/manual-windows-checklist.md`
- Modify: `docs/testing/v1.8.0-core-workflow-acceptance.md`

**Interfaces:**
- Produces: 用户真实数据副本上的人工结论；不产生正式发布资产。
- Consumes: Task 7 全绿提交。

- [ ] **Step 1: 使用数据库副本，不碰唯一用户库**

通过应用备份功能导出，再恢复到独立测试位置。记录源备份 SHA-256、测试副本路径、恢复前后记录数。不得复制正在被应用占用的裸 SQLite 文件作为唯一备份手段。

- [ ] **Step 2: 执行截图原场景**

环境：Asia/Shanghai，当前确认计划含前两日安排，今天含已结束与未来安排，周期目标存在剩余量。

验收：

- 预览不显示规划窗口之前的日期；
- 没有“排程输入无效”；
- 每个缺口只出现一次；
- 完整方案按钮为“确认应用”；
- 部分方案按钮为“应用可安排部分”并有二次确认；
- 阻断方案按钮为“无法应用”；
- 确认成功后日历与任务列表一致；
- 过去日期仍能从日历历史看到，且不重复。

- [ ] **Step 3: 执行短余量矩阵**

| required | min/max | granularity | 必须结果 |
| ---: | --- | ---: | --- |
| 15 | 30–90 | 5 | 排 15，无 invalid |
| 12 | 30–90 | 5 | 排 10、缺 2；可明确应用部分 |
| 3 | 30–90 | 5 | 不排、缺 3；无伪造块 |
| 100 | 30–90 | 5 | 普通块均 >= 30 |
| 20 continuous | 30–90 | 5 | 单一 20 分钟块，无片段长度 invalid |
| 20 | 30–90 | 10 | 单一 20 分钟块，全部落 10 分钟网格 |

- [ ] **Step 4: 执行按钮与自动应用矩阵**

对 clean/partial/blocked/stale 四态逐一检查按钮文字、可点击状态、写库次数、提示内容和导航。开启“信任自动调整”后重复矩阵：只有 clean 可自动应用。

- [ ] **Step 5: 记录真实结果**

每项填写日期、操作人、实际结果、截图路径和 PASS/FAIL。任何 FAIL 阻塞 Task 9；不得把“未执行”写成 PASS。

- [ ] **Step 6: Commit evidence**

```powershell
git add docs/testing/manual-windows-checklist.md docs/testing/v1.8.0-core-workflow-acceptance.md
git commit -m "docs: record plan preview repair acceptance"
```

### Task 9: 冻结新候选并交付可安装包

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/app/backup_assembly.dart`
- Modify: `test/app/version_consistency_test.dart`
- Modify: `docs/release/build-ledger.md`
- Create: `docs/release/1.8.0-buildNN-user-guide.md`
- Create or update the matching release notes / GitHub release body required by `docs/release/windows-release.md`
- Rebuild: Windows portable directory, ZIP, signed MSIX, `.cer`, installer scripts, install instructions, SHA-256 manifest

**Interfaces:**
- Produces: 下一份 1.8.0 候选安装包；不创建正式 GitHub Release，除非用户另行明确授权且全套发布条件满足。
- Consumes: Tasks 1～8 全部 PASS 证据。

- [ ] **Step 1: 确认候选号**

读取 `docs/release/build-ledger.md`，取全局下一个未使用 build。若仍为 `+44`，使用 `1.8.0+44`；若已被占用，取下一个，禁止复用。MSIX 版本严格依照 `version-policy.md` 当前规则，不自行发明 revision 语义。

- [ ] **Step 2: 一次性更新所有版本事实源**

更新 `pubspec.yaml`、`backup_assembly.dart`、版本一致性测试、用户指南与 build ledger。运行：

```powershell
flutter test --no-pub test/app/version_consistency_test.dart
```

Expected: PASS，所有显示与备份清单一致。

- [ ] **Step 3: 最终干净回归**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
```

Expected: 全部 exit 0。版本变更后任何代码变化都使本候选失效，必须重新分配 build 并重跑。

- [ ] **Step 4: 构建 Windows Release 与 MSIX**

严格按 `docs/release/windows-release.md` 执行项目现有构建、签名和打包脚本。不得手工复制旧 build 的二进制冒充新包。

- [ ] **Step 5: 检查交付内容**

必须同时存在：

- Windows 便携目录；
- ZIP；
- 已签名 MSIX；
- 公钥 `.cer`；
- `安装.cmd` 与 `install-planner.ps1`；
- 安装说明；
- 本版本用户指南；
- SHA-256 清单。

必须不存在：

- `user-data/`；
- `.sqlite/.db/.bak`；
- `.pfx/.p12/.key/.pem`；
- 日志、诊断输出、测试 exe、个人课表或截图。

- [ ] **Step 6: 验证签名、哈希与覆盖安装**

记录 `Get-AuthenticodeSignature` 结果、所有资产 SHA-256、ZIP 条目数、MSIX manifest identity/version。用非开发环境 Windows x64 安装并启动；若旧候选不能原位升级，按版本政策如实记录原因，不得声称覆盖安装通过。

- [ ] **Step 7: 再跑一次人工核心场景**

安装后的二进制必须重新执行 Task 8 的截图原场景、15 分钟短余量、partial 二次确认、blocked 禁用按钮。开发模式通过不能替代安装包验收。

- [ ] **Step 8: 更新台账但保持候选状态**

记录目录、ZIP、MSIX、大小、SHA-256、签名、自动化数量和人工结果。没有 GitHub Release/tag 前状态仍为“候选构建，尚未正式发布”。

- [ ] **Step 9: Commit release metadata**

只提交源码与发布文档允许入库的内容，不提交大体积二进制和私钥：

```powershell
git add pubspec.yaml pubspec.lock lib/app/backup_assembly.dart test/app/version_consistency_test.dart docs/release docs/testing
git status --short
git commit -m "chore: prepare repaired 1.8 candidate"
```

提交前逐项检查 staged 列表；发现 build、数据库、私钥或用户数据立即停止并取消暂存对应文件，不得提交。

## 4. 自动化验收矩阵

| 场景 | 层级 | 必须断言 | 所属任务 |
| --- | --- | --- | --- |
| 昨日块 | source + engine | 不进 proposal、不计 scheduled、历史 API 可见 | T1/T2 |
| 恰好在 now 结束 | partition | historical | T2 |
| 跨过 now 的进行中块 | validator | 原位保留，允许 start 早于 window | T2/T3 |
| 非锁定伪造窗口外块 | validator | blocking invalid，原因 startsBeforePlanningWindow | T3 |
| 15 < min30 | engine + validator + apply | 15 分钟块合法，可完整应用 | T3/T7 |
| 12、粒度5 | engine + preview | 10 分钟块 + 2 分钟 warning，无 invalid | T3/T6 |
| 连续 20 < min30 | engine + validator | 一个 20 分钟块合法 | T3 |
| 规则粒度10 | source + generator + validator | 09:33→09:40，全块对齐10 | T3 |
| 容量不足 | proposal | unscheduled 有值，conflicts 无 insufficientCapacity | T4 |
| partial + trusted | flow | 不自动 apply，进入 preview | T5 |
| partial + completeOnly | application | partialRequired，零写入 | T5 |
| partial + allowPartial | application | 明确确认后写一次 | T5/T6 |
| blocker | page + application | 按钮禁用、零写入 | T5/T6 |
| apply-time invalid | router | 具体标题+原因，非笼统 snackbar | T6 |
| 历史 diff | preview assembly | 不显示窗口前日期 | T6 |
| 空分组 | widget | 不渲染四五张“无”卡片 | T6 |
| 快速双击 | widget + fake repo | 写入一次 | T6 |
| 完整真实链 | integration | 生成、预览、确认、重读一致 | T7 |

## 5. 人工验收清单

- [ ] 当前时间之后生成的新块没有落入过去。
- [ ] 昨天与今天已结束的历史安排仍在日历中可见。
- [ ] 历史安排没有因为重排重复。
- [ ] 预览不再出现不相关的过去日期。
- [ ] 同一任务缺口只出现一次。
- [ ] 缺口显示任务标题、缺多少分钟和具体原因。
- [ ] 完整方案显示“确认应用”。
- [ ] 部分方案显示“应用可安排部分”，且必须二次确认。
- [ ] 阻断方案显示“无法应用”，不能点击。
- [ ] stale 方案只能重新生成。
- [ ] 取消预览或取消部分确认后，当前计划完全不变。
- [ ] 应用失败时显示具体任务和规则，而不是“排程输入无效”。
- [ ] 开启信任自动调整后，部分／阻断方案仍不会自动落库。
- [ ] 15 分钟短任务可以正常安排并确认。
- [ ] 安装包环境与开发运行结果一致。

## 6. 完成定义

只有同时满足下列条件才能说“修复完成”：

1. Tasks 1～7 的新增和修改测试全部通过；
2. `dart format --output=none --set-exit-if-changed lib test integration_test` 退出 0；
3. `flutter analyze --no-pub` 为 0 问题；
4. `flutter test --no-pub --concurrency=1` 全量退出 0；
5. 两条 Windows 集成测试逐条退出 0；
6. Task 8 人工矩阵全部填写且无 FAIL；
7. 截图原场景在安装后的候选包中复测通过；
8. 历史块仍可见但不进入未来提案；
9. 不再存在“候选生成合法、最终确认却因同一规则失败”的契约分裂；
10. 新候选的完整安装包、签名、哈希和台账齐全；
11. Git 工作树只含有意变更，无数据库、私钥、日志或构建垃圾；
12. 未经用户明确授权，不创建 tag、不上传 GitHub Release、不宣称正式发布。

## 7. 禁止的捷径

- 禁止简单删除 validator 的所有窗口或片段检查来“让确认通过”。
- 禁止把所有 conflicts 都降级为 warning。
- 禁止只禁用按钮而不修历史块进入提案的根因。
- 禁止只过滤 UI 文本、让历史块继续污染 `scheduledByTask`。
- 禁止把 `proposal.conflicts` 与 `proposal.unscheduled` 合并成字符串数组。
- 禁止用 taskId/UUID 代替标题。
- 禁止在 trusted 路径自动传 `allowPartial`。
- 禁止为了通过截图测试写死日期、任务名或 76 分钟。
- 禁止修改系统时间、用户唯一数据库或旧版本资产作为测试手段。
- 禁止在完整回归失败时打包候选。
- 禁止复用 `1.8.0+43` 交付不同代码内容。

## 8. 执行交接

执行代理开始前必须完整阅读：

1. 本文；
2. `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md` §11、§13、§15；
3. `docs/release/version-policy.md`；
4. `docs/release/windows-release.md`；
5. `docs/testing/v1.8.0-core-workflow-acceptance.md` 中当前 1.8 证据。

每完成一个 Task，回复中必须列出：提交哈希、改动文件、红灯命令与失败原因、绿灯命令与通过数量、尚未验证的人工项。不得用“应该没问题”“全测过了”代替证据。
