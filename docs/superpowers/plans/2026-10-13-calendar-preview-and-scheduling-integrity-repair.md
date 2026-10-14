# Calendar, Plan Preview, and Scheduling Integrity Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. **Do not use parallel agents for this plan.** Tasks 3–7 share the candidate, validation, failure-reason, preview, and refresh contracts; concurrent edits would make the intermediate states uncompilable. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复日历与计划预览中已经确认的显示、刷新和排程完整性问题，使同一事项在日视图与近期日历中保持一致，长任务的最后短片段能按统一规则安排，未安排原因与真实缺口一致，用户不会在排程异常时被引导去应用不完整计划。

**Architecture:** 排程侧以“当前剩余分钟”为候选生成与最终校验的共同输入，删除跨轮次累积的陈旧拒绝证据，并在最终块集合上重新生成结构化诊断。展示侧以一个可失效的数据源统一加载日历、任务和计划，所有成功写入只发失效信号，不直接拼接页面状态。预览只消费引擎输出的结构化事实，并把修复入口、部分应用和阻断状态分开呈现。

**Tech Stack:** Flutter / Dart、Drift / SQLite、现有确定性排程引擎、Riverpod、IANA 时区、Flutter widget tests、Windows x64。

**Spec:** `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md` §4、§5、§11、§13；`docs/superpowers/plans/2026-10-12-plan-preview-validation-repair.md`；`docs/superpowers/plans/2026-10-13-visible-free-time-false-shortage-repair.md`。本计划对“长任务经过若干片段后形成短余量”“最终失败证据”“日历实时一致性”和“预览交互层级”的规定优先于前两份计划中的旧表述。

## Global Constraints

- **文档状态：本文件只是一份实施计划；本文列出的代码修复尚未因文档创建而完成。**
- 只新增本文件，不以编写计划为由修改生产代码、测试、数据库或版本号。
- 实施时严格按 Task 1 → Task 10 串行推进；未通过当前任务的红灯/绿灯门禁，不进入下一任务。
- 当前工作树是 `G:\best-planing\.worktrees\native-implementation`，分支是 `feature/native-implementation`，存在其它未跟踪文档。执行前记录状态；禁止 `git reset --hard`、`git clean`、`git checkout --` 和无筛选的 `git add -A`。
- 本计划不重复实施课程资料编辑、自定义保护时间管理、早餐规则创建、通知去重、托盘左键、统计页重构、更新检查和安装器；这些内容属于已有独立计划。
- 不修改数据库 schema、备份格式、应用 identity、publisher、AUMID、数据目录或 GitHub Release 通道。
- 不新增第三方依赖。若实现刷新流需要合并信号，使用 Dart SDK 的 `StreamController` / `StreamSubscription` 和现有端口完成。
- 不上传、打印或写入真实用户的 SQLite、任务标题、课程表、路径用户名、UUID、截图和通知内容。回归夹具使用匿名标题与固定 UUID-like 测试值。
- 所有时间区间继续使用 UTC 半开区间 `[startUtc, endUtc)`；星期、日期和钟点只通过 `TimeZoneDatabase` 转换。
- `TaskEnergyLevel` 与 `preferredWindow` 继续是评分偏好，不得变成过滤候选的硬约束。
- 固定日程、保护时间、睡眠、锁定块、最早开始、截止、允许星期、连续时长、粒度、休息和每日上限仍是硬约束；不得为了消除告警而绕过。
- “日历上看起来空”不等于任务一定可排。预览必须说明空档被哪条硬约束排除，但不能把视觉空白直接当成可用容量。
- 短余量规则只有一份：`shortRemainderAllowance(requiredMinutes, granularityMinutes)`。候选生成、引擎选择和最终校验都必须调用同一规则。
- 任一会改变同一输入排程结果的生产修改，必须把 `DeterministicScheduleEngine.algorithmVersion` 从 `15` 提升到 `16`，并同步 golden fixture；这不是软件版本号。
- 不在本计划中修改 `pubspec.yaml` 的 `1.8.0+44`、MSIX 版本或发布台账。候选发布必须在全部自动化和人工验收通过后另行安排。
- 每个生产修改都先写能因目标缺陷失败的测试。编译错误、测试夹具错误、找不到文件、时区构造错误和测试运行器崩溃都不算有效红灯。
- 若 Flutter/Dart 进程出现 `0xc0000142`、`-1073741502`、无输出退出或重复系统弹窗，只记录一次并停止重试；不得把“未运行”写成 PASS。
- 不允许通过修改测试期望、删除断言、放宽 validator、隐藏 warning 或把按钮禁用来伪装问题已经解决。

## Review Focus

- 180 分钟、最小片段 30 分钟的任务在安排 150 分钟后，剩余 30 分钟必须重新参与候选生成；不得继续使用初始 180 分钟候选集的旧形状。
- 100 分钟、最小片段 30 分钟、粒度 5 分钟的任务必须能得到 `30 + 30 + 30 + 10`；最终 10 分钟是唯一合法短尾，不得被 validator 拒绝。
- 103 分钟任务必须能安排 `30 + 30 + 30 + 10` 并准确报告不可表示的 3 分钟；不得伪造 3 分钟块。
- 只有 20 分钟零散容量、任务当前仍需 40 分钟且最小片段 30 分钟时，不得把 20 分钟做成非法短片段。
- 一轮候选曾因每日上限或最小片段被拒绝、随后成功放入块时，这些旧拒绝不得成为最终主原因。
- `_improve()` 改变最终块集合后，未安排原因必须根据最终块重新计算，不能沿用改进前的证据。
- 同一未安排任务的标题缺口、原因数字和“仍可安排”数字必须能算术对齐；界面不得同时出现“还缺 20”与正文“还缺 10”。
- 引擎仍有合法候选却没有使用时，提案必须是 blocking；不得出现“应用可安排部分”。
- 应用计划、撤销计划、编辑/删除日程、编辑课程、修改保护规则和完成任务后，日视图、近期日历和今日页必须在同一进程内自动刷新。
- 连续快速写入时，较早的异步加载结果不得覆盖较新的结果。
- 早餐规则在所有日历视图中必须显示“早餐”，不得回落为“保护时间”或英文枚举名。
- 固定日程时间已经过去，不等于任务已完成；完成图标和语义只属于 `TaskStatus.completed`。
- 近期日历实际显示“昨天 + 今天起七天”共八列；标题和空状态不得再声称只有七列。
- 日视图所有卡片右边界一致；不可用操作不以三枚灰色图标占位，键盘与屏幕阅读器仍能访问可用操作。
- 100%、125%、150%、200% 文字缩放及 1024/1280/1920 宽度下，不出现横向溢出、按钮遮挡或文本截断后不可获知完整内容。

---

## 1. 已确认问题与证据边界

### 1.1 已确认的代码缺陷

