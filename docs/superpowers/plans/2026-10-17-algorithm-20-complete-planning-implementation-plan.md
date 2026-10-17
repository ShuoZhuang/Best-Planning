# 算法 20：完整约束规划、特殊日与学习偏好实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本计划只允许一个写入者按 Task 顺序实施；禁止多个代理同时修改同一工作树、同一 Task 或相邻接口。只读审查必须等当前写入步骤结束后进行。

**Goal:** 在算法 19 已通过的容量感知排程基础上，交付算法 20 的统一有界修复、真实特殊日、临时延长日和可信领域学习偏好，并让每个失败结论都能由同一份容量与约束证据复核。

**Architecture:** 生产流程固定为“输入事实与逐日规则 → 形状容量 → 稀缺度跨日分配 → 日内放置 → 有界交换 → 字典序方案选择 → 结构化诊断 → 安全应用”。特殊日和偏好先持久化为有作用域的事实，再由输入装配层生成不可变快照；排程内核不读取数据库、设置或界面状态。

**Tech Stack:** Dart 3、Flutter 3.47.5、Drift/SQLite、现有 `TimeZoneDatabase`、`flutter_test`；不增加运行时依赖、联网服务或随机求解器。

**Spec:** `docs/superpowers/specs/2026-10-17-algorithm-20-complete-planning-design.md`

**Historical Baseline:** `docs/superpowers/plans/2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`、`docs/testing/capacity-aware-scheduler-acceptance.md`。它们记录算法 17–19 的实施过程，不作为算法 20 当前状态来源。

## Global Constraints

- 当前代码基线为 HEAD `d5951f10`、`DeterministicScheduleEngine.algorithmVersion == '19'`、schema v10；开始 Task 1 时重新记录真实值，若已变化立即停下重做基线。
- 产品版本保持 1.8.0；本计划不修改 `pubspec.yaml`、MSIX 版本或 GitHub Release。
- 算法版本在 Task 16 全部门禁通过前保持 19；只有最终版本提交可改为 20。
- Task 1–16 必须顺序实施。一个 Task 未提交、未清洁工作树或验收失败时，后续 Task 不得开始。
- 固定日程、课程、保护时间、睡眠最低线、课程过渡、锁定块、截止、最早开始、允许星期、连续/拆分、片段上下限、休息和每日上限均为硬约束。
- 精力、学习偏好、期望时段、负载均衡、坏空档和恢复余量均为软目标，不得删除合法候选。
- 区间统一使用 `[startUtc, endUtc)`；本地日期和星期必须通过 `TimeZoneDatabase` 计算。
- 一次计划只捕获一次 `nowUtc`；领域服务、排程、诊断和校验内部禁止调用 `DateTime.now()`。
- 相同规范化输入必须逐值确定；集合、数据库结果和候选全部显式排序，不用系统随机源和 Dart `hashCode`。统计重采样只能使用规范冻结的固定索引序列。
- 任一失败路径必须保留上一版确认计划。结构异常、搜索未决、过期输入、未兑现明确操作和校验失败零写入。
- 预览不得显示裸 UUID；普通日志不得记录真实标题、备注、UUID、数据库路径或睡眠明细。
- 迁移只新增特殊日表和索引。不得改写既有任务、日历、计划、专注记录或偏好证据。
- 不直接修改生成文件 `app_database.g.dart`、`app_database.steps.dart`；先改表与迁移，再运行仓库现有生成命令。
- 每个 Task 遵循：写失败测试、确认失败原因、最小实现、专项通过、相关回归、提交、工作树清洁。
- 不用更新 golden、删除测试、放宽硬断言或增加隐藏例外来解决红灯。

## Review Focus

- **跨午夜与本地周界：** 上海时区 23:00 后专注、周日到周一、月末和年末必须落到正确本地日与时段桶；Task 4、5、15 覆盖。
- **合法但碎片化的容量：** 总分钟足够而最长连续段不足、20 分钟坏空档、短尾和重叠阻塞必须得到不同结果；Task 7、8、15 覆盖。
- **确认状态与刷新：** 已确认、拒绝、停用和用户编辑的学习建议不能因页面重载回到待确认；Task 5 覆盖生产装配形状。
- **临时延长日失败原子性：** 用户确认特殊日后若计划重放或写入失败，特殊日与计划必须同时不落库；Task 12、14 覆盖。
- **搜索边界：** 有解、已证明无解和预算耗尽必须分开；最佳合法部分方案要稳定保留，Task 9、15 覆盖。

---

## 1. 文件与职责

### 1.1 新建生产文件

| 文件 | 单一职责 |
| --- | --- |
| `lib/domain/models/day_exception.dart` | 特殊日、临时延长日、恢复选择的不可变领域模型 |
| `lib/domain/repositories/day_exception_repository.dart` | 特殊日读取、保存、撤销端口 |
| `lib/data/repositories/drift_day_exception_repository.dart` | v11 特殊日 Drift 适配器 |
| `lib/domain/repositories/preference_rule_repository.dart` | 领域建议、确认规则、状态与版本的持久化端口 |
| `lib/data/repositories/drift_preference_rule_repository.dart` | 复用现有 `preference_rules` 表的 Drift 适配器 |
| `lib/domain/repositories/planning_commit_repository.dart` | 计划、特殊日与恢复效果的一次性原子提交端口 |
| `lib/application/day_exception_service.dart` | 创建、确认、撤销、配额与连续日校验 |
| `lib/application/extension_day_service.dart` | 从排程诊断生成候选，确认时协调特殊日和新提案 |
| `lib/domain/models/preference_snapshot.dart` | 领域级和全局偏好的不可变排程快照 |
| `lib/application/preference_evidence_service.dart` | 专注、移动、建议动作证据的统一写入入口 |
| `lib/scheduling/shape_aware_capacity.dart` | 任务逐日形状容量和值对象 |
| `lib/scheduling/frozen_block_policy.dart` | 纯函数计算冻结块 ID |
| `lib/scheduling/bounded_repair_search.dart` | 有界交换、去重、预算和最佳方案保留 |
| `lib/scheduling/extension_day_policy.dart` | 延长日硬边界、候选排序与配额纯规则 |

