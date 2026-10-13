# Personal Planner Visible Free Time False Shortage Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. **Do not use parallel agents for this plan.** The tasks share the same scheduling input, candidate, proposal, and preview contracts. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复“七日日历仍有可排空档，但生成计划却把任务全部报为可用时间不足”的故障；确保进入本次规划的任务范围正确、候选容量可解释、精力偏好不被误当成硬限制、预览只报告真实缺口。

**Architecture:** 先把排程输入按规划窗口分类，彻底隔离未来周期实例；再从现有空闲区间与候选生成链产出每个任务的容量证据，并用同一份证据决定结构化失败原因。引擎若无法用这些证据解释缺口，必须报告“排程结果无法解释”，不得伪装成容量不足。预览层只翻译引擎事实，不自行推测。

**Tech Stack:** Flutter / Dart、Drift / SQLite、现有确定性排程引擎、IANA 时区、Flutter tests、Windows x64。

**Spec:** `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md` §3、§11、§13；`docs/superpowers/plans/2026-10-08-v1.7.1-recurring-goal-even-distribution-fix.md` §3；`docs/superpowers/plans/2026-10-12-plan-preview-validation-repair.md` §1.3～§1.6。本文件是“可见空闲与容量误报”的独立约束，发生冲突时以本文件列出的专项不变量和验收用例为准。

## Global Constraints

- **文档状态：仅完成实施计划，专项代码尚未按本计划实施。** 执行者不得把“已有部分相关修复”写成“本故障已修复”。
- 本计划只处理“有可排空档却误报容量不足”。课程管理、保护时间编辑、通知、托盘、统计、安装器和版本发布不在本计划内。
- 必须由一个实现代理、一个工作树按 Task 1 → Task 8 串行执行。不得让多个代理同时改 `repository_schedule_problem_source.dart`、`schedule_engine.dart`、`availability_builder.dart` 或同一批测试。
- 当前工作树为 `G:\best-planing\.worktrees\native-implementation`，分支为 `feature/native-implementation`。执行前记录状态；不得 reset、clean、checkout 覆盖或删除现有改动。
- 当前目录已有其它未跟踪文档。只能暂存本计划指定的文件，禁止使用无筛选的 `git add -A`。
- 不修改数据库 schema，不迁移或删除用户数据，不改变备份格式、应用 identity、publisher、AUMID、数据目录或更新通道。
- 不新增第三方依赖，不增加联网权限，不记录用户任务标题、备注、日程或数据库内容到遥测和普通日志。
- 用户数据库只能用副本只读核验。不得把 SQLite、导出数据、路径中的用户名、任务 UUID、真实标题或截图写进测试夹具、提交和发布产物。
- 所有时间范围继续使用 UTC 半开区间 `[startUtc, endUtc)`；本地日期与星期只能通过 `TimeZoneDatabase` 转换。
- `TaskEnergyLevel` 和 `preferredWindow` 都是评分偏好，不是硬约束。任何代码不得因为“高精力”而删除中低精力时段候选。
- 固定日程、保护时间、睡眠、锁定块、最早开始、截止、允许星期、连续时长、粒度、休息和每日上限是硬约束；不得为了消除提示而绕过它们。
- 不重新实现已完成的两个修复：短余量由 `shortRemainderAllowance()` 统一；`AvailabilityBuilder` 必须继续返回全天真实空闲，不得重新按每日上限截断候选。
- UI 不得用“日历卡片之间看起来是空的”直接判定任务可排。真实可排性必须来自规划窗口、硬占用和任务约束共同计算。
- 引擎不得在没有 `availableMinutes` 或其它可判定证据时，把默认原因写成“可用时间不足”。
- 任何改变同一输入排程结果的生产修改，都必须把 `DeterministicScheduleEngine.algorithmVersion` 从 `14` 提升到 `15`。这是算法版本，不是软件版本。
- 本计划不改 `pubspec.yaml`、MSIX 版本或发布台账。只有专项验收和全量门禁通过后，发布流程才能另行分配 build。
- 每次生产修改先写能因目标缺陷失败的测试。编译错误、夹具错误、时区写错、运行器故障都不算有效红灯。
- 若 `flutter` 或仓库测试包装器出现 `0xc0000142`、`-1073741502`、无输出退出或重复弹窗，只记录一次并停止重试。运行环境修复不属于本计划，不能把“未运行”登记为 PASS。

## Review Focus

- 下周周期实例可以存在于数据库和任务页，但不得作为普通任务进入本周规划，也不得出现在本周缺口预览。
- 普通任务若 `availableFromUtc >= planningWindow.endUtc`，本次规划应静默排除；不能先纳入再报告容量不足。
- 普通任务只要可用区间与窗口相交，就仍应进入规划；不能为了消除告警而把真正需要安排的任务过滤掉。
- 已过截止时间的未完成任务不能静默消失；它要得到截止窗口原因，而不是未来任务的排除处理。
- 原始空闲、符合任务硬约束的容量、最大连续空档、每日上限余量和最终缺口必须能逐层核对。
- 高精力任务在高精力时段没有容量时，仍可排入其它合法时段；能量匹配只能改变候选顺序和分数。
- 若某任务存在合法候选且未被任何硬约束拒绝，却最终排入 0 分钟，结果必须被识别为无法解释的排程异常，不能显示容量不足。
- 同名的本周与下周周期实例必须通过 task id / cycle id 区分；预览不得把两个实例合成两条同名“还缺 210 分钟”。
- 预览只显示任务标题和结构化原因，不显示 UUID、内部枚举名或笼统的无证据文案。
- 修复后的提案必须继续通过最终校验、部分计划确认和自动应用安全边界。

---

## 1. 故障定义与已核实事实

### 1.1 用户可见现象

在七日日历中，未来几天存在大量没有固定日程、保护时间或计划块的时段；生成计划后，预览仍出现：

- 普通任务还缺 180 分钟；
- 同名周期目标出现两条，各还缺 210 分钟；
- 三条都被解释为“可用时间不足”；
- 本次提案 `scheduledMinutes = 0`、`unscheduledMinutes = 600`。

这不是单一 UI 文案问题。预览只是显示了引擎输出的 `unscheduled`；必须沿“数据库事实 → 排程输入 → 空闲区间 → 候选 → 选择 → 最终校验 → 预览”逐段定位。

### 1.2 已经确认、不得重复修的部分

| 项目 | 当前代码事实 | 本计划处理方式 |
| --- | --- | --- |
| 15 分钟剩余、最小片段 30 分钟 | `CandidateGenerator` 已用有效最小片段和 `shortRemainderAllowance()` 处理 | 保留回归，不重写 |
| 每日上限导致全天候选被截断 | `AvailabilityBuilder` 已改为返回全天真实空闲，每日上限在引擎和校验器执行 | 保留回归，不恢复旧截断 |
| 历史块污染未来提案 | 算法 14 已通过 `classifyConfirmedBlocks()` 分离历史、进行中和未来块 | 保留回归 |
| 缺口与容量冲突重复显示 | 容量缺口已统一为 `UnscheduledTask` | 不恢复双重来源 |
| 裸 UUID | 预览已有 `TaskTitleLookup` / `titleByTaskId` 翻译链 | 本计划继续禁止回退 UUID |