| 编号 | 现象 | 当前代码事实 | 严重级别 |
| --- | --- | --- | --- |
| R1 | 早餐显示成“保护时间” | `schedule_view_source.dart::_protectedLabel()` 只覆盖 lunch、dinner、fixedRest，遗漏 breakfast | P2 |
| R2 | 日视图卡片右边界不齐 | `_DayItemTile` 外部的操作按钮数量随条目类型变化；规则保护时间比课程多一个 settings 按钮 | P2 |
| R3 | 长任务最后一小段排不进去 | `schedule_engine.dart` 在进入 `while (remaining > 0)` 前只调用一次 `chunkGenerator.generate(task, slots)`；`CandidateGenerator` 却用 `task.requiredMinutes` 判定短余量 | P0 |
| R4 | 最终校验仍按整项任务判断短余量 | `isValidPlannedChunk()` 不知道同任务其它块，无法证明某个低于 min 的块是不是全任务唯一最终短尾 | P0 |
| R5 | 最终原因可能来自旧轮次 | `rejectionEvidence[taskId]` 按 reason code 跨放置轮次累计；成功选择块不会清空旧证据 | P0 |
| R6 | 原因可能与最终块不一致 | `_improve()` 在收集拒绝证据后修改块，随后直接用旧证据生成 `unscheduled` | P0 |
| R7 | 缺口数字互相矛盾 | `_withNumbers()` 用 `required - available` 再造一份“还缺”，而标题使用 `UnscheduledTask.shortageMinutes` | P1 |
| R8 | 排程异常可被误认为普通部分计划 | `classifyProposal()` 只看 conflicts/unscheduled；若异常未正确升为 conflict，就会给出部分应用入口 | P0 |
| R9 | 日历数据不会实时更新 | `RepositoryScheduleViewSource.watch()` 只执行一次 `yield await _load(...)` | P1 |
| R10 | 测试替身掩盖生产问题 | 页面测试的 `StreamController` 能推第二次事件，但生产源永远不推第二次 | P1 |
| R11 | 固定日程被标成“已完成” | 数据源把已过结束时间的非保护日程写成 `isCompleted=true`，页面显示任务完成勾 | P2 |
| R12 | “七日日历”实际有八列 | `for (index = -1; index < 7; index++)` 显示昨天和今天起七天 | P2 |

### 1.2 已确认的体验缺口

| 编号 | 缺口 | 目标状态 |
| --- | --- | --- |
| U1 | 普通任务缺口只有文字，没有“编辑任务/调整规则”入口 | 问题卡片提供与原因匹配的恢复动作 |
| U2 | “应用可安排部分”使用全宽主按钮 | 部分应用降为次要危险动作，并再次确认准确后果 |
| U3 | 失败预览仍显示“信任自动调整” | 开关只留在设置页；预览专注处理当前结果 |
| U4 | 用户看不出每段可见空档为何不能用 | 提供可展开的“未使用空档”证据，显示时间段与排除原因 |
| U5 | 规则保护时间显示三枚灰色不可用操作 | 每行只呈现可执行操作；操作槽宽度固定 |

### 1.3 本计划不把下列风险写成已确认缺陷

- 键盘焦点顺序、Narrator 宣读、200% 缩放和高对比主题尚未在真实 Windows 构建上验证；它们是必须执行的验收项，不是已证实的失败。
- 日历跨午夜、夏令时切换和周界目前没有截图证据表明失败；本计划补回归，未出现红灯前不重写时区逻辑。
- “高精力导致其它时段全部不可用”没有代码证据；现有设计把精力作为软评分。本计划只加反向测试，不改为硬限制。
- 课程资料编辑、自定义保护时间改名和早餐规则创建已有独立计划。本计划只修复这些数据进入日历后的标签、刷新和布局。

## 2. 冻结决策与数据契约

### 2.1 当前剩余量是候选生成的显式参数

修改候选接口为：

```dart
List<SchedulingCandidate> generate(
  SchedulableTask task,
  List<AvailabilitySlot> slots, {
  required int remainingMinutes,
});
```

约束：

- `remainingMinutes` 必须满足 `0 <= remainingMinutes <= task.requiredMinutes`；非法值抛 `ArgumentError`。
- 连续任务只有当 `remainingMinutes == task.requiredMinutes` 时生成一次完整候选；连续任务放置成功后不再迭代。
- 可拆分任务的 candidate duration 上限使用 `remainingMinutes`，不再读 `task.requiredMinutes`。
- `remainingMinutes < minChunkMinutes` 时，唯一候选时长是 `shortRemainderAllowance(remainingMinutes, granularity)`；结果为 0 时不生成。
- 引擎每次成功放置后，以新 `remainingMinutes` 重新生成下一轮候选。不得在循环外缓存一份基于初始总量的候选列表。
- 均匀分布的按日预算过滤在每轮候选生成后执行；过滤只读同一份 `EvenDistributionPlan`，不得重算本周目标。

### 2.2 最终校验按同任务块集合判断短尾

新增纯函数：

```dart
enum ChunkSetViolation {
  none,
  nonPositiveDuration,
  offGranularity,
  aboveMaximum,
  belowMinimumBeforeTail,
  multipleShortTails,
  shortTailMismatch,
  totalExceedsRequired,
  continuousTaskSplit,
}

final class ChunkSetValidation {
  const ChunkSetValidation({
    required this.violation,
    this.blockId,
  });

  final ChunkSetViolation violation;
  final String? blockId;
  bool get isValid => violation == ChunkSetViolation.none;
}

ChunkSetValidation validatePlannedChunkSet({
  required SchedulableTask task,
  required Iterable<PlannedBlock> blocks,
  required int granularityMinutes,
});
```

可拆分任务的判定顺序固定为：

1. 所有块时长为正、落在粒度网格且不超过 `maxChunkMinutes`；
2. 总时长不超过 `task.requiredMinutes`；
3. `duration >= minChunkMinutes` 的块记为常规块；
4. 低于 `minChunkMinutes` 的块最多一个；
5. 若存在短块，令 `regularTotal` 为全部常规块之和，计算 `tailBudget = shortRemainderAllowance(task.requiredMinutes - regularTotal, granularityMinutes)`；
6. 短块时长必须严格等于 `tailBudget`；小于预算的半截短块和第二个短块都非法；
7. 任务总量存在不足一个粒度的余数时允许保留真实缺口，不伪造块。

示例：

| required / min / granularity | 块集合 | 结果 |
| --- | --- | --- |
| 100 / 30 / 5 | 30, 30, 30, 10 | 合法 |
| 103 / 30 / 5 | 30, 30, 30, 10 | 合法，缺口 3 |
| 100 / 30 / 5 | 30, 30, 20 | 非法；20 不是最终 40 分钟剩余的唯一宽免 |
| 12 / 30 / 5 | 10 | 合法，缺口 2 |
| 12 / 30 / 5 | 5 | 非法；合法短尾预算是 10 |
| 100 / 30 / 5 | 30, 30, 5, 5 | 非法；存在两个短尾 |

`PlanValidator.validate()` 必须按 task id 分组后调用该函数。旧的 `isValidPlannedChunk()` 只能保留为单候选的快速前置检查，不能再作为最终集合合法性的唯一依据。

### 2.3 最终诊断只看最终计划

新增 `lib/scheduling/task_placement_diagnostics.dart`：

```dart
enum GapExclusionCode {
  beforeAvailableFrom,
  afterDeadline,
  disallowedWeekday,
  shorterThanRequiredChunk,
  dailyTaskLimitReached,
  dailyMovableLimitReached,
  requiredBreakUnavailable,
  occupiedByFixedSchedule,
  occupiedByProtectedTime,
  occupiedByLockedBlock,
}

final class ExcludedGapEvidence {
  const ExcludedGapEvidence({
    required this.range,
    required this.code,
    this.requiredMinutes,
    this.availableMinutes,
  });

  final TimeRange range;
  final GapExclusionCode code;
  final int? requiredMinutes;
  final int? availableMinutes;
}

final class TaskPlacementDiagnostics {
  const TaskPlacementDiagnostics({
    required this.remainingMinutes,
    required this.capacity,
    required this.reasons,
    required this.excludedGaps,
    required this.hasEligibleCandidate,
  });

  final int remainingMinutes;
  final TaskCapacityEvidence capacity;
  final List<UnscheduledReason> reasons;
  final List<ExcludedGapEvidence> excludedGaps;
  final bool hasEligibleCandidate;
}
```

新增纯入口：