### 1.2 修改生产文件

| 文件 | 责任 |
| --- | --- |
| `lib/data/database/tables/planner_tables.dart` | 新增 `DayExceptions` 表 |
| `lib/data/database/app_database.dart` | schema v11、只新增迁移和索引 |
| `lib/domain/services/preference_analyzer.dart` | 新证据指标、时段与片段建议、稳定状态 ID |
| `lib/domain/models/preferences.dart` | 兼容读取旧偏好，禁止继续承载领域映射 |
| `lib/application/focus_evidence_recorder.dart` | 写完整会话结果和正确本地日期/时段 |
| `lib/application/preference_service.dart` | 状态机、刷新合并、清除与重新开启；通过规则仓储持久化 |
| `lib/application/settings_service.dart` | 学习总开关、绝对最低睡眠、延长日频率设置 |
| `lib/application/repository_schedule_problem_source.dart` | 装配特殊日与 `PreferenceSnapshot` |
| `lib/application/recovery_planning_service.dart` | 把四个恢复选择改成真实不同操作 |
| `lib/scheduling/schedule_problem.dart` | 偏好快照、搜索模式、特殊日上下文 |
| `lib/scheduling/day_capacity_ledger.dart` | 使用形状容量并支持预算退回 |
| `lib/scheduling/day_allocation.dart` | 稀缺度排序、跨日预算和稳定轮换 |
| `lib/scheduling/local_repair.dart` | 只做局部级联并返回结构化失败 |
| `lib/scheduling/schedule_objective.dart` | 三种模式的完整字典序向量 |
| `lib/scheduling/schedule_engine.dart` | 编排阶段、有界搜索、最佳合法方案和算法版本门禁 |
| `lib/scheduling/task_placement_diagnostics.dart` | 从统一拒绝事实生成原因 |
| `lib/scheduling/schedule_proposal.dart` | 搜索结果、扩展日候选和完整诊断 |
| `lib/scheduling/plan_quality_validator.dart` | 结构异常、坏空档和方案质量底线 |
| `lib/application/plan_application_service.dart` | 特殊日与计划事务、搜索状态拦截 |
| `lib/data/repositories/drift_plan_repository.dart` | 实现统一提交端口；普通应用和特殊日确认共用一段数据库事务 |
| `lib/features/settings/preferences/preferences_page.dart` | 学习开关、领域进度、状态与立即重排入口 |
| `lib/features/calendar/special_day/special_day_page.dart` | 持久特殊日、候选、恢复选择和撤销 |
| `lib/features/planning/plan_preview_page.dart` | 结构化原因和延长日建议卡 |
| `lib/main.dart` | 只做组合根接线，不写业务判断 |

### 1.3 主要测试文件

新增测试与生产目录镜像；核心文件名固定为：

- `test/domain/day_exception_test.dart`
- `test/drift/day_exception_repository_test.dart`
- `test/drift/schema_v11_migration_test.dart`
- `test/application/day_exception_service_test.dart`
- `test/application/preference_evidence_service_test.dart`
- `test/domain/preference_analyzer_v2_test.dart`
- `test/application/preference_state_machine_test.dart`
- `test/drift/preference_rule_repository_test.dart`
- `test/application/preference_snapshot_wiring_test.dart`
- `test/scheduling/shape_aware_capacity_test.dart`
- `test/scheduling/frozen_block_policy_test.dart`
- `test/scheduling/bounded_repair_search_test.dart`
- `test/scheduling/extension_day_policy_test.dart`
- `test/application/extension_day_service_test.dart`
- `test/application/special_day_atomic_apply_test.dart`
- `test/drift/planning_commit_repository_test.dart`
- `test/app/algorithm20_preview_test.dart`
- `test/application/algorithm20_real_workflow_test.dart`
- `test/application/algorithm20_determinism_property_test.dart`
- `test/scheduling/algorithm20_performance_test.dart`
- `test/scheduling/algorithm20_golden_test.dart`
- `test/fixtures/scheduling/algorithm20_week.json`
- `docs/testing/algorithm20-acceptance.md`

## 2. 冻结接口

后续 Task 必须使用这些名称；变更签名前先更新本计划并记录原因。