### 1.3 已确认的当前缺陷

`RepositoryScheduleProblemSource.load()` 当前先把 `watchOpenTasks()` 返回的**全部**未完成任务转成 `SchedulableTask`。随后 `_recurringInputs(nowUtc)` 只读取“包含 now 的本周周期”，并只删除这些本周周期的 task id，再加入周期视角输入。

与此同时，`ensureCycles()` 会为滚动七天补生成后续周期。于是出现以下确定路径：

1. 下周周期实例已经生成，并且对应普通任务仍是 open；
2. 它进入 `openTasks`；
3. `_recurringInputs()` 只返回本周实例；
4. 删除普通输入时只删除本周实例 id；
5. 下周实例保留为一件普通任务；
6. 它的 `availableFromUtc` 落在本次规划窗口终点或之后；
7. 引擎无法生成候选，却仍可能为它计算出本次目标；
8. 预览错误显示第二条同名周期目标缺口。

这条缺陷可以直接从代码路径和故障数据库形状确认。它解释了“同名周期目标重复”，但**不能单独解释本周普通任务与本周周期实例为什么也排入 0 分钟**。后者必须由 Task 1 的端到端红灯和阶段证据定位。

### 1.4 尚未确认、禁止先入为主的部分

以下都只是可能性，不得在没有红灯证据时修改：

- 候选生成后的按日均分预算是否被算成 0；
- 已确认块、进行中块或休息间隔是否错误占满候选；
- 截止时间是否以错误端点进入输入；
- 每日可移动上限是否被已有块重复计费；
- `_improve()` / `minimizeChangedBlocks()` 是否丢失已经选择的块；
- 输入中的重复 task id 是否让 `targets`、`scheduledByTask` 或 `unscheduled` 相互覆盖；
- 真实数据库中的规则是否与界面展示不一致。

执行者必须先证明“哪一阶段从非零变成零”，再修改那一阶段。

### 1.5 高精力不是硬限制

当前 `CandidateScorer` 只有在 `hardConstraintsSatisfied == false` 时拒绝候选。`energyMatch` 只是正负评分：匹配时加分，不匹配时减分。它不能让候选消失。

专项验收必须证明：

- 高精力任务只有低精力时段可用时，仍会排进去；
- 高精力和中精力候选同时存在时，高精力候选优先；
- 失败原因枚举中不存在“精力时段不可用”这种硬限制原因。

### 1.6 “日历空白”与“任务可排”的严格定义

为避免继续用一个“空闲”词混淆不同层次，本计划固定四个量：

| 名称 | 定义 | 用途 |
| --- | --- | --- |
| `calendarGapMinutes` | 规划窗口扣除固定日程、保护时间、睡眠、锁定块并按粒度对齐后的空闲分钟并集 | 回答日历层面还有多少空档 |
| `taskWindowMinutes` | 在 `calendarGapMinutes` 上继续应用任务的最早开始、截止、允许星期后的分钟并集 | 回答这件任务能在哪些时段尝试 |
| `taskPlaceableMinutes` | `taskWindowMinutes` 中满足连续/可拆分、最小/最大片段和粒度的可放置分钟 | 回答任务形状能利用多少容量 |
| `remainingPlaceableMinutes` | 再扣除本次提案中已被其它任务选择、休息间隔和每日上限占用后的可放置分钟 | 回答当前缺口的直接容量证据 |

分钟必须按**区间并集**计算，禁止把大量相互重叠的候选时长直接相加。

### 1.7 任务进入本次规划的边界

对每个普通任务计算：

```text
effectiveStart = max(planningWindow.startUtc, availableFromUtc ?? planningWindow.startUtc)
effectiveEnd   = min(planningWindow.endUtc, dueAtUtc ?? planningWindow.endUtc)
```

分类规则固定如下：

| 条件 | 分类 | 行为 |
| --- | --- | --- |
| `availableFromUtc >= window.endUtc` | `futureOutsideWindow` | 不进入 `problem.tasks`，不生成缺口 |
| `dueAtUtc <= window.startUtc` | `deadlineElapsed` | 进入问题报告，显示截止已过/截止窗口为 0；不得静默消失 |
| `effectiveStart < effectiveEnd` | `intersectsWindow` | 正常进入排程 |
| 数据不是 UTC、时长非正、min/max 非法 | `invalid` | 作为阻断输入错误，不尝试排程 |

周期实例多一层规则：所有已生成周期实例先从普通任务输入中剥离；本次只由 `RecurringScheduleInput` 把与规划窗口相交、状态 open、剩余量大于 0 的实例重新加入。未来周期保留在数据库和任务页，不进入本次 `ScheduleProblem`。

---

## 2. 目标数据流与接口

### 2.1 排程输入准入

新增纯函数文件：

`lib/application/schedule_window_admission.dart`

建议接口：

```dart
enum ScheduleWindowAdmissionCode {
  intersectsWindow,
  futureOutsideWindow,
  deadlineElapsed,
  invalid,
}

enum ScheduleWindowInvalidReason {
  nonUtcBoundary,
  nonPositivePlanningWindow,
  startNotBeforeDeadline,
}

final class ScheduleWindowAdmission {
  const ScheduleWindowAdmission({
    required this.code,
    this.effectiveRange,
    this.invalidReason,
  });

  final ScheduleWindowAdmissionCode code;
  final TimeRange? effectiveRange;
  final ScheduleWindowInvalidReason? invalidReason;
}

ScheduleWindowAdmission classifyTaskForPlanningWindow({
  required PlannerTask task,
  required TimeRange planningWindow,
});
```

约束：

- 函数不查数据库、不读系统时钟、不依赖 Flutter；
- 端点使用半开区间；
- 返回值不修改任务；
- `futureOutsideWindow` 不是错误；
- `deadlineElapsed` 不是 `futureOutsideWindow`；
- 生产装配和测试夹具必须调用同一个函数，不能复制条件。

### 2.2 周期实例去重与归属

不对每个 open task 调 `findCycleByTaskId()`，避免 N+1 查询。装配流程必须批量完成：

1. 调用 `ensureCycles()`；
2. 使用新增的 `findCyclesByTaskIds(openTaskIds)` 一次反查这些 open task 的周期归属；
3. 构造 `cycleByTaskId`；
4. 从普通 `openTasks` 映射中剥离 `cycleByTaskId.keys`；
5. 只通过 `_recurringInputs()` 加回本次允许的周期实例；
6. 最终断言 `problem.tasks` 中每个 `id` 的输入契约明确：普通任务最多一条；按允许星期拆分的周期输入可以同 id 多窗口，但必须有一致的目标与周期归属。