```dart
TaskPlacementDiagnostics diagnoseTaskPlacement({
  required ScheduleProblem problem,
  required SchedulableTask task,
  required int remainingMinutes,
  required AvailabilityAnalysis availability,
  required List<PlannedBlock> finalBlocks,
  required TimeZoneDatabase zones,
});
```

规则：

- 此函数在 `_improve()`、稳定块最小化和最终排序之后调用。
- 它不得读取放置循环中累计的 `rejectionEvidence`。
- 候选资格判定必须与引擎放置共用同一个纯函数；禁止在诊断器复制另一套“看起来差不多”的约束。
- `hasEligibleCandidate == true && remainingMinutes > 0` 时，主原因固定为 `unexplainedSchedulingFailure`，并生成 blocking conflict。
- `excludedGaps` 先按起点排序，再合并相邻且 code 相同的区间；相同输入输出顺序稳定。
- 诊断数据只进入内存提案，不写普通日志和遥测。

### 2.4 原因字段不再承担两种含义

把 `UnscheduledReason.requiredMinutes` 重命名为两个语义明确的字段：

```dart
final class UnscheduledReason {
  const UnscheduledReason({
    required this.code,
    required this.placementRemainingMinutes,
    this.constraintRequiredMinutes,
    this.constraintAvailableMinutes,
    this.constraintLabel,
  });

  final UnscheduledReasonCode code;
  final int placementRemainingMinutes;
  final int? constraintRequiredMinutes;
  final int? constraintAvailableMinutes;
  final String? constraintLabel;
}
```

字段不变量：

- `placementRemainingMinutes == UnscheduledTask.shortageMinutes`；
- `constraintRequiredMinutes` 是某条约束要求的连续/最小/每日分钟，不是总缺口；
- `constraintAvailableMinutes` 是同一约束口径下的可用分钟；
- UI 不得再计算 `constraintRequiredMinutes - constraintAvailableMinutes` 并称为“还缺”；
- “还缺多少”只显示 `UnscheduledTask.shortageMinutes`；
- 原因正文只描述约束，例如“最短片段要求 30 分钟，当前最长合法空档 20 分钟”。

### 2.5 保护时间标签使用类型，不解析 id

扩展 `BusyInterval`：

```dart
final class BusyInterval {
  const BusyInterval({
    required this.id,
    required this.range,
    this.protectedKind,
  });

  final String id;
  final TimeRange range;
  final ProtectedTimeKind? protectedKind;
}
```

`ProtectedTimeExpander.expand()` 创建的区间必须写入 `protectedKind: rule.kind`；固定日程、睡眠和锁定块保持 `null`。新增日历与预览层共用的文案函数：

```dart
String protectedTimeKindLabel(ProtectedTimeKind kind);
```

固定放在新文件 `lib/design/protected_time_labels.dart`。日历与预览调用它，并删除按 `interval.id.split(':')` 推断 kind 的代码。`AnalyticsDao` 属于数据层，不得反向依赖 `lib/design/`；它继续把统计窗口投影为字符串，但默认规则与 JSON 规则的两个 switch 都必须显式覆盖 `breakfast → 早餐`，并用契约测试保证与界面文案一致。若将来统计模型改为携带 typed kind，应另写迁移计划，不能在本修复里顺手扩大模型边界。

### 2.6 日历刷新使用显式失效信号

新增：

```dart
enum ScheduleViewChangeKind {
  calendar,
  plan,
  task,
  planningRules,
  colors,
  workspace,
}

abstract interface class ScheduleViewInvalidation {
  Stream<int> get revisions;
  void notify(ScheduleViewChangeKind kind);
}

final class ScheduleViewInvalidationBus implements ScheduleViewInvalidation {
  // 单调递增 revision；broadcast；dispose 只由组合根调用。
}
```

装配规则固定如下：

- `main.dart` 创建唯一的 `ScheduleViewInvalidationBus`，同时注入 `RepositoryScheduleViewSource` 与写入服务；应用销毁时只 dispose 一次。
- `CalendarService.onScheduleInputChanged` 的生产回调在保留既有重排记录后调用 `notify(calendar)`；不为 CalendarService 再增加第二个同义回调。
- `TaskService.onScheduleInputChanged` 继续负责重排；任务展示刷新由 `tasks.watchAllTasks()` 驱动，不重复发送 bus 信号。
- `PlanApplicationService.onPlanChanged` 与 `PlanUndoService.onPlanChanged` 的生产回调先完成既有通知同步，再调用 `notify(plan)`。若通知同步发生在计划已提交之后并失败，必须仍发送 plan 信号，让页面读回真实已提交结果；不能把已经落库的计划假装成未写入。
- `CourseManagementService` 新增 `void Function()? onCalendarChanged`，仅给未经过 `CalendarService` 的成功事务发送 `calendar`；经过 CalendarService 的路径不得重复发送。
- `SettingsService` 新增 `void Function()? onPlanningRulesChanged`，只在 `saveUserRules` / `saveDateOverride` 成功后调用；通知设置、关闭行为和其它无关设置不发送。
- `ScheduleColorService` 新增 `void Function()? onColorsChanged`，只在颜色写入成功后调用。
- `WorkspaceService` 新增 `void Function()? onWorkspaceChanged`，只在会改变日历分类名称或颜色的 area 写入成功后调用；不影响卡片展示的项目变化不发。
- 上述新增回调在领域服务中允许为空以保持测试替身轻量，但 `main.dart` 的生产装配测试必须断言全部非空且指向同一个 bus。
- `ScheduleViewInvalidationBus.dispose()` 幂等；dispose 后的 `notify()` 安全忽略，避免应用关闭竞态产生未捕获异常。

`RepositoryScheduleViewSource.watch()` 的契约：

1. 订阅后立即加载一次；
2. 监听 `tasks.watchAllTasks()` 与 `invalidation.revisions`；
3. 任一信号到达后重新执行完整 `_load(startUtc, endUtc)`；
4. 同一时刻多个信号合并为至多一次在途加载加一次待处理加载；
5. 用单调 generation 丢弃晚到的旧结果，旧结果不得覆盖新结果；
6. 最后一个监听者取消后，释放内部订阅和 controller；
7. 加载失败通过 stream error 交给页面，下一次信号仍能恢复，不永久关闭流。

失效信号只在事务/写入成功后发送。失败、取消和 stale 不发信号。

### 2.7 日视图操作区固定宽度且只显示可执行动作

每行改为：

```text
[占满剩余宽度的日程卡片] [固定 48 px 的更多操作槽]
```

- 所有行都有 48 px 操作槽，卡片右边界因此一致。
- 有至少一个动作时显示单个 `more_vert` 按钮；没有动作时用等宽空槽，不显示灰色按钮。
- 菜单只列可执行动作：编辑、调整所属领域、删除、去设置。
- 规则来源保护时间只显示“去设置”；自定义保护时间显示“编辑/删除”；课程/固定日程按实际端口显示；任务块不显示无效的固定日程操作。
- 删除仍走二次确认；菜单关闭后焦点返回触发按钮。
- 不以颜色区分动作是否危险；删除项同时有文字和 delete 图标。

### 2.8 预览恢复动作与按钮层级

扩展问题模型：

```dart
enum PreviewRecoveryAction {
  editTask,
  openPlanningRules,
  openProtectedTimeManagement,
  recalculate,
}

final class PreviewIssue {
  const PreviewIssue({
    required this.key,
    required this.severity,
    required this.title,
    required this.message,
    this.taskId,
    this.excludedGaps = const [],
    this.actions = const [],
  });

  // 既有字段省略。
  final String? taskId;
  final List<ExcludedGapEvidence> excludedGaps;
  final List<PreviewRecoveryAction> actions;
}
```