```dart
enum DayExceptionKind { userSpecialDay, temporaryExtensionDay }
enum DayExceptionStatus { draft, confirmed, revoked, expired }
enum RecoveryChoice { nextDayRest, nextNightEarlierSleep, reduceNextDayLoad, none }

final class DayException {
  const DayException({
    required String id,
    required DateTime localDate,
    required DayExceptionKind kind,
    required DayExceptionStatus status,
    required int originalSleepStartOffsetMinutes,
    required int temporarySleepStartOffsetMinutes,
    required int fixedWakeOffsetMinutes,
    required int absoluteMinimumSleepMinutes,
    required RecoveryChoice recoveryChoice,
    required String source,
    required DateTime createdAtUtc,
    required DateTime updatedAtUtc,
    String? triggeringProposalId,
    DateTime? recoveryLocalDate,
    DateTime? revokedAtUtc,
  });
}

abstract interface class DayExceptionRepository {
  Future<DayException?> findConfirmed(DateTime localDate);
  Future<List<DayException>> listAffecting(DateTime localDate);
  Future<List<DayException>> listBetween(DateTime first, DateTime last);
  Future<void> save(DayException value);
  Future<void> revoke(String id, DateTime revokedAtUtc);
}

enum LearnedPreferenceStatus {
  suggested,
  edited,
  confirmed,
  rejected,
  disabled,
  superseded,
}

enum LearnedPreferenceKind { preferredTimeWindow, preferredFocusMinutes }

final class LearnedPreferenceRule {
  const LearnedPreferenceRule({
    required String id,
    required LearnedPreferenceKind kind,
    required String subjectKey,
    required LearnedPreferenceStatus status,
    required int confidencePermille,
    required String source,
    required String evidenceVersion,
    required DateTime updatedAtUtc,
    int? preferredStartMinute,
    int? preferredEndMinute,
    int? preferredFocusMinutes,
    String? supersedesId,
  });
}

abstract interface class PreferenceRuleRepository {
  Future<List<LearnedPreferenceRule>> listAll();
  Future<List<LearnedPreferenceRule>> listForSubject(String subjectKey);
  Future<void> save(LearnedPreferenceRule value);
  Future<void> saveAllAtomically(List<LearnedPreferenceRule> values);
  Future<void> clearLearnedRules();
}

final class PreferenceSnapshot {
  const PreferenceSnapshot({
    required bool enabled,
    required Map<String, SubjectPreference> bySubject,
    SubjectPreference? global,
    required String evidenceVersion,
  });
  SubjectPreference? forTask({required String? areaId});
}

final class TaskDayCapacity {
  const TaskDayCapacity({
    required String taskId,
    required DateTime localDate,
    required int hardFreeMinutes,
    required int constraintEligibleMinutes,
    required int placeableMinutes,
    required int longestContiguousMinutes,
    required Map<int, int> slotCountByChunkSize,
    required int remainingTaskDailyLimitMinutes,
    required int remainingGlobalDailyLimitMinutes,
    required Map<CandidateRejectionCode, int> rejectionCounts,
  });
}

final class SearchBudget {
  const SearchBudget({
    required int maxStates,
    required int maxFrontier,
    required int maxRepairDepth,
    required int maxBranchesPerState,
  });
}

final class ExtensionDayCandidate {
  const ExtensionDayCandidate({
    required DateTime localDate,
    required int temporarySleepStartOffsetMinutes,
    required int fixedWakeOffsetMinutes,
    required int addedPlaceableMinutes,
    required int sleepLossMinutes,
    required List<String> triggeringTaskIds,
    required String stableKey,
  });
}

final class RecoveryCommitEffect {
  const RecoveryCommitEffect({
    required RecoveryChoice choice,
    required DateTime nextLocalDate,
    TimeRange? protectedRestUtc,
    int? nextNightSleepStartMinute,
    int? nextDayMovableLoadCapMinutes,
  });
}

final class PlanningCommitRequest {
  const PlanningCommitRequest({
    required ScheduleProposal proposal,
    required String expectedInputHash,
    DayException? confirmedDayException,
    RecoveryCommitEffect? recoveryEffect,
  });
}

abstract interface class PlanningCommitRepository {
  Future<ApplyPlanResult> commit(PlanningCommitRequest request);
}

enum RepairSearchStatus { feasible, hardInfeasible, budgetExhausted }

final class RepairSearchResult {
  const RepairSearchResult({
    required RepairSearchStatus status,
    required List<PlannedBlock> bestBlocks,
    required List<UnscheduledTask> unscheduled,
    required int visitedStates,
    required String deterministicSignature,
  });
}

Set<String> computeFrozenBlockIds({
  required List<PlannedBlock> baseline,
  required DateTime nowUtc,
  required Set<String> executingBlockIds,
  required Set<String> explicitlyPinnedIds,
  BlockAdjustmentContext? adjustment,
});
```

## 3. 任务依赖

```text
Task 1 baseline
  -> Task 2 schema/model
  -> Task 3 day exception service
  -> Task 4 preference evidence
  -> Task 5 preference analysis/state
  -> Task 6 preference snapshot wiring
  -> Task 7 shape capacity
  -> Task 8 allocation/placement
  -> Task 9 bounded repair search
  -> Task 10 frozen IDs/stability
  -> Task 11 extension candidates
  -> Task 12 special-day recovery/atomic confirm
  -> Task 13 diagnostics/UI
  -> Task 14 application safety/migration audit
  -> Task 15 properties/performance/real workflows
  -> Task 16 full gate/version 20/golden/handoff
```

## 4. 实施任务

### Task 1: 冻结算法 19 基线与红灯矩阵

**Files:**
- Create: `docs/testing/algorithm20-acceptance.md`
- Test: 本计划列出的新测试文件先创建最小失败用例，不改生产代码

**Interfaces:**
- Consumes: 当前 HEAD、schema、算法版本和全量测试。
- Produces: 可复核基线、需求到测试映射、每个现有缺陷的 RED 证据。

- [ ] **Step 1: 记录基线**

在验收文件写入 HEAD、分支、Flutter/Dart、schema、算法版本、工作树状态和已有未提交文件。若工作树不干净，逐文件登记所有者；不得清理或提交用户改动。

- [ ] **Step 2: 运行格式、静态检查和全量测试**

- Run: `dart format --output=none --set-exit-if-changed lib test`
- Run: `G:\flutter-3.47.5\bin\flutter.bat analyze --no-pub`
- Run: `G:\flutter-3.47.5\bin\flutter.bat test --no-pub --concurrency=1`

Expected: 记录实际退出码和测试数。任何非既知失败先处理或停下，不能在坏基线上实施。

- [ ] **Step 3: 写八条真实红灯**

至少覆盖：分钟阈值/百分比错误、确认状态刷新、无生产手动移动证据、领域偏好污染全局、夜间桶、可行方案需交换、特殊日不持久、特殊日与计划非原子。

- [ ] **Step 4: 证明红灯因目标缺陷失败**

逐文件运行；验收文件记录每条断言和失败信息。编译错误不算合格红灯。

- [ ] **Step 5: Commit**

`git commit -m "test: freeze algorithm 20 failure baseline"`

### Task 2: 新增特殊日模型与 schema v11

**Files:**
- Create: `lib/domain/models/day_exception.dart`
- Create: `lib/domain/repositories/day_exception_repository.dart`
- Create: `lib/data/repositories/drift_day_exception_repository.dart`
- Modify: `lib/data/database/tables/planner_tables.dart`
- Modify: `lib/data/database/app_database.dart`
- Test: `test/domain/day_exception_test.dart`
- Test: `test/drift/day_exception_repository_test.dart`
- Test: `test/drift/schema_v11_migration_test.dart`