批量端口契约固定为：空集合直接返回空列表；非空集合按 `periodStartLocalDate`、`templateId`、`taskId` 稳定排序；每个 task id 最多一条。不得改用日期猜测“哪些 open task 可能是周期实例”，也不得退回逐任务查库。

### 2.3 空闲与容量证据

扩展 `AvailabilityBuilder`，保留现有 `build()` 接口并让它委托到详细分析，避免无关调用点一次性改写：

```dart
enum AvailabilityBlockerKind {
  fixed,
  protected,
  sleep,
  locked,
}

final class BlockedAvailabilitySegment {
  const BlockedAvailabilitySegment({
    required this.range,
    required this.kinds,
  });
  final TimeRange range;
  final Set<AvailabilityBlockerKind> kinds;
}

final class AvailabilityAnalysis {
  const AvailabilityAnalysis({
    required this.slots,
    required this.blockedSegments,
    required this.calendarGapMinutes,
  });
  final List<AvailabilitySlot> slots;
  final List<BlockedAvailabilitySegment> blockedSegments;
  final int calendarGapMinutes;
}
```

实现要求：

- 重叠占用采用带标签的扫线或等价确定性算法；
- 同一分钟只能从总容量扣一次；
- 一个区间可同时带多个 blocker kind；
- `calendarGapMinutes == slots.sum(durationMinutes)`；
- `build(input)` 必须逐值等于 `analyze(input).slots`，确保旧行为不漂移。

再新增纯函数：

`lib/scheduling/task_capacity_analyzer.dart`

```dart
final class TaskCapacityEvidence {
  const TaskCapacityEvidence({
    required this.calendarGapMinutes,
    required this.taskWindowMinutes,
    required this.taskPlaceableMinutes,
    required this.remainingPlaceableMinutes,
    required this.largestTaskWindowGapMinutes,
    required this.largestRemainingGapMinutes,
    required this.dailyLimitRemainingMinutes,
  });
  // 字段按名称定义；所有分钟均 >= 0。
}
```

证据只从当前 `ScheduleProblem`、`AvailabilityAnalysis`、任务和最终块集合计算，不读数据库、不读 UI、不读实时系统时钟。

### 2.4 结构化失败原因

保留当前 `UnscheduledReason` 体系，但改变“默认容量不足”的规则：

- `insufficientCapacity` 只能在 `remainingPlaceableMinutes < shortageMinutes` 且证据数字存在时使用；
- `continuousGapTooShort` 必须带 `requiredMinutes` 与 `largestRemainingGapMinutes`；
- `dailyLimitReached` 必须带日上限余量；
- `availableTimeNotReached` 只用于任务开始时间仍落在本次窗口之外的兼容路径，正常准入分类应已把它排除；
- 空证据不得自动落到 `insufficientCapacity`。

新增原因：

```dart
UnscheduledReasonCode.unexplainedSchedulingFailure
```

使用条件：任务存在可放置容量，最终仍有缺口，但已收集的硬约束证据不能解释这项缺口。用户文案固定为：

> 排程没有使用仍可用的合法时段。本次计划未自动应用，请重新生成；若问题持续，请导出诊断信息。

该原因不是“容量不足”，也不能包含 UUID。它必须作为阻断问题进入预览，禁止自动应用；人工“应用可安排部分”也不得绕过。实现时可以通过新增 `ConflictCode.schedulingInvariantViolation` 把它提升为 blocker，但只能保留一条用户可见问题，不能同时显示 warning 和 blocker。

### 2.5 不变量

实现后必须满足：

```text
0 <= remainingPlaceableMinutes
   <= taskPlaceableMinutes
   <= taskWindowMinutes
   <= calendarGapMinutes

scheduledForTask + shortage == targetForTask

insufficientCapacity
  => availableMinutes != null
  && availableMinutes < requiredMinutes

legalCandidateExists
  && selectedMinutes == 0
  && noHardRejection
  => unexplainedSchedulingFailure
```

任何不变量失败都必须让测试失败；不得通过 `clamp` 静默掩盖错误。

---

## 3. 文件职责

### 新建文件

| 文件 | 唯一职责 |
| --- | --- |
| `lib/application/schedule_window_admission.dart` | 纯函数判断普通任务与本次规划窗口的关系 |
| `lib/scheduling/task_capacity_analyzer.dart` | 从真实空闲、任务硬约束和已选块计算任务容量证据 |
| `test/application/schedule_window_admission_test.dart` | 钉住规划窗口端点和普通任务准入 |
| `test/application/visible_free_time_shortage_regression_test.dart` | 使用匿名化的真实故障形状走仓储装配与引擎全链路 |
| `test/scheduling/task_capacity_analyzer_test.dart` | 钉住容量分层、区间并集和原因选择 |
| `test/app/visible_free_time_preview_test.dart` | 钉住预览标题、数字、阻断级别和无 UUID |
| `docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md` | 保存自动化与人工验收证据 |

### 修改文件

| 文件 | 修改责任 |
| --- | --- |
| `lib/application/repository_schedule_problem_source.dart` | 批量识别周期实例；剥离未来周期；应用普通任务准入分类；建立输入不变量 |
| `lib/domain/repositories/recurring_task_repository.dart` | 增加 `findCyclesByTaskIds(Set<EntityId>)` 批量归属查询契约 |
| `lib/data/database/daos/recurring_task_dao.dart` | 实现按 task id 集合批量读取，保持只读和稳定排序 |
| `lib/data/repositories/drift_recurring_task_repository.dart` | 适配必要的批量查询 |
| `lib/scheduling/availability_builder.dart` | 返回带来源的详细空闲分析；现有 `build()` 行为不变 |
| `lib/scheduling/schedule_proposal.dart` | 增加无法解释原因和可选容量证据；固定主原因规则 |
| `lib/scheduling/schedule_engine.dart` | 使用容量证据归因；检测无法解释的零安排；算法版本升到 15 |
| `lib/scheduling/explanations.dart` | 翻译新的结构化原因和证据，不猜测 |
| `lib/features/planning/plan_preview_issues.dart` | 将无法解释原因渲染为 blocker；容量缺口继续为 warning；去重 |
| `lib/scheduling/preview_failure_lines.dart` | 复用同一翻译，保持延后/普通生成一致 |
| `test/application/recurring_enters_schedule_test.dart` | 增加未来周期不进入当前窗口的生产接线测试 |
| `test/application/recurring_even_distribution_test.dart` | 保留本周/下周实例隔离和均分回归 |
| `test/scheduling/unscheduled_reason_test.dart` | 增加证据完整性、高精力软偏好和无法解释分支 |
| `test/scheduling/availability_builder_test.dart` | 增加详细分析与旧 slots 逐值一致性 |
| `test/features/planning/plan_preview_issue_policy_test.dart` | 增加新原因严重级别、数字和去重 |
| `docs/testing/manual-windows-checklist.md` | 追加本专项人工验收入口 |