页面接收：

```dart
final Future<void> Function(
  PreviewRecoveryAction action,
  PreviewIssue issue,
)? onRecover;
```

映射规则：

| 主原因 | 动作 |
| --- | --- |
| deadlineWindowTooShort / continuousGapTooShort / minimumChunkTooLarge | 编辑任务 |
| dailyLimitReached | 调整规划规则、编辑任务 |
| protectedTimeOccupied | 管理保护时间、编辑任务 |
| availableTimeNotReached | 编辑任务 |
| insufficientCapacity | 编辑任务、调整规划规则 |
| unexplainedSchedulingFailure | 重新生成；若再次出现，保持阻断并提示导出诊断 |

按钮状态固定：

| 状态 | 主操作 | 部分应用 |
| --- | --- | --- |
| 完整可行 | `FilledButton`“确认应用” | 不显示 |
| 可解释的真实缺口 | 每条问题卡显示恢复动作；底部不放误导性的全宽主按钮 | `OutlinedButton`“仍应用可安排部分”并二次确认 |
| 无法解释/结构错误 | `FilledButton`“重新生成计划” | 不显示 |
| stale | `FilledButton`“重新生成计划” | 不显示 |

“信任自动调整”从预览页移除，只保留设置页入口。它影响之后的完整可行提案，不参与当前失败的处置。

## 3. 文件职责

### 新建文件

| 文件 | 唯一职责 |
| --- | --- |
| `lib/application/schedule_view_invalidation.dart` | 应用内日历展示失效信号与单调 revision |
| `lib/scheduling/task_placement_diagnostics.dart` | 根据最终块集合生成失败原因与空档排除证据 |
| `test/application/schedule_view_invalidation_test.dart` | 失效合并、乱序丢弃、取消订阅和失败恢复 |
| `test/scheduling/dynamic_short_tail_test.dart` | 长任务经过多轮后形成短尾的矩阵回归 |
| `test/scheduling/task_placement_diagnostics_test.dart` | 最终证据、原因数字和空档排除原因 |
| `integration_test/calendar_preview_consistency_test.dart` | 应用计划与编辑日程后的三视图一致性 |
| `docs/testing/calendar-preview-scheduling-integrity-acceptance.md` | Windows 人工验收记录模板和实测证据 |

### 修改文件

| 文件 | 修改责任 |
| --- | --- |
| `lib/scheduling/schedule_problem.dart` | 为规则保护区间携带 `ProtectedTimeKind` |
| `lib/scheduling/protected_time_expander.dart` | 展开时保留 kind，不再只把信息编码进 id |
| `lib/design/protected_time_labels.dart` | 新建无 Widget 状态的日历/预览保护时间中文标签函数 |
| `lib/features/calendar/week_view/schedule_view_source.dart` | 使用 typed kind；实现可失效重载；固定日程不再冒充完成任务 |
| `lib/features/calendar/week_view/schedule_view_models.dart` | 收紧 `isCompleted` 为任务完成语义 |
| `lib/features/calendar/day_view/day_view_page.dart` | 统一右边界与更多菜单；修正完成语义 |
| `lib/features/calendar/week_view/week_view_page.dart` | 标题改为“近期日历”；维持八列行为；处理刷新流 |
| `lib/features/tutorial/tutorial_steps.dart` | 同步“近期日历”名称；发布前更新对应截图 |
| `lib/scheduling/candidate_generator.dart` | 以 `remainingMinutes` 生成每轮候选 |
| `lib/scheduling/plan_validator.dart` | 对同任务块集合验证唯一短尾 |
| `lib/scheduling/schedule_engine.dart` | 每轮重生候选；最终诊断；算法版本 16 |
| `lib/scheduling/schedule_proposal.dart` | 结构化原因字段和 gap evidence |
| `lib/scheduling/explanations.dart` | 按原因专用字段写文案，不再自行计算缺口 |
| `lib/scheduling/proposal_disposition.dart` | 保证异常提案始终 blocking |
| `lib/features/planning/plan_preview_issues.dart` | 构建恢复动作和空档证据；无 UUID |
| `lib/features/planning/plan_preview_page.dart` | 原因动作、空档展开、部分应用降级、移除自动调整开关 |
| `lib/app/router.dart` | 装配恢复路由和日历失效总线 |
| `lib/main.dart` | 创建/释放同一个 app-scoped 失效总线 |
| `lib/application/plan_application_service.dart` | 成功应用后发 plan 失效；失败不发 |
| `lib/application/plan_undo_service.dart` | 成功撤销后发 plan 失效 |
| `lib/application/calendar_service.dart` | 成功保存、编辑、删除后发 calendar 失效 |
| `lib/application/course_management_service.dart` | 成功课程事务后发 calendar 失效 |
| `lib/application/settings_service.dart` | 成功保存规划规则后发 planningRules 失效 |
| `lib/application/schedule_color_service.dart` | 成功改色后发 colors 失效 |
| `lib/application/workspace_service.dart` | 领域名称/颜色变化后发 workspace 失效 |

### 只加回归、不因本计划随意重构

- `lib/scheduling/task_capacity_analyzer.dart`
- `lib/scheduling/availability_builder.dart`
- `lib/scheduling/even_distribution_allocator.dart`
- `lib/core/time_zone.dart`
- Drift schema 与迁移文件
- 更新检查、通知、托盘、统计与安装器

## 4. 任务依赖与停止条件

```text
Task 1 失败证据
  ├─→ Task 2 标签与状态语义
  ├─→ Task 3 日视图布局
  └─→ Task 4 动态短尾与集合校验
          → Task 5 最终诊断与原因一致性
              → Task 6 预览恢复交互
                  → Task 7 实时刷新
                      → Task 8 近期日历命名与跨视图一致性
                          → Task 9 可访问性/响应式
                              → Task 10 全量与 Windows 验收
```

停止条件：

- Task 1 无法稳定复现时停止，不凭截图猜修法；先保存匿名化输入快照与实际输出。
- Task 4 若需要改变短余量产品规则，停止并更新本计划 §2.2；不得实现人员临场决定。
- Task 5 若诊断器与引擎必须复制约束，停止并先抽取共同 evaluator；不得接受两套规则。
- Task 7 若发现某写入绕过应用服务直接写仓储，先把它纳入失效契约；不得靠页面 `setState` 局部补丁。
- 任一任务导致数据库 schema 变化，停止；该变化超出本计划授权。

---

### Task 1: 固定真实故障形状与基线