**Interfaces:**
- Consumes: §2 的 `DayException` 与仓储接口。
- Produces: v11 持久事实和稳定 CRUD；Task 3、11、12 使用。

- [ ] **Step 1: 写领域不变量测试**

断言本地日期已归一、UTC 时间有效、`original <= temporary < fixedWake <= 2880`、固定起床偏移不变、按时区解析后的实际睡眠不少于绝对最低、非 `none` 恢复必须有已归一的 `recoveryLocalDate`、撤销状态必须有撤销时间。覆盖 22:00 延至次日 01:00、月末、年末和夏令时转换日；禁止把 01:00 当成比 22:00 更早。

- [ ] **Step 2: 写迁移红灯**

从仓库保留的 v1–v10 每个历史 schema 夹具分别升级到 v11；断言原表逐值不变，新表为空、外键开启、索引存在。全新库和每条升级路径的 schema 一致；缺少任一历史夹具时先补齐夹具，不能把该版本记为已验证。

- [ ] **Step 3: 实现表和模型**

表名 `day_exceptions`。本地日期与可空的恢复本地日期存 `YYYY-MM-DD`；枚举存稳定 name；原睡眠、临时睡眠和固定起床存相对本地日 00:00 的偏移分钟并约束在 0–2880，保持跨日顺序；审计时刻存 UTC 微秒。偏移转 UTC 必须经 `TimeZoneDatabase`，不得用系统区域或固定时差。

- [ ] **Step 4: 实现仓储并生成 Drift 文件**

仓储查询显式按本地日期、更新时间、ID 排序。`listAffecting` 同时匹配特殊日本地日期和恢复本地日期，并只返回 `confirmed`。为两列分别建索引。相同特殊日本地日期允许保留历史记录，但最多一条 `confirmed` 由服务层与事务保证。

- [ ] **Step 5: 运行测试与迁移全套**

Expected: 新增测试 PASS，既有 schema 测试全绿。

- [ ] **Step 6: Commit**

`git commit -m "feat: persist day exceptions"`

### Task 3: 特殊日生命周期与配额

**Files:**
- Create: `lib/application/day_exception_service.dart`
- Modify: `lib/application/settings_service.dart`
- Test: `test/application/day_exception_service_test.dart`

**Interfaces:**
- Consumes: `DayExceptionRepository`、`Clock`、`SettingsService`。
- Produces: `createDraft`、`confirm`、`revoke`、`confirmedForDate`、`remainingExtensionQuota`。

- [ ] **Step 1: 写生命周期测试**

覆盖草稿不生效、确认生效、同日旧确认被撤销、撤销可见、过期只读、日期边界按本地日。

- [ ] **Step 2: 写配额测试**

覆盖滚动 7 日默认最多 2 次、可设置 0/1/2、禁止连续日、一份计划最多采用一次、主动特殊日与临时延长日分别计数。

- [ ] **Step 3: 实现服务**

所有校验在保存前完成；服务不生成计划、不读 UI。错误使用带字段的特定异常，页面不得解析字符串决定行为。

- [ ] **Step 4: 运行专项与设置回归**

- [ ] **Step 5: Commit**

`git commit -m "feat: manage special day lifecycle"`

### Task 4: 统一学习证据并修正本地时间

**Files:**
- Create: `lib/application/preference_evidence_service.dart`
- Modify: `lib/domain/services/preference_analyzer.dart`
- Modify: `lib/application/focus_evidence_recorder.dart`
- Modify: 手动移动成功的应用服务调用点，由红灯定位实际文件
- Modify: `lib/features/settings/preferences/preferences_page.dart`
- Test: `test/application/preference_evidence_service_test.dart`
- Test: `test/application/preference_evidence_loop_test.dart`

**Interfaces:**
- Consumes: 完成/中断专注、确认后的手动移动、建议动作、特殊日查询。
- Produces: `recordFocusOutcome`、`recordManualMove`、`recordSuggestionAction` 和 version 2 metadata。

- [ ] **Step 1: 写证据红灯**

断言无领域任务进入 `global`、手动移动生产入口写证据、建议接受/拒绝写证据、通过 `DayExceptionRepository.listAffecting` 标记特殊日与恢复日、跨午夜使用会话开始本地日并正确分桶。

- [ ] **Step 2: 冻结四个时段边界**

测试 04:59/05:00、11:59/12:00、17:59/18:00、22:59/23:00、跨午夜。不得再把凌晨归为 evening。

- [ ] **Step 3: 实现统一服务并替换散落写入**

旧行不改写；新行在 metadata 写 `evidenceVersion: 2` 和完整整数指标。写证据失败不得让用户的专注完成或移动操作回滚，但要记录脱敏错误事件。

- [ ] **Step 4: 运行证据、专注、移动和特殊日回归**

- [ ] **Step 5: Commit**

`git commit -m "feat: record reliable preference evidence"`

### Task 5: 重写偏好分析与建议状态机

**Files:**
- Create: `lib/domain/repositories/preference_rule_repository.dart`
- Create: `lib/data/repositories/drift_preference_rule_repository.dart`
- Create: `test/domain/preference_analyzer_v2_test.dart`
- Create: `test/application/preference_state_machine_test.dart`
- Modify: `lib/domain/services/preference_analyzer.dart`
- Modify: `lib/application/preference_service.dart`
- Modify: `lib/features/settings/preferences/preferences_page.dart`
- Modify: `lib/main.dart`
- Test: `test/drift/preference_rule_repository_test.dart`
- Test: `test/features/settings/preferences_evidence_trigger_test.dart`
- Test: `test/features/settings/preferences_page_test.dart`

**Interfaces:**
- Consumes: v2 证据和当前建议/规则状态。
- Produces: 领域级时段建议、领域级片段建议、稳定刷新状态和可见进度。

- [ ] **Step 1: 写整数效果分测试**

固定公式输入输出；原始分钟不能直接成为效果差。断言差 149/1000 不建议、150/1000 且置信门槛满足才建议。旧证据单独计数但不进入分析。