若实际文件职责与表中不符，先更新本节并说明原因，再改代码。禁止把排程判断塞进路由或 Widget。

---

## 4. 任务依赖与停止条件

```text
Task 1 真实故障红灯与阶段证据
  └─ Task 2 规划窗口准入
       └─ Task 3 周期实例隔离
            └─ Task 4 容量分析与失败归因
                 └─ Task 5 修复零安排的实际根因
                      └─ Task 6 预览与安全边界
                           └─ Task 7 自动化回归
                                └─ Task 8 Windows 人工验收与交接
```

出现以下任一情况立即停止，不得继续提交：

- Task 1 无法稳定复现“合法候选非零但排入 0”；此时只能修已确认的未来周期泄漏，不能声称整个故障完成。
- 为让测试通过而删除任务、延后截止、扩大规划窗口、关闭保护时间或提高每日上限。
- 高精力被改成硬过滤，或 preferred window 被改成必须命中。
- 未来周期被从数据库删除，而不是从本次排程输入排除。
- 容量证据通过相加重叠候选得出，导致分钟大于规划窗口。
- `insufficientCapacity` 仍可能没有 `availableMinutes`。
- 提案含 `schedulingInvariantViolation` 却仍能自动应用或点击确认应用。
- 修复要求 schema migration、联网服务或用户数据重写；这些超出专项范围，必须先重新设计并由用户确认。
- Flutter 运行器继续返回 `0xc0000142` / `-1073741502`；不能用静态阅读代替测试通过。
- 目标文件已有不属于本任务的未提交修改且无法安全分离。

---

### Task 1: 用真实故障形状建立红灯与阶段证据

**Files:**

- Create: `test/application/visible_free_time_shortage_regression_test.dart`
- Modify: `docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md`
- Read only: 用户数据库副本、`tool/db_fingerprint.dart`、`tool/db_stats_probe.dart`

**Interfaces:**

- Produces: 可重复、匿名化、固定时钟的端到端红灯；每阶段的任务、slot、candidate、selected、unscheduled 数量。
- Does not modify: 生产代码、用户数据库、算法版本、软件版本。

- [ ] **Step 1: 记录干净基线与运行器状态**

Run:

```powershell
Set-Location 'G:\best-planing\.worktrees\native-implementation'
git status --short --branch
git rev-parse HEAD
flutter --version
```

Expected:

- 记录 HEAD 和现有未跟踪文件；
- `flutter --version` 正常退出；
- 若出现 `0xc0000142`、`-1073741502` 或无输出失败，停止本计划，登记 `BLOCKED-RUNTIME`，不要循环启动 `dart.exe`。

- [ ] **Step 2: 只读记录故障数据库的结构摘要**

使用数据库副本，不直接打开软件正在使用的数据库。记录以下字段，随后全部匿名化：

- 固定时钟；
- 规划窗口；
- 三个 open task 的 `remaining / availableFrom / due / split / min / max / priority / energy`；
- 本周与下周周期实例的 `periodStart / taskId / status / target`；
- 固定、保护、锁定和现有块的时间范围；
- 规则中的粒度、睡眠、每日上限、休息间隔和精力窗口。

Expected: 验收文档只写相对时间和匿名 id，例如 `ordinary-a`、`cycle-current`、`cycle-next`；不得提交数据库或真实 UUID。

- [ ] **Step 3: 建立最小端到端夹具**

在内存 Drift 数据库中使用固定本地时钟和 `Asia/Shanghai`：

- 一件普通高精力任务，目标 180 分钟，截止落在规划窗口内；
- 一个每周 210 分钟的周期目标，同时存在本周实例和下周实例；
- 本周实例可立即开始，下周实例的 `availableFromUtc == planningWindow.endUtc`；
- 放入与真实故障同形但匿名化的固定日程、保护时间、睡眠和规则；
- 保证未来至少有 180 分钟连续合法空档，并另有足够分段容量容纳本周周期目标。

测试必须调用真实的：

```text
RecurringTaskService.ensureCycles
→ RepositoryScheduleProblemSource.load
→ DeterministicScheduleEngine.generate
```

不得直接手写 `ScheduleProblem` 冒充装配链。

- [ ] **Step 4: 先写输入泄漏红灯**

断言修复前应失败：

```dart
expect(problem.tasks.map((t) => t.id), contains(currentCycleTaskId));
expect(problem.tasks.map((t) => t.id), isNot(contains(nextCycleTaskId)));
expect(problem.tasks.where((t) => t.id == ordinaryTaskId), hasLength(1));
```

有效红灯：第二条失败，且能证明 `nextCycleTaskId` 来自 open tasks 的普通映射。

- [ ] **Step 5: 再写零安排红灯与诊断输出**

断言目标行为：

```dart
expect(calendarGapMinutes, greaterThanOrEqualTo(390));
expect(candidatesForOrdinary, isNotEmpty);
expect(candidatesForCurrentCycle, isNotEmpty);
expect(scheduledMinutesFor(ordinaryTaskId), greaterThan(0));
expect(scheduledMinutesFor(currentCycleTaskId), greaterThan(0));
expect(proposal.unscheduled.map((u) => u.taskId), isNot(contains(nextCycleTaskId)));
```

若“零安排”未复现：

- 保留未来周期泄漏红灯；
- 对比故障数据库摘要与夹具，逐项补齐差异；
- 不得为了制造失败写与生产数据不符的夹具；
- 若差异补齐后仍不复现，把该项登记为“尚未复现”，停止 Task 5 的算法修改。

- [ ] **Step 6: 固定阶段证据格式**

测试失败信息至少包含：

```text
window=<start>..<end>
task=<anonymous-id>
admission=<code>
calendarGapMinutes=<n>
taskWindowMinutes=<n>
candidateCount=<n>
selectedMinutes=<n>
shortageMinutes=<n>
reasons=<codes only>
```

不得在生产日志默认输出；此格式只用于测试失败和用户主动导出的诊断。

- [ ] **Step 7: 提交测试夹具，不混生产修复**

```powershell
git add -- test/application/visible_free_time_shortage_regression_test.dart docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md
git diff --cached --check
git commit -m "test: reproduce false shortage with visible free time"
```

Expected: 只提交红灯夹具与验收记录；验收文档明确标记 RED，不写 PASS。

---

### Task 2: 建立规划窗口准入的单一规则

**Files:**

- Create: `lib/application/schedule_window_admission.dart`
- Create: `test/application/schedule_window_admission_test.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`

**Interfaces:**

- Consumes: `PlannerTask`、`TimeRange`。
- Produces: `ScheduleWindowAdmission`。
- Does not know: 周期模板、数据库、UI、候选评分。

- [ ] **Step 1: 写纯函数边界测试**

至少覆盖：