**Files:**
- Modify: `test/scheduling/short_remainder_test.dart`
- Modify: `test/application/short_remainder_matrix_test.dart`
- Modify: `test/features/calendar/schedule_view_source_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Modify: `test/features/planning/unscheduled_display_test.dart`
- Modify: `test/scheduling/dynamic_short_tail_test.dart`

**Interfaces:**
- Consumes: 当前生产接口，不先改夹具以适配目标实现。
- Produces: 对 R1–R12 的可重复失败证据与基线快照。

- [ ] **Step 1: 记录工作树与当前版本**

```powershell
git status --short --branch
git diff --stat
Select-String -Path pubspec.yaml -Pattern '^version:'
Select-String -Path lib/scheduling/schedule_engine.dart -Pattern 'algorithmVersion'
```

Expected: 记录当前分支、已有改动、`1.8.0+44` 和算法版本 `15`；不清理任何文件。

- [ ] **Step 2: 写长任务动态短尾红灯**

在 `dynamic_short_tail_test.dart` 加以下用例，固定 UTC、无固定日程、粒度 5：

1. `100 / min30 / max30` 在四个合法空档中得到 `30,30,30,10`，缺口 0；
2. `103 / min30 / max30` 得到 `30,30,30,10`，缺口 3；
3. `180 / min30 / max90` 有足够容量时缺口 0；
4. `remaining=40` 但只剩 20 分钟空档时，不生成 20 分钟短块；
5. 高精力任务只有普通时段可用时仍能完整安排。

每个用例同时断言块时长列表、总时长、`proposal.unscheduled` 和 validator 结果。

- [ ] **Step 3: 写陈旧拒绝证据红灯**

构造第一轮某候选触发 `minimumChunkTooLarge` 或 `dailyLimitReached`、之后其它候选成功、最终只剩另一种真实约束的输入。断言最终主原因不包含第一轮的旧 reason。

- [ ] **Step 4: 写原因数字一致性红灯**

断言一条 issue 中：标题的缺口分钟等于 `UnscheduledTask.shortageMinutes`；正文不得出现由 constraint 数字另算出的第二个“还缺”。

- [ ] **Step 5: 写日历标签与布局红灯**

断言 breakfast 显示“早餐”；固定日程时间已过不出现 `day-schedule-completed-*`；四种条目卡片 `getTopLeft/getTopRight` 的横坐标一致；不存在不可点击的 delete/folder/edit 三连灰色图标。

- [ ] **Step 6: 写生产源只发一次的红灯**

使用真实 `RepositoryScheduleViewSource` 与内存仓储：订阅后写入/失效，再断言 stream 收到第二份不同列表。不能用能手工 `add()` 的假 `_Source` 代替生产源。

- [ ] **Step 7: 运行定向测试并保存失败摘要**

```powershell
flutter test --no-pub test/scheduling/dynamic_short_tail_test.dart test/features/calendar/schedule_view_source_test.dart test/features/calendar/day_view_test.dart test/features/planning/unscheduled_display_test.dart
```

Expected: 失败点必须对应 R1/R2/R3/R5/R7/R9/R11；把每条实际失败写进实施记录。若只因编译错误失败，先修夹具，直到命中行为断言。

- [ ] **Step 8: 提交测试基线**

只暂存本任务文件；提交信息：`test: capture calendar and short-tail regressions`。

---

### Task 2: 修复保护时间名称与完成状态语义

**Files:**
- Modify: `lib/scheduling/schedule_problem.dart`
- Modify: `lib/scheduling/protected_time_expander.dart`
- Create: `lib/design/protected_time_labels.dart`
- Modify: `lib/features/calendar/week_view/schedule_view_source.dart`
- Modify: `lib/features/calendar/week_view/schedule_view_models.dart`
- Modify: `lib/data/database/daos/analytics_dao.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `test/scheduling/protected_time_expander_test.dart`
- Modify: `test/features/calendar/schedule_view_source_test.dart`
- Modify: `test/data/analytics_dao_test.dart`

**Interfaces:**
- Produces: `BusyInterval.protectedKind`；`protectedTimeKindLabel(ProtectedTimeKind)`；`ScheduleViewItem.isCompleted` 只表示任务完成。

- [ ] **Step 1: 为 BusyInterval 加 typed kind 测试**

展开 breakfast/lunch/dinner/fixedRest，逐条断言 `protectedKind`；sleep、fixed 和 locked busy interval 仍为 null。

- [ ] **Step 2: 实现 typed kind 与分层安全的标签映射**

按 §2.5 实现；删除日历与预览里的字符串 split/重复 switch。统计 DAO 不导入 design 层，只给默认规则和 JSON 规则补齐 breakfast 映射，并在 `analytics_dao_test.dart` 同时覆盖两条数据路径。

- [ ] **Step 3: 收紧完成状态**

固定日程无论是否经过结束时间都 `isCompleted=false`；只有任务状态为 completed 的计划块为 true。取消/跳过不显示完成勾，必要时保留真实历史卡片但不伪称完成。

- [ ] **Step 4: 运行定向验证**

```powershell
dart format lib/scheduling/schedule_problem.dart lib/scheduling/protected_time_expander.dart lib/design/protected_time_labels.dart lib/features/calendar/week_view/schedule_view_source.dart lib/features/calendar/week_view/schedule_view_models.dart lib/data/database/daos/analytics_dao.dart lib/features/planning/plan_preview_page.dart test/scheduling/protected_time_expander_test.dart test/features/calendar/schedule_view_source_test.dart test/data/analytics_dao_test.dart
flutter test --no-pub test/scheduling/protected_time_expander_test.dart test/features/calendar/schedule_view_source_test.dart test/data/analytics_dao_test.dart
```

Expected: breakfast 三处均为“早餐”；固定日程不出现任务完成语义；规则展开与容量行为不变。

- [ ] **Step 5: 提交**

提交信息：`fix: preserve protected-time labels and task completion semantics`。

---

### Task 3: 统一日视图卡片边界与操作入口

**Files:**
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/app/accessibility_semantics_test.dart`

**Interfaces:**
- Consumes: 既有删除、编辑、领域和打开设置回调。
- Produces: 单一更多菜单；每行固定 48 px 操作槽；既有业务回调签名不变。

- [ ] **Step 1: 写四类条目几何测试**

同时渲染任务、固定日程、自定义保护时间、规则保护时间。读取 `day-schedule-card-*` 的矩形，断言 left/right 完全相等；测试宽度 1024 和 1920。

- [ ] **Step 2: 写菜单可用性测试**

断言：

- 固定日程菜单只有编辑、调整领域、删除；
- 自定义保护时间只有编辑、删除；
- 规则保护时间只有去设置；
- 没有动作的任务不渲染可点击菜单；
- 不渲染禁用操作项；
- 删除仍弹确认，不会直接执行。

- [ ] **Step 3: 实现固定槽与菜单**

把当前 Row 中的四组条件 IconButton 改成一个 `_DayItemActions`。动作列表先按能力构造，再决定显示菜单或空槽。不要在 `_DayItemTile` 内查询仓储。

- [ ] **Step 4: 加键盘与语义断言**

Tab 可到达更多按钮；Enter 打开；方向键选择；Esc 关闭并返回焦点；Narrator 标签为“更多操作：事项标题”，菜单项含动作名称。

- [ ] **Step 5: 验证与提交**

```powershell
dart format lib/features/calendar/day_view/day_view_page.dart test/features/calendar/day_view_test.dart test/app/accessibility_semantics_test.dart
flutter test --no-pub test/features/calendar/day_view_test.dart test/app/accessibility_semantics_test.dart
```

提交信息：`fix: align day cards and expose only valid actions`。

---

### Task 4: 以当前剩余量生成候选并验证唯一短尾

**Files:**
- Modify: `lib/scheduling/candidate_generator.dart`
- Modify: `lib/scheduling/plan_validator.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `test/scheduling/candidate_generator_test.dart`
- Modify: `test/scheduling/short_remainder_test.dart`
- Modify: `test/application/short_remainder_matrix_test.dart`
- Create: `test/scheduling/dynamic_short_tail_test.dart`
- Modify: `test/scheduling/plan_validator_test.dart`
- Modify: `test/scheduling/granularity_contract_test.dart`
- Modify: `test/scheduling/algorithm_version_test.dart`
- Modify: `test/fixtures/scheduling/golden_week.json`

**Interfaces:**
- Produces: §2.1 的 `CandidateGenerator.generate(... remainingMinutes:)`；§2.2 的 `validatePlannedChunkSet()`；算法版本 `16`。

- [ ] **Step 1: 改 CandidateGenerator 接口并修齐编译调用点**

所有测试和生产调用必须显式传 `remainingMinutes`。禁止提供默认值掩盖漏改调用点。