- [ ] **Step 2: 写片段建议测试**

20 条、14 天后取 5 分钟粒度稳健中位数，并夹在用户片段范围内；建议不改任务预计总时长。

- [ ] **Step 3: 写状态机生产形状测试**

页面带 `loadEvidence`：确认后 `_reload` 仍为 confirmed；拒绝、停用和 edited 同理。新证据生成新版本时旧项 superseded；陈旧未确认建议移除。

- [ ] **Step 4: 把现有规则表接成唯一持久化源**

使用 schema v1 已存在的 `preference_rules`，不为偏好再升 schema。`id/kind/subjectKey/status/source/updatedAtUtc` 使用独立列；建议值、证据版本、置信区间和 `supersedesId` 放入版本化 `valueJson`；`confidence` 只保存无量纲置信度。查询固定按 `subjectKey/kind/updatedAtUtc/id` 排序。`SettingsPreferenceStore` 中的旧全局档案只作为一次性兼容输入：首次成功迁移后写入规则表并记录迁移标记，不得与新规则双写。

- [ ] **Step 5: 修复清除/开关**

“清除结果”在一笔数据库事务内清空学习规则与建议，但不关闭学习；学习总开关只保存在 `settings`，可以关闭和重新开启。自动采用默认关闭；撤销按钮仅在存在自动采用历史时启用。

- [ ] **Step 6: 实现领域进度**

页面显示记录、活跃日、时段样本、排除数量和剩余门槛；百分比只显示无量纲效果分，不显示分钟乘 100。

- [ ] **Step 7: 运行专项与持久化回归**

- [ ] **Step 8: Commit**

`git commit -m "fix: make learned preferences reliable"`

### Task 6: 将领域偏好快照接入排程

**Files:**
- Create: `lib/domain/models/preference_snapshot.dart`
- Modify: `lib/domain/repositories/preference_rule_repository.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/scheduling/schedule_problem.dart`
- Modify: `lib/application/input_snapshot_builder.dart`
- Test: `test/application/preference_snapshot_wiring_test.dart`
- Test: `test/application/learned_preference_storage_test.dart`

**Interfaces:**
- Consumes: `PreferenceRuleRepository` 中已确认规则、任务领域映射、用户手动规则。
- Produces: `PreferenceSnapshot.forTask(areaId:)` 和输入哈希中的偏好版本。

- [ ] **Step 1: 写作用域红灯**

学习领域偏好只影响学习任务；工作任务保持自身/全局偏好。确认第二个领域不覆盖第一个。用户手动设置优先。

- [ ] **Step 2: 替换空偏好装配**

删除 `preferences: const PreferenceProfile()` 的生产路径。输入装配从规则仓储一次读取不可变快照；快照按 subject/kind/规则 ID 排序，确认、撤销或停用偏好后版本及输入哈希同时变化。排程执行期间不得再次读库。

- [ ] **Step 3: 修正偏好片段语义**

偏好片段只进入候选软评分和新任务片段默认值，不改 `estimatedMinutes`，不改已有任务硬片段范围。

- [ ] **Step 4: 运行排程与设置回归**

- [ ] **Step 5: Commit**

`git commit -m "feat: scope learned preferences by area"`

### Task 7: 建立形状感知容量唯一事实源

**Files:**
- Create: `lib/scheduling/shape_aware_capacity.dart`
- Modify: `lib/scheduling/availability_builder.dart`
- Modify: `lib/scheduling/task_capacity_analyzer.dart`
- Modify: `lib/scheduling/day_capacity_ledger.dart`
- Test: `test/scheduling/shape_aware_capacity_test.dart`
- Test: `test/scheduling/task_capacity_analyzer_test.dart`

**Interfaces:**
- Consumes: `ScheduleProblem`、任务、当前块、每日策略。
- Produces: `TaskDayCapacity`、拒绝计数和稳定形状签名。

- [ ] **Step 1: 写容量层级测试**

覆盖总空闲足够但连续不足、多个小槽不能拼连续任务、短尾、重叠阻塞只扣一次、每日任务上限和全局上限分别归因。

- [ ] **Step 2: 写20分钟空档测试**

有合法 15 分钟任务时计可落地；所有剩余任务 minChunk 30 时计碎片空档，不得计为可安排容量。

- [ ] **Step 3: 实现容量值对象和缓存**

缓存键包含任务约束、日期、每日策略和已选块签名；块变化后只失效相关日期。诊断和分配共用结果。

- [ ] **Step 4: 运行现有“可见空闲”全部回归**

- [ ] **Step 5: Commit**

`git commit -m "feat: compute shape-aware task capacity"`

### Task 8: 按稀缺度完成跨日分配与日内放置

**Files:**
- Modify: `lib/scheduling/day_allocation.dart`
- Modify: `lib/scheduling/day_capacity_ledger.dart`
- Modify: `lib/scheduling/candidate_generator.dart`
- Modify: `lib/scheduling/candidate_scorer.dart`
- Modify: `lib/scheduling/schedule_objective.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Test: `test/scheduling/day_allocation_test.dart`
- Test: `test/application/capacity_aware_week_planning_test.dart`
- Test: `test/scheduling/capacity_aware_week_golden_test.dart`

**Interfaces:**
- Consumes: `TaskDayCapacity`、`PreferenceSnapshot`、基线负载。
- Produces: 可退回的 `DayAllocationPlan` 和合法日内初始方案。

- [ ] **Step 1: 写任务稀缺度排序测试**

连续、可用日期少、截止紧的任务先分；同条件按优先级和稳定 ID。输入顺序打乱不变。

- [ ] **Step 2: 写周末自然胜出测试**

工作日负载高且周末空时使用周末；周末拥挤时不强行使用。删除一切固定 weekday/weekend 奖惩。

- [ ] **Step 3: 写软偏好不得删候选测试**

高精力窗口不足但其他时段合法时完整安排，并标记偏离偏好；学习偏好同理。

- [ ] **Step 4: 实现预算退回和重新分配**

日内失败将分钟和拒绝证据退回账本，重算剩余日期；不保留过期静态预算。

- [ ] **Step 5: 运行分配、周期、时区和 golden 回归**

- [ ] **Step 6: Commit**

`git commit -m "feat: allocate scarce work across real capacity"`

### Task 9: 接入有界交换搜索并区分无解

**Files:**
- Create: `lib/scheduling/bounded_repair_search.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/schedule_objective.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Test: `test/scheduling/bounded_repair_search_test.dart`
- Test: `test/scheduling/dynamic_reallocation_test.dart`