1. 无开始、无截止，进入窗口；
2. `availableFrom == window.start`，进入；
3. `availableFrom == window.end`，归 `futureOutsideWindow`；
4. `availableFrom > window.end`，归 `futureOutsideWindow`；
5. `due == window.start`，归 `deadlineElapsed`；
6. `due < window.start`，归 `deadlineElapsed`；
7. `due == window.end`，有效结束为窗口终点；
8. 开始和截止把窗口夹成 1 个粒度，仍进入；
9. 非 UTC 边界，归 `invalid`；
10. `availableFrom >= due`，归 `invalid`。

- [ ] **Step 2: 运行红灯**

```powershell
flutter test --no-pub --concurrency=1 test/application/schedule_window_admission_test.dart
```

Expected: 因文件/类型未实现失败；不能因测试语法或时区夹具失败。

- [ ] **Step 3: 最小实现纯函数**

严格按 §1.7 实现，不读 clock。`invalidReason` 使用稳定内部 code，不写自由文本；若需要用户文案，交给解释层。

- [ ] **Step 4: 在装配层应用分类**

装配顺序固定为：

```text
读取 open tasks
→ 识别并剥离所有周期实例任务
→ 对普通任务做 window admission
→ 只映射 intersectsWindow / deadlineElapsed
→ 通过周期输入加回允许的周期实例
→ 检查最终 task ids 与输入契约
```

注意：Task 2 先实现普通任务分类；周期剥离在 Task 3 完成。两个任务之间允许红灯仍因未来周期存在而失败。

- [ ] **Step 5: 验证普通未来任务不产生假缺口**

增加生产接线测试：一件 `availableFrom == window.end` 的普通任务仍在任务仓储中，但不在 `problem.tasks`、`proposal.unscheduled` 和预览问题中。

- [ ] **Step 6: 提交**

```powershell
git add -- lib/application/schedule_window_admission.dart lib/application/repository_schedule_problem_source.dart test/application/schedule_window_admission_test.dart test/application/visible_free_time_shortage_regression_test.dart
git diff --cached --check
git commit -m "fix: exclude tasks outside the planning window"
```

---

### Task 3: 隔离本周与未来周期实例

**Files:**

- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/domain/repositories/recurring_task_repository.dart`
- Modify: `lib/data/database/daos/recurring_task_dao.dart`
- Modify: `lib/data/repositories/drift_recurring_task_repository.dart`
- Modify: `test/application/recurring_enters_schedule_test.dart`
- Modify: `test/application/recurring_even_distribution_test.dart`
- Modify: `test/application/visible_free_time_shortage_regression_test.dart`

**Interfaces:**

- Produces: 每个周期实例只能通过周期输入进入排程；未来实例不参与当前提案。
- Preserves: `ensureCycles()` 的幂等生成和任务页可见性。

- [ ] **Step 1: 写“数据库有两周，排程只有当前窗口”红灯**

在真实 Drift 仓储中：

- `ensureCycles()` 后断言仓储存在本周、下周两个 cycle；
- `watchOpenTasks()` 可以看见两个实例任务；
- `source.load()` 只包含与规划窗口相交的实例；
- 下周实例仍在仓储中，没有被删除、完成或归档。

- [ ] **Step 2: 写同名实例隔离测试**

本周和下周使用同一模板标题，但不同 task id。断言：

- 当前 proposal 最多出现本周 task id；
- 下周 task id 不出现在 blocks、unscheduled、explanations；
- 标题映射有两个同名值也不会生成两条当前缺口。

- [ ] **Step 3: 实现批量周期归属查询**

新增准确端口：

```dart
Future<List<RecurringTaskCycle>> findCyclesByTaskIds(Set<EntityId> taskIds);
```

DAO 只按 `recurring_task_cycles.task_id IN (...)` 查询，不按日期猜测；空集合不发 SQL。结果按 `periodStartLocalDate`、`templateId`、`taskId` 稳定排序。数据库已有 `task_id` 唯一约束，测试仍要断言结果中 task id 不重复。

装配层传入 `openTasks.map((task) => task.id).toSet()`，据返回值构造 `cycleByTaskId`。这样无论周期是本周、下周、跨时区边界或异常遗留，都能先从普通任务输入中剥离，再由周期规则决定是否加回。

- [ ] **Step 4: 先剥离、后加回**

从普通任务映射中删除 `cycleByTaskId.keys`，再只加 `_recurringInputs()` 返回的实例。最终增加开发期断言：

```dart
assert(
  ordinarySchedulable.every((task) => !cycleByTaskId.containsKey(task.id)),
);
```

生产逻辑不得依赖 assert 才正确。

- [ ] **Step 5: 防止同一 id 的错误重复**

允许星期拆分会产生同一 task id 的多个时间窗口。新增测试区分：

- 同一周期实例的合法多窗口；
- 普通映射 + 周期映射的非法重复；
- 两个不同周期实例的不同 task id。

不得简单 `toSet()` 去重后丢掉 selected weekdays 窗口。

- [ ] **Step 6: 运行专项测试**

```powershell
flutter test --no-pub --concurrency=1 test/application/recurring_enters_schedule_test.dart test/application/recurring_even_distribution_test.dart test/application/visible_free_time_shortage_regression_test.dart
```

Expected: 未来周期泄漏红灯转绿；若普通任务和本周周期仍排入 0，保留该红灯进入 Task 4/5。

- [ ] **Step 7: 提交**

```powershell
git add -- lib/application/repository_schedule_problem_source.dart lib/domain/repositories/recurring_task_repository.dart lib/data/database/daos/recurring_task_dao.dart lib/data/repositories/drift_recurring_task_repository.dart test/application/recurring_enters_schedule_test.dart test/application/recurring_even_distribution_test.dart test/application/visible_free_time_shortage_regression_test.dart
git diff --cached --check
git commit -m "fix: isolate recurring cycles by planning window"
```

只暂存实际修改的文件；不存在改动的可选文件不要强行加入。

---

### Task 4: 建立可审计的容量证据与失败归因

**Files:**

- Create: `lib/scheduling/task_capacity_analyzer.dart`
- Create: `test/scheduling/task_capacity_analyzer_test.dart`
- Modify: `lib/scheduling/availability_builder.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `test/scheduling/availability_builder_test.dart`
- Modify: `test/scheduling/unscheduled_reason_test.dart`

**Interfaces:**

- Produces: `AvailabilityAnalysis`、`TaskCapacityEvidence`、可验证的主原因。
- Does not change yet: 候选排序权重、均分算法、任务属性。

- [ ] **Step 1: 写区间并集和 blocker 标签红灯**

至少覆盖：

- 固定日程与保护时间重叠 30 分钟，总容量只扣一次；
- 同一区间的 `kinds` 同时包含 fixed 和 protected；
- 跨午夜睡眠按本地日展开；
- 窗口起点/终点半开；
- 粒度尾部裁剪与现有 `build()` 完全一致；
- `calendarGapMinutes == sum(slots)`。

- [ ] **Step 2: 写任务容量分层红灯**

构造 09:00–17:00 原始空闲，并逐层加入：