- [ ] **Step 2: 写候选层矩阵**

对 remaining `100, 40, 30, 29, 12, 3, 0` 断言候选 duration 集合；0 返回空；负数和大于 required 抛 ArgumentError。

- [ ] **Step 3: 实现集合校验**

按 §2.2 实现 `validatePlannedChunkSet()`，让 `PlanValidator` 按 task id 一次校验整个集合。冲突仍使用现有结构化 code，不把 violation 枚举直接显示给用户。

- [ ] **Step 4: 把候选生成移入 remaining 循环**

每轮先生成候选，再应用截止、均分预算、重叠、每日上限、休息和评分。成功后扣减 remaining，下一轮重新生成。删除“初始 candidates 可代表全部后续轮次”的假设。

- [ ] **Step 5: 防止性能退化**

复用静态 slot 列表和 EvenDistributionPlan；不得每个 candidate 重建 AvailabilityAnalysis。保留现有规模测试，并增加相同输入重复 20 次结果字节级一致的确定性断言。

- [ ] **Step 6: 抬算法版本并更新 golden**

只在新的块输出已通过定向测试后，把版本 `15` 改为 `16`。逐项审阅 golden 的块变化，不能无条件接受全文件重写；文档记录变化只来自合法短尾。

- [ ] **Step 7: 运行验证**

```powershell
dart format lib/scheduling/candidate_generator.dart lib/scheduling/plan_validator.dart lib/scheduling/schedule_engine.dart test/scheduling test/application/short_remainder_matrix_test.dart
flutter test --no-pub test/scheduling/candidate_generator_test.dart test/scheduling/short_remainder_test.dart test/scheduling/dynamic_short_tail_test.dart test/scheduling/plan_validator_test.dart test/scheduling/granularity_contract_test.dart test/scheduling/algorithm_version_test.dart test/application/short_remainder_matrix_test.dart
```

Expected: §Review Focus 前四条全部通过；validator 与 generator 对每个矩阵输入一致。

- [ ] **Step 8: 提交**

提交信息：`fix: regenerate candidates for the remaining task duration`。

---

### Task 5: 用最终块集合生成可信失败诊断

**Files:**
- Create: `lib/scheduling/task_placement_diagnostics.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `lib/scheduling/explanations.dart`
- Modify: `lib/scheduling/proposal_disposition.dart`
- Modify: `lib/scheduling/task_capacity_analyzer.dart`
- Create: `test/scheduling/task_placement_diagnostics_test.dart`
- Modify: `test/scheduling/unscheduled_reason_test.dart`
- Modify: `test/scheduling/proposal_disposition_test.dart`
- Modify: `test/app/visible_free_time_preview_test.dart`

**Interfaces:**
- Consumes: Task 4 动态候选和集合校验。
- Produces: §2.3 的最终诊断；§2.4 的原因字段；异常缺口必为 blocking。

- [ ] **Step 1: 提取共同候选资格判定**

把引擎放置和诊断都需要的硬约束判定抽成同一个纯 evaluator。返回所有命中的结构化拒绝，不直接写 UI 文案。评分高低不是拒绝原因。

- [ ] **Step 2: 删除跨轮次 rejectionEvidence**

放置循环可以保留当前轮的调试局部变量，但最终 `unscheduled` 不得读取它。成功选择候选后，本轮拒绝自然销毁。

- [ ] **Step 3: 在所有块稳定后诊断**

执行顺序固定为：初次放置 → `_improve` → provenance/stability 处理 → 排序 → 计算最终 shortage → `diagnoseTaskPlacement` → unscheduled/conflicts。

- [ ] **Step 4: 写 gap exclusion 矩阵**

分别构造最早开始、截止、星期、最小连续片段、日上限、全局日上限、休息、固定日程、保护时间、锁定块。每个用例断言 code、UTC range 和数字。

- [ ] **Step 5: 改原因字段和文案**

删除 `_withNumbers()` 中的 `required - available` 缺口推导。每个 code 使用自己的模板；标题是唯一显示 shortage 的位置。所有测试断言不出现 UUID 和内部枚举名。

- [ ] **Step 6: 建立不可绕过的异常阻断**

`hasEligibleCandidate && shortage > 0` 必须同时产生 `unexplainedSchedulingFailure` 和 `schedulingInvariantViolation`；`classifyProposal()` 返回 blocked。`PlanApplicationService.apply()` 在 stale 检查之后、validator 之前先检查 `proposal.conflicts`：非空立即返回 `ApplyPlanResult.invalid(proposal.conflicts)`；因此 `allowPartial` 模式也不得绕过引擎已经报告的 blocking conflict，更不能写库。

- [ ] **Step 7: 验证与提交**

```powershell
dart format lib/scheduling/task_placement_diagnostics.dart lib/scheduling/schedule_engine.dart lib/scheduling/schedule_proposal.dart lib/scheduling/explanations.dart lib/scheduling/proposal_disposition.dart lib/scheduling/task_capacity_analyzer.dart test/scheduling/task_placement_diagnostics_test.dart test/scheduling/unscheduled_reason_test.dart test/scheduling/proposal_disposition_test.dart test/app/visible_free_time_preview_test.dart
flutter test --no-pub test/scheduling/task_placement_diagnostics_test.dart test/scheduling/unscheduled_reason_test.dart test/scheduling/proposal_disposition_test.dart test/app/visible_free_time_preview_test.dart test/application/plan_application_service_test.dart
```

提交信息：`fix: derive scheduling failures from the final plan`。

---

### Task 6: 重建预览的恢复路径与部分应用层级

**Files:**
- Modify: `lib/features/planning/plan_preview_issues.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/features/planning/plan_preview_test.dart`
- Modify: `test/features/planning/unscheduled_display_test.dart`
- Modify: `test/app/plan_preview_regression_test.dart`
- Modify: `test/app/visible_free_time_preview_test.dart`

**Interfaces:**
- Consumes: Task 5 的最终原因、excluded gaps 和 disposition。
- Produces: §2.8 的 recovery actions；普通任务可直接进入编辑；部分应用是次要动作。

- [ ] **Step 1: 扩展 PreviewIssue**

加入 `taskId`、`excludedGaps`、`actions`；`buildPreviewIssues()` 只根据 reason code 映射动作，不读取任务属性猜原因。

- [ ] **Step 2: 装配恢复路由**

`editTask` 打开现有任务编辑路由并带 task id；`openPlanningRules` 进入规划规则；`openProtectedTimeManagement` 进入保护时间管理；返回预览后标记旧提案 stale，并要求重新生成，不能继续应用旧提案。

- [ ] **Step 3: 展示空档排除证据**

每条 issue 默认只显示主原因。存在 `excludedGaps` 时显示“查看未使用空档”展开项；每行写本地日期时间和原因。最多首屏显示 6 条，其余用“另有 N 段”折叠；数据本身不截断。

- [ ] **Step 4: 调整按钮层级**

按 §2.8 三态表实现。部分应用二次确认必须列出每个任务的准确 shortage，并说明未安排部分仍留在待办中；取消时零写入。

- [ ] **Step 5: 移除预览里的自动调整开关**

删除预览页 `SwitchListTile`，不删除设置页持久化和完整提案自动应用逻辑。增加测试证明打开设置中的开关仍不会自动应用 warning/blocking 提案。

- [ ] **Step 6: 验证与提交**

```powershell
dart format lib/features/planning/plan_preview_issues.dart lib/features/planning/plan_preview_page.dart lib/app/router.dart test/features/planning test/app/plan_preview_regression_test.dart test/app/visible_free_time_preview_test.dart
flutter test --no-pub test/features/planning/plan_preview_test.dart test/features/planning/unscheduled_display_test.dart test/app/plan_preview_regression_test.dart test/app/visible_free_time_preview_test.dart test/application/plan_generation_safety_test.dart
```

提交信息：`fix: make plan-preview recovery explicit and safe`。

---

### Task 7: 让生产日历源在成功写入后自动刷新

**Files:**
- Create: `lib/application/schedule_view_invalidation.dart`
- Modify: `lib/features/calendar/week_view/schedule_view_source.dart`
- Modify: `lib/main.dart`
- Modify: `lib/app/planner_app.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/application/plan_application_service.dart`
- Modify: `lib/application/plan_undo_service.dart`
- Modify: `lib/application/calendar_service.dart`
- Modify: `lib/application/course_management_service.dart`
- Modify: `lib/application/settings_service.dart`
- Modify: `lib/application/schedule_color_service.dart`
- Modify: `lib/application/workspace_service.dart`
- Create: `test/application/schedule_view_invalidation_test.dart`
- Modify: `test/features/calendar/schedule_view_source_test.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/features/today/today_page_test.dart`

**Interfaces:**
- Produces: §2.6 的 app-scoped invalidation；`RepositoryScheduleViewSource.watch()` 多次发值。

- [ ] **Step 1: 实现并测试总线**

revision 从 1 单调递增；broadcast；无监听时 notify 不抛错；`dispose()` 幂等；dispose 后 notify 安全忽略。测试固定这些行为，不留下实现者自行选择的分支。

- [ ] **Step 2: 重写生产 watch**

按 §2.6 实现初始加载、合并触发、generation 防乱序、错误恢复和取消清理。不得通过定时轮询数据库实现。

- [ ] **Step 3: 接入任务变化**

使用 `tasks.watchAllTasks()` 触发重载，确保任务标题、领域、完成状态变化可见。重载时仍由 `_load` 读取一致快照；不要把 task stream 的局部列表直接塞进半份结果。

- [ ] **Step 4: 接入所有成功写入点**

按 §2.6 的装配规则逐个覆盖 plan apply、undo、calendar save/update/delete、course direct transaction、planning rules、colors、workspace。每个服务测试都断言成功一次发一个信号，失败/stale/cancel 发零次；经过 CalendarService 的课程写入不得产生两次刷新。

- [ ] **Step 5: 写乱序与抖动测试**

让第一次 `_load` 延迟，第二次先完成；stream 最终值必须是第二次。连续 20 个 notify 不得并发 20 次读取；最多一个在途加一个待处理。

- [ ] **Step 6: 写真实源跨页面测试**

三个页面订阅同一个生产 source；应用新计划后都收到同一 task id / range；编辑固定日程后都显示新标题/时间；无需离开页面或手工点刷新。

- [ ] **Step 7: 验证与提交**

```powershell
dart format lib/application/schedule_view_invalidation.dart lib/features/calendar/week_view/schedule_view_source.dart lib/main.dart lib/app/planner_app.dart lib/app/router.dart lib/application test/application/schedule_view_invalidation_test.dart test/features/calendar/schedule_view_source_test.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart test/features/today/today_page_test.dart
flutter test --no-pub test/application/schedule_view_invalidation_test.dart test/features/calendar/schedule_view_source_test.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart test/features/today/today_page_test.dart
```

提交信息：`fix: refresh calendar views after successful mutations`。

---

### Task 8: 修正近期日历命名并建立跨视图一致性

**Files:**
- Modify: `lib/features/calendar/week_view/week_view_page.dart`
- Modify: `lib/features/tutorial/tutorial_steps.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Modify: `test/app/app_smoke_test.dart`
- Modify: `test/app/calendar_event_route_test.dart`
- Modify: `test/app/notification_tap_navigation_test.dart`
- Modify: `test/app/timetable_import_route_test.dart`
- Create: `integration_test/calendar_preview_consistency_test.dart`