**Interfaces:**
- Consumes: 初始合法方案、未安排任务、`SearchBudget`、方案比较器。
- Produces: `RepairSearchResult`。

- [ ] **Step 1: 写需一次交换才有解的红灯**

贪心把灵活任务占进唯一长槽后，搜索搬走灵活任务并完整安排连续任务。

- [ ] **Step 2: 写失败回退边界**

搜索尝试产生非法中间状态或没有更好方案时返回原合法方案；原计划对象逐值不变。

- [ ] **Step 3: 写 hardInfeasible 与 budgetExhausted 对照**

同一类输入分别用充足状态预算和零/极小状态预算；前者穷尽确定性搜索图后证明无解，后者只能返回未决。两者预览文案和应用权限不同。测试禁止用真实运行毫秒数控制引擎停止点。

- [ ] **Step 4: 实现稳定状态签名与去重**

签名由排序后的块、剩余量、账本和调整状态生成，不含运行时对象 hash。每次弹出队列顺序固定。

- [ ] **Step 5: 删除或接通所有搜索参数**

全库搜索 `maxReallocationPasses` 等参数；每个保留参数必须有生产读取和边界测试，无法证明用途的删除。

- [ ] **Step 6: 运行专项与引擎回归**

- [ ] **Step 7: Commit**

`git commit -m "feat: add bounded deterministic repair search"`

### Task 10: 统一冻结 ID、少移动与块级延后

**Files:**
- Create: `lib/scheduling/frozen_block_policy.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/scheduling/local_repair.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/schedule_objective.dart`
- Test: `test/scheduling/frozen_block_policy_test.dart`
- Test: `test/scheduling/local_repair_cascade_test.dart`
- Test: `test/scheduling/choose_repair_plan_test.dart`

**Interfaces:**
- Consumes: 持久化基线块 ID、执行/锁定/钉住事实、调整请求。
- Produces: `computeFrozenBlockIds`、真实可匹配来源块和局部修复结果。

- [ ] **Step 1: 直接断言纯函数边界**

按规范 §6 覆盖六类冻结行为；空集合、重复 ID、目标不存在均有明确结果。

- [ ] **Step 2: 证明 ID 族相交**

未锁定基线块以持久 ID 进入 `existingBlocks/referenceBlocks`；提案使用新 ID 和 `continuedFromId`。测试断言少移动比较确实命中来源，而非两个永不相交的集合。

- [ ] **Step 3: 强制局部修复先于全局搜索**

注入计数器：局部成功时全局搜索调用数为0；局部失败时调用1次。延后失败后原计划不变。

- [ ] **Step 4: 写“不能靠删除躲过移动成本”测试**

删除后重建计入改变块数，并比原位复用更差。

- [ ] **Step 5: 运行所有延后、移动、来源和应用回归**

- [ ] **Step 6: Commit**

`git commit -m "fix: preserve confirmed block identity during repair"`

### Task 11: 生成临时延长日候选