1. `availableFrom = 10:00`；
2. `due = 15:00`；
3. 只允许当前星期；
4. 连续 120 分钟，但最长空档 90；
5. 可拆分 30–90；
6. 每日余量只剩 60；
7. 另一任务先占用 30。

逐步断言四个容量量和最大连续空档。任何量不得大于上一级。

- [ ] **Step 3: 实现 `AvailabilityAnalysis`，保持旧输出不变**

`build(input)` 改为：

```dart
List<AvailabilitySlot> build(AvailabilityInput input) => analyze(input).slots;
```

旧 `availability_builder_test.dart` 必须无需改期望值继续通过。若旧测试需要大面积重写，说明行为漂移，停止检查。

- [ ] **Step 4: 实现任务容量分析**

计算规则：

- 先裁最早开始、截止和允许星期；
- 再按 split mode、min/max 和粒度判断每段可利用分钟；
- 连续任务的 `taskPlaceableMinutes` 只在至少有一个完整连续区间时大于 0；
- 可拆分任务使用 `shortRemainderAllowance()`，不能复制短余量公式；
- 已选块、休息和每日上限只影响 `remainingPlaceableMinutes`；
- 候选区间先合并再计分钟。

- [ ] **Step 5: 让所有容量原因携带数字**

修改原因生成：

```dart
UnscheduledReason(
  code: UnscheduledReasonCode.insufficientCapacity,
  requiredMinutes: shortage,
  availableMinutes: evidence.remainingPlaceableMinutes,
)
```

对连续空档、截止窗口和每日上限使用对应证据。测试遍历所有需要数字的原因，断言 `requiredMinutes` 与 `availableMinutes` 非空且 `available < required`。

- [ ] **Step 6: 消除无证据默认回退**

`primaryUnscheduledReason([])` 不再返回 `insufficientCapacity`。可选实现之一：

- 返回 `unexplainedSchedulingFailure`；或
- 把选择函数改成 nullable，由引擎根据 `TaskCapacityEvidence` 补出具体原因。

无论选择哪一种，最终都必须满足：空 evidence 不能显示“可用时间不足”。

- [ ] **Step 7: 写高精力软偏好回归**

测试设置：

- 高精力窗口全部被固定日程占用；
- 低精力窗口有 120 分钟合法空档；
- 高精力任务需要 60 分钟。

断言 proposal 安排 60 分钟，`unscheduled` 为空。再提供高、低两种空档，断言匹配时段优先但两者都有候选。

- [ ] **Step 8: 暂不提升算法版本并运行纯测试**

```powershell
flutter test --no-pub --concurrency=1 test/scheduling/availability_builder_test.dart test/scheduling/task_capacity_analyzer_test.dart test/scheduling/unscheduled_reason_test.dart
```

Task 4 只增加分析和正确归因时可以先不改版本；Task 5 一旦改变块集合，统一升到 15。

- [ ] **Step 9: 提交**

```powershell
git add -- lib/scheduling/availability_builder.dart lib/scheduling/task_capacity_analyzer.dart lib/scheduling/schedule_proposal.dart lib/scheduling/schedule_engine.dart test/scheduling/availability_builder_test.dart test/scheduling/task_capacity_analyzer_test.dart test/scheduling/unscheduled_reason_test.dart
git diff --cached --check
git commit -m "feat: explain scheduling capacity with measured evidence"
```

---

### Task 5: 只修阶段证据证明的零安排根因

**Files:**

- Modify: 由 Task 1 阶段证据唯一指向的生产文件
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `test/application/visible_free_time_shortage_regression_test.dart`
- Modify: 对应阶段的最小单元测试

**Interfaces:**

- Produces: 有合法候选与容量时，普通任务和本周周期目标至少按既有目标策略排入；无法解释时阻断。
- Does not permit: 顺手调整评分、改变均分定义、扩大窗口或放宽硬约束。

- [ ] **Step 1: 根据阶段证据选择唯一修复点**

使用下表，不得跳步：

| 最后一个非零阶段 | 第一个为零阶段 | 允许检查的位置 |
| --- | --- | --- |
| slots | candidates | `CandidateGenerator` 的日期、开始、截止、片段规则 |
| candidates | ranked | 每日预算、每日上限、休息、重叠、leftover、`score.isEligible` |
| ranked | selected blocks | 候选排序或放置循环 |
| selected blocks | post-improve blocks | `_improve()` / local repair |
| post-improve blocks | minimized blocks | `minimizeChangedBlocks()` |
| blocks 非零 | proposal scheduled 为零 | 汇总、task id 或 target 映射 |

只修改第一处把正确数据变错的阶段。

- [ ] **Step 2: 为根因增加最小单元红灯**

端到端测试负责证明用户场景；另写一个只含必要输入的单元测试，测试名写明根因，例如：

```text
候选存在时按日预算不得把所有日期剪成零
同名不同周期的 task id 不得共享 scheduledByTask
最小化改动不得删除新安排块
```

不要提交只断言内部函数调用次数的脆弱测试。

- [ ] **Step 3: 实现最小修复**

修改后先跑单元红灯，再跑端到端红灯。不得同时调权重和控制流；否则无法知道是哪项修复生效。

- [ ] **Step 4: 加入无法解释失败防线**

在提案返回前，对每个 shortage 执行：

```text
若 capacity evidence 能解释 → 输出对应 UnscheduledReason
若不能解释 → 输出 schedulingInvariantViolation blocker
```

断言 blocker 存在时：

- `metrics.isFullyFeasible == false`；
- 不允许自动应用；
- 预览不显示“可用时间不足”；
- 原计划不写入。

- [ ] **Step 5: 提升算法版本到 15**

在 `schedule_engine.dart` 注释中写清三类结果变化：

1. 规划窗口外任务不再进入本次目标；
2. 未来周期实例不再作为普通任务泄漏；
3. Task 5 的实际零安排根因修复。

若第 3 项最终未复现、未修改，注释必须如实只写前两项，不能伪造完成内容。

- [ ] **Step 6: 验证核心结果**

```powershell
flutter test --no-pub --concurrency=1 test/application/visible_free_time_shortage_regression_test.dart
```

Expected:

- 下周周期实例不在提案；
- 普通任务与本周周期实例在有合法容量时排入非零分钟；
- 真实缺口带可用分钟证据；
- 无法解释路径被 blocker 拦截；
- proposal 通过最终校验。

- [ ] **Step 7: 提交**

```powershell
git add -- lib/scheduling/schedule_engine.dart test/application/visible_free_time_shortage_regression_test.dart
git add -- <本任务实际修改的唯一根因文件与对应测试>
git diff --cached --check
git commit -m "fix: schedule tasks when legal capacity remains"
```

---

### Task 6: 让预览准确解释容量，不允许误导和绕过

**Files:**

- Modify: `lib/scheduling/explanations.dart`
- Modify: `lib/features/planning/plan_preview_issues.dart`
- Modify: `lib/scheduling/preview_failure_lines.dart`
- Create: `test/app/visible_free_time_preview_test.dart`
- Modify: `test/features/planning/plan_preview_issue_policy_test.dart`
- Modify: `test/scheduling/preview_failure_lines_test.dart`