**Interfaces:**
- Consumes: Task 7 多次发值的数据源。
- Produces: “近期日历”名称；仍显示昨天 + 今天起七天；日/近期/今日同源一致性。

- [ ] **Step 1: 只改名称，不改日期范围**

标题改为“近期日历”；空状态改为“当前范围暂无安排”；教程说明写“昨天及未来七天”。保留 index `-1..6` 和现有拖动 key。

- [ ] **Step 2: 更新所有文本断言**

仓库搜索“七日日历”“未来七天暂无安排”，逐处判断是产品文案还是历史注释。产品文案和测试改名；历史故障描述不改写事实。

- [ ] **Step 3: 写集成一致性流程**

流程：启动 → 生成并应用计划 → 不重启切到近期日历和日视图 → 两处均出现相同课程和计划块 → 编辑固定日程 → 两处自动变更 → 完成任务 → 今日/日视图只给任务显示完成状态。

- [ ] **Step 4: 验证与提交**

```powershell
dart format lib/features/calendar/week_view/week_view_page.dart lib/features/tutorial/tutorial_steps.dart test/features/calendar/week_view_test.dart test/app integration_test/calendar_preview_consistency_test.dart
flutter test --no-pub test/features/calendar/week_view_test.dart test/app/app_smoke_test.dart test/app/calendar_event_route_test.dart test/app/notification_tap_navigation_test.dart test/app/timetable_import_route_test.dart
```

提交信息：`fix: name and refresh the eight-day calendar consistently`。

---

### Task 9: 可访问性、缩放与视觉回归

**Files:**
- Modify: `test/app/accessibility_semantics_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Modify: `test/features/planning/plan_preview_test.dart`
- Modify: `docs/testing/manual-windows-checklist.md`

**Interfaces:**
- Consumes: Tasks 2、3、6、8 的最终 UI。
- Produces: 键盘、语义、缩放和布局门禁；不改变业务模型。

- [ ] **Step 1: 文字缩放矩阵**

在 100%、125%、150%、200% 下泵日视图、近期日历和失败预览；断言无 `RenderFlex overflow`、无越界 exception；长标题可通过 tooltip/semantics 获知完整内容。

- [ ] **Step 2: 窗口宽度矩阵**

1024、1280、1920 三档验证卡片边界、菜单、问题动作和底部按钮。窄窗口允许合理换行/滚动，不允许操作被裁掉。

- [ ] **Step 3: 键盘路径**

不用鼠标完成：打开日程菜单、去设置、编辑任务、展开未使用空档、取消部分应用确认、重新生成。焦点顺序与视觉顺序一致。

- [ ] **Step 4: 语义断言**

完成任务读“已完成”；固定日程不读“已完成”；warning 读“需要处理”；blocking 读“无法应用”；部分应用按钮读出后果而不是只读“应用”。

- [ ] **Step 5: 更新人工清单**

把上述矩阵加入 `manual-windows-checklist.md`，实际结果栏留空。计划文件不能预先把未执行项写成通过。

- [ ] **Step 6: 验证与提交**

```powershell
flutter test --no-pub test/app/accessibility_semantics_test.dart test/features/calendar/day_view_test.dart test/features/calendar/week_view_test.dart test/features/planning/plan_preview_test.dart
```

提交信息：`test: guard calendar and preview accessibility`。

---

### Task 10: 全量回归、实机验收与交接

**Files:**
- Create: `docs/testing/calendar-preview-scheduling-integrity-acceptance.md`
- Modify: `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md`
- Modify: `docs/testing/manual-windows-checklist.md`

**Interfaces:**
- Consumes: Tasks 1–9 的最终接口与测试证据。
- Produces: 可审计验收记录；不自动创建 Release、不自动提升软件版本。

- [ ] **Step 1: 运行格式、静态分析和全量测试**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
```