**Files:**
- Create: `lib/scheduling/extension_day_policy.dart`
- Create: `lib/application/extension_day_service.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Test: `test/scheduling/extension_day_policy_test.dart`
- Test: `test/application/extension_day_service_test.dart`

**Interfaces:**
- Consumes: `hardInfeasible`/合法部分方案、任务诊断、日配额、睡眠规则、已有特殊日。
- Produces: 最多3个 `ExtensionDayCandidate` 和拒绝记忆键。

- [ ] **Step 1: 写提出条件测试**

正常可解或仅预算耗尽时不建议；证明硬约束缺口且延长可增加触发任务可落地容量时建议。

- [ ] **Step 2: 写睡眠与日期边界测试**

固定次日起床，默认绝对最低6小时；不跨任务截止；不连续延长；滚动7日0/1/2配额；同计划最多1次。

- [ ] **Step 3: 写候选排序和强制选择测试**

最多3个系统候选。用户自选日期/结束时间只要满足硬边界即可提交；不满足时返回具体字段错误，不能静默夹紧。

- [ ] **Step 4: 写拒绝去重测试**

相同 inputHash、候选参数和触发任务构成稳定键；拒绝后本次不再弹。任务、规则或计划变化使 inputHash 改变后可重新建议。

- [ ] **Step 5: Commit**

`git commit -m "feat: propose safe temporary extension days"`

### Task 12: 特殊日恢复选择与原子确认

**Files:**
- Create: `lib/domain/repositories/planning_commit_repository.dart`
- Modify: `lib/application/recovery_planning_service.dart`
- Modify: `lib/application/extension_day_service.dart`
- Modify: `lib/application/plan_application_service.dart`
- Modify: `lib/data/repositories/drift_plan_repository.dart`
- Modify: `lib/features/calendar/special_day/special_day_page.dart`
- Modify: `lib/main.dart`
- Test: `test/application/recovery_planning_service_test.dart`
- Test: `test/application/special_day_atomic_apply_test.dart`
- Test: `test/drift/planning_commit_repository_test.dart`

**Interfaces:**
- Consumes: 已选候选、`RecoveryCommitEffect`、当前输入重放和 `PlanningCommitRepository`。
- Produces: 四种真实不同恢复方案与全成全败确认；应用层不串联两个独立仓储写入。

- [ ] **Step 1: 写四分支红灯**

`nextDayRest` 创建保护块；`nextNightEarlierSleep` 只改次日晚睡眠开始；`reduceNextDayLoad` 降低次日可移动预算；`none` 不创建恢复项。四者不能走同一路径。

- [ ] **Step 2: 写固定起床测试**

当天延长不改变次日起床，也不把后续整周作息平移。

- [ ] **Step 3: 写取消次日任务语义测试**

只删除次日可移动计划块；任务、剩余分钟和原截止保留，未来重排不得越过原截止。

- [ ] **Step 4: 写事务注入失败测试**

分别在特殊日保存后、计划保存中、审计保存前注入异常；每次特殊日、计划版本、块和审计记录逐值不变。

- [ ] **Step 5: 收敛到唯一数据库事务**

让 `DriftPlanRepository` 同时实现 `PlanningCommitRepository`。普通 `applyProposal` 构造不带特殊日的 `PlanningCommitRequest` 并委托同一个内部事务；特殊日确认在同一个 `AppDatabase.transaction` 内完成：重放哈希复核、同日旧确认撤销、新特殊日确认、恢复保护事件或带来源标记的日期规则覆盖、旧计划 superseded、新计划与块写入、全部 `change_log`。`nextDayRest` 写保护事件，`nextNightEarlierSleep` 写次日日期规则覆盖，`reduceNextDayLoad` 写次日可移动负载上限，`none` 不写恢复效果；对应 `recoveryLocalDate` 保存在特殊日事实中供证据排除与撤销清理。禁止先调用 `DayExceptionRepository.save` 再调用 `PlanRepository.applyProposal`。任一步异常由 Drift 回滚整笔事务，通知同步只在提交成功后触发。

- [ ] **Step 6: 实现页面预览后确认**

打开页面不写设置。用户确认后调用一个应用服务；取消无写入。

- [ ] **Step 7: Commit**

`git commit -m "feat: apply special day recovery atomically"`

### Task 13: 结构化诊断、预览与操作入口

**Files:**
- Modify: `lib/scheduling/task_placement_diagnostics.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `lib/scheduling/explanations.dart`
- Modify: `lib/features/planning/plan_preview_issues.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `lib/features/settings/preferences/preferences_page.dart`
- Test: `test/app/algorithm20_preview_test.dart`
- Test: `test/features/settings/preferences_page_test.dart`

**Interfaces:**
- Consumes: 最终容量、拒绝证据、搜索状态、标题查找和扩展候选。
- Produces: 不含裸 ID 的任务行、原因、数字证据和操作链接。

- [ ] **Step 1: 写原因矩阵**

逐项覆盖容量、连续、开始、截止、星期、两类日上限、固定、保护、睡眠、课程过渡、锁定、休息、预算耗尽、结构异常、输入失效。

- [ ] **Step 2: 写标题与隐私测试**

有标题显示标题；标题丢失显示“未命名任务”；页面、语义树、异常和普通日志不含 UUID。

- [ ] **Step 3: 写建议卡交互测试**

预览加载不弹窗；点击建议卡才打开。拒绝记忆、候选选择、自定义合法时间、取消和确认分别覆盖。

- [ ] **Step 4: 写偏好进度与生效提示**

未达门槛显示计数；确认后提示“下次生成计划生效”，并提供明确的立即重新生成入口。

- [ ] **Step 5: 运行页面、路由、无障碍和截图尺寸回归**

- [ ] **Step 6: Commit**

`git commit -m "feat: explain algorithm 20 planning outcomes"`

### Task 14: 加固应用闸门、无解拦截与迁移审计

**Files:**
- Modify: `lib/scheduling/plan_validator.dart`
- Modify: `lib/scheduling/plan_quality_validator.dart`
- Modify: `lib/application/plan_application_service.dart`
- Modify: `lib/domain/repositories/planning_commit_repository.dart`
- Modify: `lib/data/repositories/drift_plan_repository.dart`
- Modify: `lib/application/input_snapshot_builder.dart`
- Test: `test/application/plan_application_service_test.dart`
- Test: `test/scheduling/plan_quality_validator_test.dart`
- Test: `test/drift/schema_v11_migration_test.dart`

**Interfaces:**
- Consumes: 完整提案状态、输入哈希、算法版本、特殊日、明确调整和最终块。
- Produces: 唯一应用判定和事务写入。

- [ ] **Step 1: 写状态准入表测试**

`feasible` 可正常应用；可解释 `hardInfeasible` 只在用户明确授权时部分应用；`budgetExhausted`、结构异常、过期输入、旧算法版本和未兑现调整全部拒绝。

- [ ] **Step 2: 写重放测试**

确认前重新装配输入。任务、规则、偏好、特殊日、基线块任一变化均改变哈希并拒绝旧提案。

- [ ] **Step 3: 写坏空档质量测试**

仅在完成度、截止、稳定性相同的方案之间选择坏空档较少者；不得把它变成硬冲突。

- [ ] **Step 4: 执行迁移与隐私扫描**

检查数据库/密钥产物未进入工作树，验证旧偏好按兼容规则读取，普通日志无个人数据。

- [ ] **Step 5: Commit**

`git commit -m "fix: gate algorithm 20 proposal application"`

### Task 15: 真实工作流、属性测试和性能预算

**Files:**
- Create: `test/application/algorithm20_real_workflow_test.dart`
- Create: `test/application/algorithm20_determinism_property_test.dart`
- Create: `test/scheduling/algorithm20_performance_test.dart`
- Modify: `docs/testing/algorithm20-acceptance.md`

**Interfaces:**
- Consumes: Task 2–14 完整生产链。
- Produces: 发布门禁所需的真实路径、确定性和性能证据。

- [ ] **Step 1: 写五条真实工作流**

覆盖：可见空闲但高精力不匹配仍排入；周末空闲自然分流；块延后局部修复；正常无解后确认临时延长日；学习偏好达标、确认并仅影响对应领域。

- [ ] **Step 2: 写属性测试**

固定种子生成合法输入；100次同输入相同，输入列表洗牌结果相同，所有输出过 validator，无块重叠、越界、超上限或重复分钟。

- [ ] **Step 3: 写性能基准**

七日普通夹具和 200任务/300基线块大型夹具各预热、运行固定次数，记录 p50/p95/最大值、机器与运行时。确定性状态预算耗尽路径保持 UI 可返回；另测界面墙钟看门狗只取消并丢弃计算结果，不产生可应用提案。

- [ ] **Step 4: 运行相关全套回归**

包括 schedule、application、preference、special day、plan preview、calendar、recurring、migration。

- [ ] **Step 5: Commit**

`git commit -m "test: verify algorithm 20 workflows and budgets"`

### Task 16: 全量门禁、算法版本 20 与黄金冻结

**Files:**
- Modify: `lib/scheduling/schedule_engine.dart`
- Create: `test/fixtures/scheduling/algorithm20_week.json`
- Create: `test/scheduling/algorithm20_golden_test.dart`
- Modify: 所有明确断言算法版本的测试
- Modify: `docs/testing/algorithm20-acceptance.md`

**Interfaces:**
- Consumes: Task 15 全绿证据和干净工作树。
- Produces: `algorithmVersion == '20'`、人工审阅后的黄金结果和最终交接。

- [ ] **Step 1: 最终全量验证，版本仍为19**

Run format、analyze、全部 tests、迁移 tests、性能 tests。任何失败先回到所属 Task 修复并重新过全套。

- [ ] **Step 2: 重新构建 Windows 应用并冒烟**

必须使用当前 HEAD 新构建。验证启动、生成计划、预览、偏好页、特殊日、延后和托盘基本路径；记录构建命令、产物哈希和实际结果。

- [ ] **Step 3: 只把算法版本升到20**

不得同时改产品版本。运行版本测试确认旧提案被拒绝。

- [ ] **Step 4: 生成并逐项审阅 golden**

审阅任务完成度、截止、工作日/周末负载、片段、坏空档、稳定性、原因和扩展候选；不能只因测试输出变化就接受。

- [ ] **Step 5: 再跑完整门禁**

记录实际测试总数、退出码、耗时、HEAD 和工作树状态。

- [ ] **Step 6: Commit**

`git commit -m "feat: release scheduling algorithm 20"`

## 5. 需求到证据追踪

具体到单项的可验证要求和主要证据位置见规范 §14。下面只汇总实现归属；实施者必须在 `docs/testing/algorithm20-acceptance.md` 为 ALG20-001–076 逐行填写实际测试函数全名、人工门禁记录、结果与提交哈希，不能只引用本表中的范围。

| 需求 | 任务 | 主要证据 |
| --- | --- | --- |
| ALG20-001–010 输入、时间与快照 | 1、2、6、14 | input snapshot、时区、准入、stale tests |
| ALG20-011–020 硬约束、形状容量与归因 | 7、13、14 | shape capacity、diagnostics、validator |
| ALG20-021–029 跨日、周末、软偏好与目标 | 8、14 | allocation、week planning、objective、golden |
| ALG20-030–039 搜索、身份、局部修复与回退 | 9、10 | bounded search、frozen IDs、local repair |
| ALG20-040–050 特殊日与延长候选 | 2、3、11、13 | migration、repository、extension、preview |
| ALG20-051–053 恢复与原子提交 | 12 | recovery、transaction injection |
| ALG20-054–067 学习证据、分析、状态与作用域 | 4、5、6、13 | evidence、analyzer v2、state machine、snapshot、UI |
| ALG20-068–073 诊断与应用闸门 | 13、14 | preview matrix、privacy、application gate |
| ALG20-074–076 迁移、隐私与发布 | 2、14、15、16 | migration、privacy、property、performance、acceptance |

## 6. 停止条件

出现以下任一情况立即停止当前 Task，保留证据，不进入下一 Task：

- 需要修改用户数据库或真实个人数据才能复现。
- 迁移会改写既有业务行，或无法证明回滚/预迁移备份有效。
- 为了通过测试需要放宽硬约束、隐藏缺口或删除既有回归。
- 排程结果依赖运行顺序、随机数、系统区域格式或未排序数据库结果。
- 特殊日与计划无法在同一数据库事务中原子提交。
- 有界搜索在大型夹具超过2秒且不能安全返回最佳合法方案。
- 学习指标缺少可解释输入，只能继续拿原始分钟冒充效果分。
- 同一 Task 出现超出本规范的新产品决策；先回到设计评审，不由实现者猜。

## 7. 完成定义

只有以下项目全部有实际证据时才能写“完成”：

- [ ] 需求 ALG20-001–076 每项映射到测试函数全名或人工门禁记录，且状态为 PASS。
- [ ] schema v11 从全部历史夹具升级通过，旧数据逐值保留。
- [ ] 五条真实工作流全部走生产装配和生产服务，不靠测试专用捷径。
- [ ] 偏好建议状态、领域作用域、样本门槛和特殊日排除都通过。
- [ ] 普通可行方案不建议临时延长日；真正无解时才提供候选。
- [ ] 一次晚睡不改变次日起床和后续长期作息。
- [ ] 块级延后失败保留原计划；普通重排少移动确实使用相交 ID 族。
- [ ] `hardInfeasible`、`budgetExhausted`、结构异常和输入过期在 UI 与应用层均不同。
- [ ] 26 条旧偏好测试和所有算法 19 回归继续通过，除非以新语义测试显式替换并记录理由。
- [ ] 格式、静态检查、全量测试、属性、性能、golden、Windows 新构建全部通过。
- [ ] `algorithmVersion == '20'`，产品版本未被擅自修改。
- [ ] 验收文件没有空白状态，没有把未运行项目写成 PASS。
- [ ] 最终工作树只含计划内文件，无数据库、密钥、构建缓存或个人数据。

## 8. 实施记录格式

每个 Task 完成后在 `docs/testing/algorithm20-acceptance.md` 追加：

```text
Task:
Commit:
Before failure:
Files changed:
Commands:
Exit codes:
Tests passed / failed:
Plan deviations:
Privacy/data impact:
Remaining limitations:
Status: PASS | FAIL | BLOCKED | NOT RUN
```

没有提交哈希、命令输出或测试数的 Task 不算完成。