**Interfaces:**

- Consumes: 标题表、结构化 reason、容量证据、blocking conflict。
- Produces: 一条任务只显示一个主问题；不查库、不猜原因。

- [ ] **Step 1: 写四类预览红灯**

1. 真容量不足：显示“需要 X 分钟，本次仍可安排 Y 分钟，还缺 Z 分钟”；
2. 连续空档不足：显示“需要连续 X 分钟，最长只有 Y 分钟”；
3. 每日上限：显示“当天/本次剩余上限 Y 分钟”；
4. 无法解释：显示固定异常文案，按钮禁用，不出现“可用时间不足”。

- [ ] **Step 2: 写未来任务和重复周期不可见测试**

预览输入中不应存在 future-outside-window 项。测试仍需故意注入两个同名不同 id 的问题，证明去重不能仅按标题；正确行为是上游排除未来 id，而不是 UI 按同名合并。

- [ ] **Step 3: 保持标题解析与隐私边界**

断言：

- 有标题时显示标题；
- 无标题时显示 `未命名任务`；
- 不显示 UUID；
- 不显示 task id、cycle id、模板 id、枚举名；
- 不把完整诊断明细默认写入界面。

- [ ] **Step 4: 无法解释必须阻断**

`buildPreviewIssues()` 对 `schedulingInvariantViolation` 只产生一条 `blocking`。提案处置为 `blocked`：

- 主按钮禁用或替换为“重新生成计划”；
- 不显示“应用可安排部分”；
- `trust auto adjust` 不得自动应用；
- 键盘和语义动作不能绕过。

- [ ] **Step 5: 两条展示链共用同一翻译**

普通生成预览和延后失败继续复用 `unscheduledReasonLabel()` / `planningConflictMessage()`。禁止在 Widget 或 router 里另写 switch。

- [ ] **Step 6: 运行展示专项测试**

```powershell
flutter test --no-pub --concurrency=1 test/features/planning/plan_preview_issue_policy_test.dart test/scheduling/preview_failure_lines_test.dart test/app/visible_free_time_preview_test.dart
```

- [ ] **Step 7: 提交**

```powershell
git add -- lib/scheduling/explanations.dart lib/features/planning/plan_preview_issues.dart lib/scheduling/preview_failure_lines.dart test/features/planning/plan_preview_issue_policy_test.dart test/scheduling/preview_failure_lines_test.dart test/app/visible_free_time_preview_test.dart
git diff --cached --check
git commit -m "fix: show measured reasons for scheduling shortages"
```

---

### Task 7: 自动化回归与反向用例

**Files:**

- Modify: `docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md`
- Modify: `docs/testing/manual-windows-checklist.md`
- Modify only when assertion is stale for a documented reason: related tests

- [ ] **Step 1: 跑格式与静态检查**

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
```

Expected: 零 error、零 warning；若仓库已有与本任务无关的失败，记录基线和新增差异，不能删测试或加 blanket ignore。

- [ ] **Step 2: 跑专项矩阵**

```powershell
flutter test --no-pub --concurrency=1 test/application/schedule_window_admission_test.dart test/application/visible_free_time_shortage_regression_test.dart test/application/recurring_enters_schedule_test.dart test/application/recurring_even_distribution_test.dart test/scheduling/availability_builder_test.dart test/scheduling/task_capacity_analyzer_test.dart test/scheduling/unscheduled_reason_test.dart test/features/planning/plan_preview_issue_policy_test.dart test/scheduling/preview_failure_lines_test.dart test/app/visible_free_time_preview_test.dart
```

- [ ] **Step 3: 跑既有反向回归**

必须覆盖：

```powershell
flutter test --no-pub --concurrency=1 test/scheduling/short_remainder_test.dart test/application/short_remainder_matrix_test.dart test/scheduling/movable_daily_limit_test.dart test/scheduling/infeasible_schedule_test.dart test/scheduling/plan_validator_test.dart test/application/rolling_window_confirmed_blocks_test.dart test/app/plan_preview_regression_test.dart test/application/plan_generation_safety_test.dart test/application/plan_application_service_test.dart
```

这些测试证明没有通过以下错误捷径“修复”：

- 恢复全天候选截断；
- 丢弃真实缺口；
- 自动应用部分或阻断提案；
- 把历史块重新塞进未来提案；
- 放宽保护时间、锁定块或校验规则。

- [ ] **Step 4: 跑全量测试**

```powershell
flutter test --no-pub --concurrency=1
```

若全量测试受 Windows Flutter 调试日志或运行器故障影响，必须：

1. 保存退出码与首个错误；
2. 单独重跑失败文件一次；
3. 若仍是运行环境错误，登记 BLOCKED；
4. 不得写“全量通过”。

- [ ] **Step 5: 核对算法版本断言**

```powershell
git grep -n "algorithmVersion.*14\|algorithmVersion, '14'\|algorithmVersion: '14'" -- test lib
```

只更新真正断言当前引擎版本的测试。手工构造旧提案的兼容测试可以继续使用 14，不能全局替换。

- [ ] **Step 6: 检查改动范围与隐私**

```powershell
git diff --check
git status --short
git diff --name-only
Get-ChildItem -Path . -Recurse -File -Force |
  Where-Object {
    $_.FullName -notmatch '\\.git\\' -and
    $_.Extension.ToLower() -in @('.db', '.sqlite', '.sqlite3', '.pfx', '.p12', '.key', '.pem')
  } |
  Select-Object FullName, Length