Expected: 格式零改动、analyze 0 问题、全量测试 0 failure。记录真实通过数量和耗时，不沿用旧台账数字。

- [ ] **Step 2: 运行 Windows 集成测试**

```powershell
flutter test --no-pub integration_test/calendar_preview_consistency_test.dart -d windows
```

Expected: 计划应用、日程编辑、任务完成后，三个视图无需重启即一致。

- [ ] **Step 3: 构建但不发布候选**

只有 Step 1–2 通过才按 `docs/release/windows-release.md` 构建 Release。关闭旧进程后安装到测试目录；不得覆盖用户真实数据库。若未获发布授权，不创建 tag/GitHub Release。

- [ ] **Step 4: 执行人工场景 A——早餐与布局**

启用 breakfast 07:30–08:00。近期日历、日视图、今日页均显示“早餐”；同页课程、任务、自定义保护和规则保护卡片右边界一致；菜单无灰色无效项。

- [ ] **Step 5: 执行人工场景 B——动态短尾**

创建 100 分钟、可拆分 30–30、粒度 5 的匿名任务，提供四段容量；生成结果完整。再创建 103 分钟版本，预览只报 3 分钟不可表示缺口，正文数字不矛盾。

- [ ] **Step 6: 执行人工场景 C——真实容量不足**

让任务需要 40 分钟、最短 30，但只保留 20 分钟空档。预览说明最短片段与最长空档；“查看未使用空档”显示该 20 分钟和排除原因；不生成非法 20 分钟短块。

- [ ] **Step 7: 执行人工场景 D——跨视图刷新**

应用计划后依次打开今日、近期日历、日视图；同一块标题/时间一致。编辑课程和保护时间、撤销计划、完成任务，每次均自动刷新，不切页、不重启。

- [ ] **Step 8: 执行人工场景 E——预览安全性**

可解释真实缺口只显示次要的“仍应用可安排部分”；点击后有精确确认。制造测试用无法解释异常时只允许重新生成，无法部分应用。预览页没有“信任自动调整”开关。

- [ ] **Step 9: 执行人工场景 F——时区与边界**

验证 Asia/Shanghai 的周日→周一、23:55→00:05、截止恰好等于空档终点；再用 America/New_York 的 DST 切换周跑自动化夹具。所有比较保持半开区间，无重复/漏项。

- [ ] **Step 10: 记录验收证据**

每项写执行时间、构建哈希、操作、期望、实际、截图路径和结论。任何失败回到所属 Task，修复后重跑该任务定向测试、全量测试和受影响人工场景。

- [ ] **Step 11: 更新规范与最终提交**

设计规范写入最终接口和不变量；验收记录不得把未执行项写成 PASS。只暂存本任务文件，提交信息：`docs: record calendar and scheduling integrity verification`。

## 5. 自动化验收矩阵

| 需求 | 单元 | Widget/路由 | Integration | 人工 |
| --- | --- | --- | --- | --- |
| 长任务动态短尾 | Task 4 | Task 6 | Task 10 | B |
| 短尾集合合法性 | Task 4 | — | Task 10 | B |
| 不保留旧拒绝原因 | Task 5 | Task 6 | Task 10 | C/E |
| 缺口数字一致 | Task 5 | Task 6 | Task 10 | B/C |
| 异常提案阻断 | Task 5 | Task 6 | Task 10 | E |
| 空档排除原因 | Task 5 | Task 6 | Task 10 | C |
| 早餐标签 | Task 2 | Task 3/8 | Task 10 | A |
| 卡片右边界 | — | Task 3/9 | Task 10 | A |
| 只显示可用操作 | — | Task 3/9 | Task 10 | A |
| 固定日程不冒充完成 | Task 2 | Task 3/9 | Task 10 | D |
| 生产源自动刷新 | Task 7 | Task 7/8 | Task 8/10 | D |
| 乱序加载不覆盖新值 | Task 7 | Task 7 | Task 10 | D |
| 八列命名准确 | — | Task 8 | Task 10 | D |
| 部分应用层级 | Task 5 | Task 6/9 | Task 10 | E |
| 自动调整只在设置 | Task 6 | Task 6 | Task 10 | E |
| 缩放/键盘/语义 | — | Task 9 | Task 10 | A/E |

## 6. 禁止的捷径

- 不允许只在 `_protectedLabel` 增加一个 breakfast case 后继续依赖 id 格式；kind 必须作为类型数据传递。
- 不允许把 `minChunkMinutes` 全局改小、把 min 约束删除或让任意短块通过 validator。
- 不允许只在任务初始总量低于 min 时宽免；本计划修复的是长任务经过多轮后形成的最终短尾。
- 不允许继续把初始候选集保存到循环外，再用 `candidate.duration > remaining` 过滤；这正是 R3 的根因。
- 不允许以“最后一次拒绝”或固定优先级覆盖最终事实；最终原因必须根据最终块集合重新诊断。
- 不允许 UI 根据 task 属性推测失败原因；UI 只翻译引擎事实。
- 不允许再从 `constraintRequired - constraintAvailable` 推导总缺口。
- 不允许把所有 `unscheduled` 都视为可部分应用；`unexplainedSchedulingFailure` 和结构冲突必须阻断。
- 不允许通过页面 `setState`、切换路由或定时刷新掩盖一次性生产 stream。
- 不允许让每个页面各建一套失效总线；整个应用只有一个 app-scoped 实例。
- 不允许成功信号在数据库事务提交前发送；否则页面可能先读到旧值并错过真正提交。
- 不允许用禁用图标占位解决对齐；固定的是操作槽宽度，不是无意义控件数量。
- 不允许删除昨天列来让“七日”字面成立；既有产品要求明确保留昨天，正确修复是改名。
- 不允许把固定日程的“时间已过”继续映射成任务“已完成”。
- 不允许未执行 Windows 实机验收就声明修复完成或发布就绪。

## 7. 完成定义

以下条件缺一项都不能写“修复完成”：

- Task 1–10 的 checkbox 有对应测试输出、提交或人工记录；
- 动态短尾矩阵全部通过，候选生成与 validator 对同一输入一致；
- 最终 unscheduled 原因来自最终块集合，旧轮次拒绝不能污染结果；
- 任一 issue 的标题缺口与原因正文数字不矛盾；
- 合法候选未使用时提案为 blocked，`allowPartial` 也无法写库；
- breakfast 在全部视图显示“早餐”；
- 日视图卡片右边界一致，菜单只含可执行动作；
- 固定日程不显示任务完成勾；
- 近期日历名称与八列范围一致；
- 计划、日程、任务、规则和颜色成功变化后，三个日历视图自动刷新；
- 格式检查零改动、`flutter analyze --no-pub` 0 问题、全量测试和 Windows 集成测试通过；
- Windows 人工验收 A–F 有真实记录；
- 数据库 schema、备份格式、软件版本和用户数据未被本计划意外修改；
- 未经用户单独授权，不创建发布、tag 或远程提交。

## 8. 执行交接模板

实施完成后只允许按真实结果填写：

```markdown
## Calendar / Preview / Scheduling Integrity Repair — Handoff

### Scope
- Implemented tasks:
- Deferred tasks and reason:

### Root-cause evidence
- Dynamic remaining reproduction:
- Final-diagnostics reproduction:
- Production refresh reproduction:

### Verification
- Targeted tests:
- Full test count:
- Analyze:
- Windows integration:
- Manual scenarios A–F:

### Safety
- Schema unchanged:
- Backup format unchanged:
- Product version unchanged:
- No user data used:
- No remote action performed:

### Remaining risk
-

### Status
- NOT COMPLETE / COMPLETE (choose one; COMPLETE requires every item in §7)
```