```

Expected: 没有用户数据库、私钥或新二进制进入 Git。`build/` 中的本地产物不应被跟踪。

- [ ] **Step 7: 更新验收证据**

验收文档逐项记录：命令、退出码、测试数、HEAD、算法版本、失败项。没有运行的项目写 `NOT RUN`，受环境阻断写 `BLOCKED`，禁止留空或写“应该通过”。

- [ ] **Step 8: 提交测试和文档**

```powershell
git add -- docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md docs/testing/manual-windows-checklist.md
git add -- <本任务实际更新的测试文件>
git diff --cached --check
git commit -m "test: verify visible-time shortage repair"
```

---

### Task 8: Windows 人工验收与交接

**Files:**

- Modify: `docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md`
- No release upload, no tag, no version bump in this task.

- [ ] **Step 1: 从用户数据库制作验收副本**

关闭应用后复制数据库到专用验收目录。记录原文件与副本 SHA-256；后续只启动副本。验收结束后不得把副本加入仓库或安装包。

- [ ] **Step 2: 使用新代码重新构建 Windows 应用**

必须重新构建，不能拿旧 EXE 验证新代码。记录构建命令、退出码、EXE 修改时间和 Git HEAD。

- [ ] **Step 3: 核验原故障形状**

在副本中生成计划，逐项确认：

- 日历未来空档与排程输入使用同一规划窗口；
- 下周周期实例不出现在本周预览；
- 同名周期目标不再重复；
- 普通任务与本周周期目标使用合法空档；
- 若真实容量仍不足，文案带需要、可用和缺口分钟；
- 高精力任务可退到其它合法时段；
- 预览无 UUID 和内部枚举名；
- 应用后最终计划通过校验。

- [ ] **Step 4: 核验边界操作**

人工创建以下临时数据，验收后在副本中删除：

1. 明天才可开始但仍在窗口内的任务；
2. 恰好在窗口终点才可开始的任务；
3. 已过截止时间的任务；
4. 需要 120 分钟连续时段但只有两段 60 分钟空档的任务；
5. 30 分钟最小片段、只剩 15 分钟的任务；
6. 高精力任务但只剩低精力时段；
7. 每日上限已满但次日仍有容量的任务。

每项记录“期望／实际／PASS 或 FAIL”。

- [ ] **Step 5: 验证零写入和失败原子性**

故意制造一个 `schedulingInvariantViolation` 测试构建或通过测试专用注入：

- 页面显示无法解释的排程异常；
- 应用按钮不可用；
- 当前确认计划、任务、周期进度与历史版本数量均不变。

- [ ] **Step 6: 完成状态判定**

只有同时满足以下条件才可写 `PASS`：

- Task 1 的完整真实故障形状已复现并转绿；
- 专项、反向和全量自动化通过；
- Windows 新构建人工验收通过；
- 用户数据库副本未被提交；
- 没有未解释的新增回归；
- 验收文档有命令、退出码、HEAD 和证据。

若只修复未来周期重复，但本周任务零安排未复现或未解决，最终状态必须写：

```text
PARTIAL — future recurring-cycle leakage fixed; zero-scheduling root cause not proven.
```

不得写“修复完成”。

- [ ] **Step 7: 交接，不自动发布**

输出：

- 提交列表；
- 修改文件列表；
- 算法版本；
- 自动化结果；
- 人工验收结果；
- 已知剩余问题；
- 是否具备发布候选资格。

等待用户明确授权后，才能进入版本分配、安装包构建、签名、Git tag 和 GitHub Release 流程。

---

## 5. 自动化验收矩阵

| 编号 | 场景 | 必须断言 |
| --- | --- | --- |
| A01 | 普通任务无开始/截止 | 进入当前窗口 |
| A02 | `availableFrom == window.end` | 不进入提案、不报缺口 |
| A03 | `due == window.start` | 截止已过原因，不静默丢失 |
| A04 | 本周与下周周期均已生成 | 只有本周进入当前提案 |
| A05 | 两周期同名 | 当前预览只有当前实例问题 |
| A06 | 高精力窗口被占、低精力有空 | 仍安排，不报容量不足 |
| A07 | 高低精力都有空 | 高精力候选优先，两者都合法 |
| A08 | 全天真实空闲在下午/晚上 | slots 与候选包含下午/晚上 |
| A09 | 每日上限已满 | 显示上限原因和剩余上限 |
| A10 | 连续任务总空闲足够但被切碎 | 显示最长连续空档 |
| A11 | 可拆分短余量 15、min 30 | 安排 15 或按粒度安排并报真实尾差 |
| A12 | 固定/保护区间重叠 | 总容量只扣一次，保留两个 blocker kind |
| A13 | 合法候选存在但结果为 0 | 阻断为 invariant violation，不显示容量不足 |
| A14 | 真容量不足 | `availableMinutes < requiredMinutes` 且文案含数字 |
| A15 | 未来普通任务与当前任务并存 | 未来任务不影响当前任务目标和排序 |
| A16 | 旧确认块含历史/进行中/未来 | 历史不污染容量，进行中与未来按既有规则处理 |
| A17 | 部分计划 | 需人工确认，自动应用不执行 |
| A18 | blocker | 零写入，按钮不可绕过 |
| A19 | 输入顺序打乱 | 输出和原因保持确定 |
| A20 | Asia/Shanghai 本地周界 | 周一至周日实例边界正确 |

---

## 6. 完成定义

以下全部满足才算专项实施完成：

- [ ] 未来周期实例不再作为普通任务进入当前规划。
- [ ] 窗口外普通任务不再制造本次缺口。
- [ ] 普通任务和当前周期目标在存在合法容量时能实际排入。
- [ ] 高精力只影响排序，不影响候选资格。
- [ ] `insufficientCapacity` 每次都带真实的 `requiredMinutes` 和 `availableMinutes`。
- [ ] 空 evidence 不再回落“可用时间不足”。
- [ ] 无法解释的零安排被结构化 blocker 拦截。
- [ ] 日历空闲、任务窗口、可放置容量和剩余容量满足 §2.5 不变量。
- [ ] 短余量、全天候选、历史块、部分计划与自动应用既有修复无回归。
- [ ] 专项、反向、全量测试均有实际 PASS 记录。
- [ ] Windows 新构建在数据库副本上通过人工验收。
- [ ] 算法版本已按真实行为变化升到 15；软件版本未被擅自改动。
- [ ] 没有提交用户数据库、真实 UUID、秘密文件或构建目录。
- [ ] 验收文档没有空项、模糊“应该通过”或把 BLOCKED 写成 PASS。

---

## 7. 禁止的捷径

- 不通过扩大到 14 天或更长窗口掩盖任务输入错误。
- 不通过提高/关闭每日上限让测试变绿。
- 不通过关闭睡眠、保护时间或固定日程制造容量。
- 不把高精力改成“仅高精力时段可排”。
- 不删除下周周期实例；只从当前排程输入隔离。
- 不在预览层根据任务属性猜原因。
- 不把所有缺口统一翻译成“可用时间不足”。
- 不把 candidate duration 相加当容量；候选大量重叠。
- 不用标题去重周期实例；标题不是身份。
- 不吞掉 `unscheduled` 让页面看起来没有问题。
- 不允许 blocker 走“应用可安排部分”。
- 不用旧 EXE 验证新代码。
- 不因运行器失败而写测试通过。
- 不在本计划中顺手发布新版本或上传 GitHub Release。

---

## 8. 执行交接模板

执行代理结束时必须按以下格式交付：

```markdown
## Visible Free Time False Shortage Repair — Handoff

- Worktree:
- Branch:
- Start HEAD:
- End HEAD:
- Algorithm version:
- Software version changed: no / yes (若 yes，说明授权来源)

### Root cause evidence
- Future recurring-cycle leak:
- Zero-scheduling first failing stage:
- Exact production fix:

### Verification
- Static analysis:
- Focused tests:
- Reverse regressions:
- Full suite:
- Windows rebuild:
- Manual database-copy acceptance:

### Safety
- Original user database modified: no
- Database/schema migration: no
- Secrets or personal data committed: no
- Automatic/partial apply boundary preserved: yes/no

### Status
- PASS / PARTIAL / BLOCKED / FAIL
- Remaining issues:
```

任何空白项都视为未完成。
