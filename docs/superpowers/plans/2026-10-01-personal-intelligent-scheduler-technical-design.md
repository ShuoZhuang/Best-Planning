# 个人智能日程规划软件技术设计与实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个本地优先、可解释、可恢复的 Windows 智能日程程序，并保留通过同一 Flutter 代码库扩展 Android/iOS 的能力。

**Architecture:** 使用单一 Flutter 应用和按功能划分的模块结构；排程核心是无 Flutter 依赖的纯 Dart 模块，数据库、系统通知和文件系统通过端口接口接入。SQLite/Drift 保存事实数据和版本化计划，任何重新排程先生成不可变提案，确认后才以事务替换当前计划。

**Tech Stack:** Flutter stable（最低 3.38.1，实施时使用并锁定当期 stable）、Dart、Riverpod、go_router、Drift/SQLite、timezone、uuid、flutter_local_notifications、fl_chart、flutter_test、fake_async、integration_test、MSIX。

**Spec:** `docs/superpowers/specs/2026-10-01-personal-intelligent-scheduling-design.md`

## Global Constraints

- 首发平台为 Windows 10/11 x64，产物包含可执行程序和 MSIX 安装包。
- 运行时不要求账号、网络、云端服务或在线 AI。
- 睡眠、用餐、固定休息、固定日程、锁定时间块、连续任务及每日任务上限属于硬约束。
- 默认详细规划未来 7 天，同时评估全部未完成任务的远期截止压力。
- 时间计算使用 5 分钟粒度；持久化瞬时时间使用 UTC 微秒，重复规则保留本地墙上时间和 IANA 时区标识。
- 默认先显示调整预览；只有用户开启“信任自动调整”后才可直接应用可行提案。
- 用户主动设置优先于确认后的学习偏好，学习偏好优先于产品默认值。
- 学习模块只能更新软约束；硬约束只能由用户明确修改或单次放宽。
- 所有核心写入使用事务；计算失败、保存失败或取消操作时保留当前已确认计划。
- `pubspec.lock`、Drift schema 快照和数据库迁移测试必须提交版本控制。
- 面向用户的中文文案保持中性，不因休息、娱乐、延期或中断进行羞辱和惩罚。

## Review Focus

- 夏令时、跨午夜和系统时区改变：固定事项与重复事项必须保持用户预期的本地时间，不产生重复或遗漏时间块；由 Task 5 的边界测试固定。
- 总需求时长大于可用时间：必须返回结构化冲突和缺口分钟数，不能给出违反硬约束的“成功”计划；由 Task 8 的不可行提案测试固定。
- 计算完成前数据再次改变：过期提案必须因输入快照哈希不匹配而拒绝应用；由 Task 9 的并发版本测试固定。
- 计时中崩溃或系统时钟跳变：恢复时要求用户确认真实结束时间，不能直接把异常间隔算作实际投入；由 Task 12 的恢复测试固定。
- 损坏、截断或来自新版本的备份：必须在临时位置验证并拒绝覆盖当前数据库；由 Task 16 的恢复测试固定。

---

## 1. 技术选择

### 1.1 为什么选择 Flutter

Flutter 官方支持从同一代码库构建 Windows、Android 和 iOS 应用，并可生成 Windows 原生桌面产物。该能力直接匹配“Windows 首发、未来手机 App”的产品路线。首版不拆分桌面端和移动端两个前端工程，避免提前承担双技术栈成本。

备选方案及未选择原因：

- Tauri + React + Rust：体积小且桌面能力强，但会引入 TypeScript/Rust 双语言边界，首版排程、数据库和 UI 联调成本更高。
- .NET MAUI：Windows 集成好，但未来移动端与跨平台组件选择更受 .NET 生态约束。
- Electron：开发便利，但对本地单用户工具而言运行体积和内存开销不占优势。

技术依据：

- Flutter 支持平台：https://docs.flutter.dev/reference/supported-platforms
- Flutter 桌面支持与 Windows 构建：https://docs.flutter.dev/platform-integration/desktop
- Flutter Windows 发布方式：https://docs.flutter.dev/platform-integration/windows/building
- Drift 事务：https://drift.simonbinder.eu/dart_api/transactions/
- Drift 迁移与测试：https://drift.simonbinder.eu/migrations/
- Drift 后台 isolate：https://drift.simonbinder.eu/isolates/
- Windows 本地通知限制：https://pub.dev/packages/flutter_local_notifications

### 1.2 依赖策略

- 使用 Flutter stable；项目创建时记录 `flutter --version`，并在升级前通过完整测试和数据库迁移测试。
- 应用项目提交 `pubspec.lock`，确保安装包构建可复现。
- 依赖只解决明确需求；不得为了“以后可能用到”引入网络、遥测、机器学习或云 SDK。
- 排程算法不依赖平台插件，确保可通过 `flutter test` 在内存中快速验证。
- Riverpod 只管理运行时状态和依赖注入；数据库仍是唯一事实来源，不使用实验性离线状态持久化替代 Drift。

## 2. 总体结构

```mermaid
flowchart TB
    UI[Flutter 页面与组件] --> APP[应用服务 / Riverpod Notifier]
    APP --> DOMAIN[领域规则与用例]
    APP --> PORTS[Repository 与平台端口]
    DOMAIN --> ENGINE[纯 Dart 排程引擎]
    PORTS --> DB[Drift / SQLite]
    PORTS --> WIN[Windows 通知、文件、凭据适配器]
    ENGINE --> PROPOSAL[不可变 ScheduleProposal]
    PROPOSAL --> APP
    APP --> PREVIEW[调整预览]
    PREVIEW -->|确认| DB
```

### 2.1 模块边界

| 模块 | 职责 | 禁止依赖 |
| --- | --- | --- |
| `domain` | 实体、值对象、枚举、业务错误和 repository 接口 | Flutter、Drift、平台插件 |
| `scheduling` | 可用时间、压力计算、候选生成、评分、验证、解释和计划 diff | Flutter、Drift、平台插件 |
| `data` | Drift 表、DAO、迁移、repository 实现和事务 | 页面组件 |
| `application` | 用例编排、提案生命周期、计时恢复、备份和通知协调 | 具体页面布局 |
| `features/*` | 页面、组件、表单和 Riverpod 状态 | 直接 SQL、排程内部实现 |
| `platform` | Windows 通知、文件、开机恢复和应用锁适配器 | 业务决策 |

### 2.2 目录结构

```text
personal_planner/
├── pubspec.yaml
├── analysis_options.yaml
├── build.yaml
├── lib/
│   ├── main.dart
│   ├── app/
│   │   ├── planner_app.dart
│   │   └── router.dart
│   ├── core/
│   │   ├── clock.dart
│   │   ├── ids.dart
│   │   ├── result.dart
│   │   └── time_zone.dart
│   ├── domain/
│   │   ├── models/
│   │   ├── repositories/
│   │   └── services/
│   ├── scheduling/
│   │   ├── schedule_engine.dart
│   │   ├── schedule_problem.dart
│   │   ├── schedule_proposal.dart
│   │   ├── availability_builder.dart
│   │   ├── pressure_calculator.dart
│   │   ├── candidate_generator.dart
│   │   ├── candidate_scorer.dart
│   │   ├── plan_validator.dart
│   │   ├── plan_differ.dart
│   │   └── explanations.dart
│   ├── data/
│   │   ├── database/
│   │   │   ├── app_database.dart
│   │   │   ├── tables/
│   │   │   └── daos/
│   │   └── repositories/
│   ├── application/
│   │   ├── planning_service.dart
│   │   ├── plan_application_service.dart
│   │   ├── focus_service.dart
│   │   ├── analytics_service.dart
│   │   ├── preference_service.dart
│   │   └── backup_service.dart
│   ├── platform/
│   │   ├── notifications/
│   │   ├── files/
│   │   └── app_lock/
│   └── features/
│       ├── onboarding/
│       ├── today/
│       ├── tasks/
│       ├── calendar/
│       ├── planning/
│       ├── focus/
│       ├── analytics/
│       └── settings/
├── test/
│   ├── domain/
│   ├── scheduling/
│   ├── data/
│   ├── application/
│   ├── features/
│   └── fixtures/
├── integration_test/
├── drift_schemas/
└── windows/
```

目录结构说明：

- `lib/app/providers.dart` 从未创建：Riverpod 状态目前由各页面自行组织，依赖注入集中在 `main.dart` 与 `PlannerApp` 构造参数，本计划不再要求该文件。若后续需要集中 provider 定义，应作为独立任务引入。
- 迁移入口在 `lib/data/database/app_database.dart` 的 `AppDatabase.migration`，drift 生成的逐版本步骤助手在 `lib/data/database/app_database.steps.dart`：当前 schemaVersion 为 3：v1→v2 新增标签两表、任务期望时段两列、领域 `is_life` 列，并回填历史行时间戳；v1→v3 再建剩余时长修正记录表。schema 快照在 `drift_schemas/app_database/`（v1–v3），迁移测试在 `test/drift/app_database/schema_migration_test.dart`，覆盖全部版本组合（v1→v2、v1→v3、v2→v3），并对 v1→v3 做数据完整性验证。后续每次改表都按 §4.2 的流程提升版本、导出快照并补迁移测试。
- `integration_test/` 属于 Task 20 交付物，当前不存在。

## 3. 核心领域接口

以下接口名和字段名是后续实现的稳定边界。UI、数据库和排程模块不得各自定义一套同义模型。

```dart
typedef EntityId = String;
typedef Minutes = int;

abstract interface class Clock {
  DateTime nowUtc();
}

abstract interface class IdGenerator {
  EntityId next();
}

abstract interface class TaskRepository {
  Stream<List<PlannerTask>> watchOpenTasks();
  Future<PlannerTask?> getById(EntityId id);
  Future<void> save(PlannerTask task);
}

abstract interface class CalendarRepository {
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  );
  Future<void> save(CalendarEvent event);
}

abstract interface class PlanRepository {
  Future<ConfirmedPlan?> current();
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  );
}

abstract interface class ScheduleEngine {
  ScheduleProposal generate(ScheduleProblem problem);
}
```

关键值对象：

- `TimeRange(startUtc, endUtc)`：半开区间 `[start, end)`，结束必须晚于开始。
- `LocalTimeRange(startMinute, endMinute)`：0–1440 分钟；跨午夜规则拆成两个日期片段。
- `PlanningRules`：睡眠、用餐、休息、每日上限、周末规则、生活配额和 5 分钟粒度。
- `TaskConstraints`：允许拆分、最短/最长片段、必须连续、期望时段和脑力强度。
- `InputSnapshot`：任务、日程、设置和当前计划的规范化 JSON 计算 SHA-256，形成 `inputHash`。
- `ScheduleProposal`：只读结果；包含 `blocks`、`unscheduled`、`conflicts`、`explanations`、`inputHash` 和 `algorithmVersion`。

## 4. 数据模型

### 4.1 表结构

| 表 | 关键字段 | 说明 |
| --- | --- | --- |
| `areas` | `id`, `name`, `color`, `sort_order`, `is_life`, `created_at_utc`, `updated_at_utc` | 学业、科研、生活等领域，可自定义。`is_life` 标记生活领域；任务是否算生活任务由项目归属推导，不单独存字段。 |
| `projects` | `id`, `area_id`, `name`, `archived_at_utc`, `created_at_utc`, `updated_at_utc` | 项目归属领域。 |
| `tasks` | `id`, `project_id`, `title`, `notes`, `priority`, `estimated_minutes`, `remaining_minutes`, `due_at_utc`, `energy_level`, `split_mode`, `min_chunk_minutes`, `max_chunk_minutes`, `preferred_start_minute`, `preferred_end_minute`, `status`, `created_at_utc`, `updated_at_utc` | 任务事实数据，不直接保存派生日程。期望时段是可空的本地分钟区间，为空表示无偏好。 |
| `tags` | `id`, `name`, `created_at_utc`, `updated_at_utc` | 自定义标签（FR-TASK-02）。独立成表而非任务上的文本列，以便按标签精确筛选与统计，不做子串匹配。 |
| `task_tags` | `task_id`, `tag_id`, `created_at_utc` | 任务与标签的关联。复合主键即行标识；关联只会创建或删除，不会改写，故只记创建时间。 |
| `calendar_events` | `id`, `title`, `start_at_utc`, `end_at_utc`, `time_zone_id`, `recurrence_rule_id`, `exception_of_id`, `locked`, `area_id`, `created_at_utc`, `updated_at_utc` | 一次性事件和重复事件实例例外。 |
| `recurrence_rules` | `id`, `weekdays_mask`, `local_start_minute`, `duration_minutes`, `valid_from_local_date`, `valid_until_local_date`, `time_zone_id`, `created_at_utc`, `updated_at_utc` | 首版只实现按周重复。 |
| `energy_windows` | `id`, `day_kind`, `start_minute`, `end_minute`, `energy_level`, `source`, `created_at_utc`, `updated_at_utc` | 工作日、周末或指定日期精力段。 |
| `settings` | `key`, `json_value`, `created_at_utc`, `updated_at_utc` | 带 schema 的设置值；不保存无法验证的任意对象。改写同一键时保留创建时间，只推进修改时间。 |
| `plan_versions` | `id`, `created_at_utc`, `input_hash`, `algorithm_version`, `status`, `summary_json` | 已确认、已被替代和已撤销的持久化计划版本；未确认提案只保存在内存。 |
| `schedule_blocks` | `id`, `plan_version_id`, `task_id`, `start_at_utc`, `end_at_utc`, `locked`, `explanation_code`, `created_at_utc`, `updated_at_utc` | 每个计划版本的任务块。 |
| `time_entries` | `id`, `task_id`, `started_at_utc`, `ended_at_utc`, `paused_minutes`, `source`, `recovery_state`, `created_at_utc`, `updated_at_utc` | 实际投入；未确认恢复记录不计入统计。专注计时期间反复保存不得重置创建时间。 |
| `task_corrections` | `id`, `task_id`, `previous_minutes`, `corrected_minutes`, `corrected_at_utc` | 剩余时长修正历史（FR-TASK-05）。保留修正前后两个值而不是只存结果，因为统计要看的正是每次修正的幅度与方向。记录不可变，故只记创建时刻。 |
| `preference_evidence` | `id`, `kind`, `subject_key`, `observed_at_utc`, `numeric_value`, `special_day`, `metadata_json` | 原始偏好证据，可追溯。 |
| `preference_rules` | `id`, `kind`, `subject_key`, `value_json`, `confidence`, `status`, `source`, `updated_at_utc` | 建议、已确认、自动采用、停用状态。 |
| `change_log` | `id`, `entity_type`, `entity_id`, `operation`, `changed_at_utc`, `revision` | 为撤销、诊断和未来同步保留最小变更历史。 |

### 4.2 数据约束

- 所有实体 ID 使用 UUID v4 字符串；未来同步不依赖数据库自增 ID。
- `estimated_minutes`、`remaining_minutes` 和片段长度必须是正整数，且按 5 分钟向上取整用于排程；原始输入仍保留。
- `due_at_utc` 可为空；没有截止日期的任务由优先级、生活配额和用户期望时段参与排序。
- `schedule_blocks` 必须引用存在的 `plan_versions` 和 `tasks`，外键在每次连接打开时启用。
- 删除任务默认采用状态转换而非物理删除；永久清除数据除外。
- 日期实例使用 UTC；重复规则使用本地日期、墙上时间和时区 ID，展开后生成 UTC occurrence。
- 所有时间戳列都是微秒为单位的 UTC 整数（`microsecondsSinceEpoch`），全库统一，不混用毫秒。
- 新增的 `NOT NULL` 时间戳列带哨兵默认值 0：SQLite 不允许对已有数据的表直接 `ADD COLUMN ... NOT NULL` 而不给默认值，因此迁移先加列、再把历史行回填为迁移时刻。哨兵 0 的含义是"尚未设置"，仓库层必须在写入时给出真实值。
- 每条核心数据都包含唯一标识、创建时间和修改时间（FR-DATA-08）。改写既有记录只推进修改时间，创建时间保持首次写入的值；`plan_versions`、`preference_evidence`、`change_log` 是不可变记录，各自只有创建时刻。
- Drift schema 每次变化都提高 `schemaVersion`、导出 schema 快照并运行生成的迁移测试（当前 schemaVersion 为 3）。

## 5. 排程引擎设计

### 5.1 输入与输出

```dart
final class ScheduleProblem {
  final DateTime planningStartUtc;
  final DateTime planningEndUtc;
  final String timeZoneId;
  final List<SchedulableTask> tasks;
  final List<BusyInterval> fixedIntervals;
  final List<BusyInterval> protectedIntervals;
  final List<PlannedBlock> lockedBlocks;
  final PlanningRules rules;
  final PreferenceProfile preferences;
  final String inputHash;
}

final class ScheduleProposal {
  final String proposalId;
  final String inputHash;
  final String algorithmVersion;
  final List<PlannedBlock> blocks;
  final List<UnscheduledTask> unscheduled;
  final List<PlanningConflict> conflicts;
  final List<PlanExplanation> explanations;
  final ProposalMetrics metrics;
}
```

`ScheduleEngine.generate` 是纯函数：不读数据库、不调用当前时间、不产生随机结果。当前时间和 ID 在应用层注入。

候选排序的完整顺序（与 `schedule_engine.dart` 的 `_compareRankedCandidates` 一致）：`coverageMinutes` 降序 → 软约束总分降序 → `startUtc` 升序 → `taskId` → 候选 ID。最后三项构成最终平局键，保证相同输入产生相同输出。

> **已解决（算法版本 5）**：本节原先只声明了最后三项平局键，遗漏了前两个实质排序键；更重要的是排序首键曾是 `coverageMinutes`（一次能覆盖多少目标时长），与 5.2 第 7 步"选择**最高分**候选"冲突。按"实现以需求文档为准"的原则，现在以软约束总分为首键，覆盖度退为同分时的次级依据。实测该改动不改变 golden 周的输出（该场景中评分顺序与覆盖度顺序恰好一致），但它会在"覆盖度与评分不一致"的输入上改变结果，因此算法版本提升为 5。

### 5.2 处理管线

1. **规范化**：校验输入，按 5 分钟粒度标准化可调度时长，合并重叠的忙碌区间。
2. **构造可用时间**：从 7 个本地日中扣除固定事件、保护时间和锁定时间块，再按每日上限裁剪。
3. **远期压力**：对全部开放任务估算截止日前容量；计算“七日内必须完成量”和“均匀推进量”。
4. **任务排序**：先按不可行风险和有效松弛时间，再按用户优先级、可用候选数量和稳定 ID 排序。
5. **候选生成**：按任务拆分规则，在可用区间中以 5 分钟步长生成候选时间块。与已排片段在 `Rules.breakMinutes` 以内相邻的候选位置在分配与局部改进阶段都被排除——该规则作用于**任意两个任务块之间，不区分任务类型**（参见 13.0.7 的 C1 决策）。连续任务与另一任务相邻时同样需要休息。算法版本 4 起生效。
6. **候选评分**：对精力匹配、期望时段、连续性、生活配额、切换成本、碎片化和移动成本计分。
7. **初始分配**：选择**软约束总分最高**且不破坏硬约束的候选；总分相同时按覆盖度、开始时间、任务 ID、候选 ID 依次决胜。算法版本 5 起排序与此一致（此前首键为覆盖度）。
8. **局部改进**：限定次数地尝试交换或移动两个可移动块，只接受总分提高且仍通过验证的结果。
9. **最终验证**：重新验证重叠、硬约束、片段总量、每日上限和生活配额。
10. **差异与解释**：与当前计划比较，生成新增、移动、拆分、删除、逾期和冲突说明。

### 5.3 远期压力

对截止日期在规划窗口之外的任务：

- `requiredNow = max(0, remaining - estimatedCapacityAfterHorizonBeforeDue)`；
- `pacedNow = ceil(remaining * horizonCapacity / estimatedCapacityUntilDue)`；
- 七日目标为 `max(requiredNow, pacedNow)`，但不得超过任务剩余时长。

目标大于零但小于最小可排片段时，会抬到**确实可排的最小量**（可拆分任务为最小片段，连续任务为整块），否则均匀推进量会因为没有这么短的片段而完全落空——这正是"远端任务整周排入 0 分钟"的成因。算法版本 6 起如此。对应地，不可拆分任务的取舍是"要么整体排入、要么一个也排不进"。

未来容量根据已知重复日程、长期保护规则、工作日/周末上限估算；一次性未来固定事项存在时必须扣除。截止日期超过 180 天时，以未来 180 天容量和周均推进量估算，避免无界展开重复日程。

### 5.4 评分

排程的决策实际分两级，评分只作用于第二级：

1. **任务级排序**（决定先排哪个任务）：由 `_compareTasks` 完成，依次比较有效松弛时间（截止前可用容量 − 目标分钟数）、用户优先级、截止时间、稳定 ID。紧迫度由第一条以梯度方式决定，而不是靠评分表。
2. **候选级排序**（在同一任务的候选位置之间选择）：先按**软约束总分**降序（设计 §5.2 第 7 步），总分相同时按 `coverageMinutes`（该候选及其后的可续排容量）降序，最后以开始时间、任务 ID、候选 ID 平局决胜，保证可复现。算法版本 5 起如此。

因此**评分表只在第二级生效**，且只比较同一任务的候选。凡是在该任务上恒定的因子都不参与选择。当前实现中各因子的实际作用范围如下：

| 因素 | 权重范围 | 当前实际作用 |
| --- | --- | --- |
| 截止与负松弛风险 | 0 至 +3000 | **不生效**：`deadlineRiskPermille` 只按"有无截止日期"取 0/1000，对同一任务的所有候选都是同一个值。紧迫度改由第 1 级的有效松弛时间承担。 |
| 用户优先级 | 0 至 +1500 | **不生效**：同上，任务级常量；优先级在第 1 级作为次级键生效。 |
| 远期均匀推进 | 0 至 +500 | **不生效**：同上，任务级常量。 |
| 精力匹配 | -800 至 +800 | 生效：随时段能量变化，是候选间的主要区分项之一。 |
| 用户期望时段 | -300 至 +500 | **已注入**（提交 `fb3eb06`，算法版本 9）：按候选落在期望时段内的时长占比在区间内线性插值；没有偏好取 0，表达了偏好却落空取 -300。实现见 `preferred_time_scorer.dart`。 |
| 生活娱乐配额缺口 | 0 至 +1000 | **不生效**：同一轮迭代内 `plannedLifeMinutes` 相同，为任务级常量。 |
| 同任务连续性 | 0 至 +400 | 生效：候选所在**本地日**内已有同一任务的片段时计入（算法版本 7 起）。连续性约束"落在哪一天"，与片段间休息约束"间隔多长"互不冲突。 |
| 类别切换 | 0 至 -300 | 生效：候选在时间上紧邻的前一个或后一个片段属于其它任务、且在同一本地日内时计入（算法版本 7 起）。"紧邻"指中间没有其它片段的那个，不引入额外时间阈值。 |
| 过度碎片化 | 0 至 -600 | 生效：随片段长度变化。 |
| 移动已确认但未锁定的时间块 | 0 至 -700 | 生效：`ScheduleProblem.existingBlocks` 承载"已确认但未锁定"的块；候选与某次确认**完全一致**时不计代价，否则计一次移动（部分重叠算冲突而非保留；占用其它任务的确认位置也算移动）。算法版本 8 起。 |

判定"是否生效"的方法可复现：对同一任务的两个不同候选调用 `CandidateScorer`，在时段能量等级相同时，未生效的因子取值完全相同（见 §13.0.7 的实测记录与 C2）。

任何高分都不能突破硬约束。每个解释使用稳定的 `explanationCode` 和参数生成中文文案，不把不可测试的自由文本写入引擎。

**软约束注入状态**：候选层面的十个因子现已全部由引擎实际设置，不再有"恒为 0"的因子——最后一项用户期望时段随 schema v2 与提交 `fb3eb06` 落地。但仍须注意两点，否则容易高估兑现程度：① 该字段目前**没有任何界面写入方**（见 R5），因此真实数据中它恒为"无偏好"，因子只在其它写入方设置后才会生效；② 八个任务级因子在同一任务的候选之间恒为常数，要让它们真正影响决策必须把任务排序也纳入评分（见 C2）。

### 5.5 冲突模型

```dart
enum ConflictCode {
  insufficientCapacity,
  fixedEventOverlap,
  protectedTimeOverlap,
  lockedBlockMoved,
  blockOverlap,
  continuousBlockUnavailable,
  dailyLimitExceeded,
  scheduledDurationExceeded,
  minimumSleepConflict,
  staleProposal,
  invalidInput,
}

final class PlanningConflict {
  final ConflictCode code;
  final EntityId? taskId;
  final Minutes shortageMinutes;
  final List<EntityId> relatedEntityIds;
  final Map<String, Object?> details;
}
```

不可行计划仍返回 `ScheduleProposal`，但 `metrics.isFullyFeasible` 为 `false`，并为每个未安排任务提供缺口分钟数和可选处理动作。引擎绝不自行修改原始截止时间、预计时长或硬约束。

## 6. 提案、确认与并发一致性

```mermaid
sequenceDiagram
    participant UI as 调整预览
    participant PS as PlanningService
    participant E as ScheduleEngine
    participant DB as Drift
    UI->>PS: createProposal()
    PS->>DB: load snapshot
    PS->>E: generate(problem + inputHash)
    E-->>PS: immutable proposal
    PS-->>UI: diff + explanations
    UI->>PS: apply(proposalId)
    PS->>DB: recompute current inputHash
    alt hash matches
      DB->>DB: transaction: version + blocks + log
      DB-->>UI: applied
    else stale
      DB-->>UI: staleProposal; request recalculation
    end
```

- 提案在应用前不替换当前计划。
- 用户编辑任何排程输入后，旧提案仍可查看，但不能应用。
- 开启自动调整时也必须执行哈希检查、完整验证和事务写入。
- 每次成功应用创建新的 `plan_versions` 记录；保留上一已确认版本用于撤销。
- 计划版本只保存必要快照摘要和块，不复制任务全文。

## 7. 偏好学习设计

首版不训练黑盒模型，使用可解释的统计规则：

- 完成一次专注，记录任务领域、脑力强度、计划/实际时段、计划/实际长度、完成状态和是否特殊日。
- 手动移动任务，记录原时段、新时段和移动方向。
- 接受、修改或拒绝提案，记录解释代码和用户动作。
- 特殊日、生病、考试周和明确标记的异常记录不参与长期偏好计算。

生成建议的最低门槛：相关领域至少 20 个有效完成记录，覆盖至少 14 个活跃日期；或同一种手动调整在非特殊日出现至少 5 次。时段效果差异低于 15% 时不生成“更适合”结论。

```dart
abstract interface class PreferenceAnalyzer {
  List<PreferenceSuggestion> analyze(
    List<PreferenceEvidence> evidence,
    PreferenceProfile current,
  );
}
```

建议包含证据数量、观察时间范围、效果差异、建议值和预计影响。默认状态是 `suggested`；用户确认后变为 `confirmed`。开启自动采用时只能把达到同一门槛的软偏好变为 `autoApplied`，并写入变更历史以便撤销。

## 8. 统计设计

统计数据直接来自任务、计划块和已确认实际时间记录：

- 计划时长：所选范围内已确认计划块与范围的交集分钟数。
- 实际时长：所选范围内已确认 `time_entries` 的有效分钟数。
- 完成率：范围内到期或完成任务中已完成数量占比；界面必须显示分母。
- 按期完成率：完成时间不晚于截止时间的已完成任务占比。
- 预估偏差：`(实际 - 预计) / 预计`，预计为零或数据缺失时不计算。
- 生活配额：生活娱乐实际或计划分钟数与目标分钟数分别展示，不互相冒充。

首版使用 Drift 聚合查询按需计算，不提前建立复杂数据仓库。只有性能测试证明跨一年查询不能满足交互要求时，才增加可重建的日汇总缓存。

## 9. 计时、恢复与系统时间

- 计时开始后立即保存 `startedAtUtc` 和 `recoveryState=running`。
- 暂停和继续都持久化累计暂停分钟及最后状态时间。
- 正常结束写入 `endedAtUtc` 和 `recoveryState=confirmed`。
- 程序启动发现 `running` 记录时，不自动把整个离线间隔计入实际时间；显示恢复对话框让用户确认结束时间或丢弃异常部分。
- `Clock` 同时提供 UTC 墙上时间和单调计时来源；单次运行中的持续时长优先使用单调时钟，落库时再转换为 UTC 边界。
- 检测到系统时间向前或向后跳变超过 5 分钟时暂停自动结束计算并要求确认。

## 10. 通知设计

- 只预排未来 7 天的一次性 Windows 通知，不使用 Windows 不支持的重复通知接口。
- 每次计划确认后，比较通知计划并重新安排受影响的一次性通知。
- MSIX 作为正式安装方式，以获得 Windows 包身份和可靠的通知取消/查询能力。
- 通知 payload 只包含实体 ID 和动作，不包含任务备注等敏感内容。
- 睡眠免打扰期间推迟普通通知；固定事件冲突等需要用户处理的提醒在下次允许时段汇总显示。

## 11. 备份、恢复与应用锁

### 11.1 备份

备份格式为带版本的 ZIP：

```text
backup.zip
├── manifest.json
├── planner.sqlite
└── exports/settings.json
```

`manifest.json` 包含格式版本、数据库 schema 版本、应用版本、创建时间、文件长度和 SHA-256。创建备份前执行 WAL checkpoint，并在禁止写入的短事务窗口中生成一致快照。

### 11.2 恢复

恢复流程先解压到应用专用临时目录，验证路径安全、manifest、哈希、SQLite integrity check 和 schema 兼容性。验证通过后关闭数据库，把当前数据库移动为可恢复副本，再原子替换并重新打开。任何一步失败都恢复原数据库。

### 11.3 应用锁

首版应用锁只阻止通过正常 UI 打开程序，不宣称数据库加密。密码使用 `PBKDF2-HMAC-SHA256` 保存验证值，每次安装生成独立随机盐，迭代次数固定为 600,000；数据库中不保存明文密码。连续失败采用递增等待，不提供不可恢复的数据加密承诺。

## 12. UI 与状态管理

- 每个 feature 对外暴露一个页面入口和少量 provider；页面不直接访问 DAO。
- 表单状态与持久化状态分开，取消编辑不会污染数据库。
- 长时排程在独立 Dart isolate 中运行，提供取消 token；取消不保存半成品。
- 所有页面覆盖 loading、empty、content、recoverable error 四种状态。
- 周视图使用虚拟化或裁剪绘制，固定日程、保护时间、任务块和生活时间使用不同纹理或图标，不能只依赖颜色区分。
- 调整预览按“新增、移动、拆分、移除、冲突”分组，可展开查看原因；确认按钮在提案过期后禁用。

主要路由：

```text
/onboarding              未接线：页面已存在，但未加入路由表，首启门控未生效
/today                   已实现，但注入 EmptyScheduleViewSource，恒显示空日程
/tasks                   已接线（真实 TaskService + Drift 仓储）
/tasks/:id               未实现（无任务详情路由）
/calendar                已实现，但注入 EmptyScheduleViewSource 与 DisabledWeekMoveController
/planning/preview/:proposalId  已实现，但硬编码空 changes/conflicts、isStale=true、onConfirm 为空
/focus/:taskId           未接线（页面已存在，无路由）
/analytics               未接线（页面已存在，无路由）
/settings                已接线（PlanningRulesPage）
/settings/preferences    未接线（页面已存在，无路由）
/settings/data           未接线（页面已存在，无路由）
```

`/today`、`/calendar`、`/planning/preview/:proposalId` 的空桩状态是当前产品不可用的直接原因，已登记在 §13.0，属于接线任务（见 §13.0 的 W1–W5）。

## 13. 分阶段实施

由于完整需求包含多个可独立验收的子系统，实施分为三个发布增量：

1. **基础排程版**：Task 1–10。交付任务、固定日程、规则设置、七日排程、预览确认、今日页和周视图。
2. **可靠执行版**：Task 11–16。交付特殊日、恢复保护、计时、通知、备份、导出和应用锁。
3. **洞察个性化版**：Task 17–20。交付统计、正向反馈、偏好学习、完整验收和 Windows 发布包。

每个增量都必须能独立运行和测试；不得等到第三阶段才验证排程正确性或数据恢复。Task 10A 属于基础排程版。

### 13.0 实施状态与偏差登记（2026-10-02 复核）

#### 13.0.1 实施状态

| 范围 | 状态 | 证据 |
| --- | --- | --- |
| Task 1–19 | 已完成并提交 | 提交 `8b2838e..e15d243`；逐任务测试日志见 `.superpowers/sdd/2026-10-01-personal-intelligent-scheduler-technical-design/task-N-tests.log` |
| Task 10A | 已完成并提交 | 提交 `05ac22a` |
| Task 20 | **进行中** | 首次引导门控已生效（`7955037`）；`docs/testing/manual-windows-checklist.md` 与 `docs/release/windows-release.md` 已创建；`integration_test/` 下已有三条端到端流程并加入 SDK 自带的 `integration_test` 依赖（`bac1f7d`）；`msix` 依赖与 `msix_config` 已加入 `pubspec.yaml`，但 `dart run msix:create` 尚未执行、包标识仍为示例值；手工验收清单尚未执行 |

Task 1–19 的复选框已按上述证据勾选。每个 checkbox 只代表该任务自身步骤已执行且其测试通过，**不代表产品整体可用**。

#### 13.0.2 关键结论：任务级完成 ≠ 产品可用

复核发现生产装配层缺失：`DeterministicScheduleEngine`、`RecurrenceExpander`、`PlanningService`、`PlanApplicationService`、`RecoveryPlanningService`、`FocusService` 在 `lib/` 中从未被实例化（仅测试构造），且 `router.dart` 的今日页与周视图注入恒空数据源。因此 §17 原先声称的"已覆盖"并不能在运行期兑现。以下偏差按类别登记，编号供后续任务引用。

#### 13.0.3 接线缺失

| 编号 | 偏差 | 证据 |
| --- | --- | --- |
| W1 | 排程引擎与全部应用服务未在应用中构造；无生产用 `ScheduleProblemSource` | **已解决**（提交 `b0a1f69`、`7955037`）：生产用 `RepositoryScheduleProblemSource`、`ProtectedTimeExpander`、`PlanningRuleResolver` 与 `RepositoryScheduleViewSource` 均已实现；`main.dart` 作为组合根构造引擎、`PlanningService`、`PlanApplicationService` 并注入应用 |
| W2 | 今日页、周视图、调整预览为空桩 | **已解决**（提交 `7955037`）：今日页与周视图改为注入真实 `RepositoryScheduleViewSource`；预览页从内存提案构建真实的差异、冲突与缺口，确认时经 `PlanApplicationService` 落库并区分 applied/stale/invalid。拖动仍禁用属另一项缺口，见 R9 |
| W3 | 已实现页面无路由：首次引导、统计、专注、偏好设置、数据管理、特殊日、任务详情 | **部分解决**（提交 `7955037`）：新增计划生成入口与真实预览路由；首次引导已改为启动门控（不再是路由）。**现状已逐页核实**：`createPlannerRouter` 现有 8 条路由（`/today`、`/tasks`、`/tasks/:taskId`、`/calendar`、`/analytics`、`/preferences`、`/settings`、`/planning/preview/:proposalId`）；**已接通三处**——统计页、偏好页，以及本轮新增的**任务详情页**（`/tasks/:taskId`）。**登记口径修正**：本行原先把"任务详情"与其它项并列成"已实现页面无路由"，但实际上**该页面根本不存在**，属"页面缺失"而非"路由缺失"，因此它不是补一条路由能解决的；本轮新建页 `features/tasks/task_detail_page.dart`，它同时是通知 payload 里 `route` 的落点（R8 的快捷入口）与 FR-TASK-05 修正剩余时长的界面入口（R9）。统计与偏好两页在组合根构造、经 `PlannerApp` 注入，各有路由可达性测试；任务详情页由路由器直接构造，另有四个 widget 测试覆盖事实展示、修正写历史、非正值被拒与任务不存在。**仍无任何路由可达的页面只剩一页**——`features/settings/data/backup_page.dart`（`export_page.dart`、`app_lock_page.dart`、`focus_page.dart`、`special_day_page.dart` 已分别由提交 `f62ed50`、`cf542d8`、`e95d839`、`226ff8f` 接通，各有路由可达性测试；专注页的入口挂在任务详情页、特殊日页的入口挂在外壳顶栏，因此**没有**新增侧边导航项）。**路由现为 13 条，侧边导航回到 6 项**（提交 `41b4873`：设置类页面收进 `/settings` 入口页，规划规则移到 `/settings/rules`、偏好移到 `/settings/preferences`，导航栏只保留今日/任务/领域/日历/统计/设置；**这一点即本节"信息架构提醒"的落地**，此后新增设置页不再占用导航项）。**入口页只列出已装配的子页**——未装配时不留"点了才知道没装"的入口，因此原先三处"未装配时说明原因"的用例改为断言该入口不出现；路由本身不变，直接经 URL 到达时仍会说明原因。**另一处遗留已解决**：任务清单已通过每行对侧的详情入口链接到详情页（`CheckboxListTile` 没有 `trailing`，勾选框本身占着那侧，因此入口放在 `secondary`，既与"点整行即完成"不冲突，也没改掉既有行为），并有 widget 测试覆盖"从清单进入详情"`features/settings/data/backup_page.dart`、`features/settings/app_lock/app_lock_page.dart`、`features/calendar/special_day/special_day_page.dart`。**每条都需要把新依赖从 `main.dart` 经 `PlannerApp` 穿到 `createPlannerRouter` 再进入路由构建器**（统计页已按这条路径走通，可作为其余六条的模板）：路由器目前只拿到 `taskService`、`settingsService`、`scheduleSource`、`moveController`、`autoAdjustStore`、`todayStartUtc`、`zones`、`timeZoneId`、`planningService`、`planApplication`、`plans`，以及本轮新增的 `analytics` 与 `nowUtc`。已核实的可复用接口：`AnalyticsPage(analytics: AnalyticsQuery, nowUtc: DateTime)` 配 `AnalyticsService({required source})`，`source` 由 `AnalyticsDao` 实现（`AnalyticsDao` 不在 drift 的 `daos:` 列表里，需手工 `AnalyticsDao(database)` 构造）；`SpecialDayPage` 的数据依赖（`recoveryDate`/`rules`/`fixedEvents`/`onCreateOverride`）随周视图选中日动态产生，需要额外的数据装配。**另需在 `_PlannerShell` 里加导航入口**，否则路由只能靠手输地址访问。注意 `SpecialDayPage` 属于 R11 剩余项的调用方，因此本行同时挡住 R11 的最后一步。**信息架构提醒**：偏好、数据导出与备份、应用锁都属于设置类页面，逐个加进侧边导航会让导航项继续膨胀（当前已 6 项）；把设置改成一个入口页、其下再列这些子页更合适，但那是界面结构调整而非补路由，故本轮仍按既有机制先补路由，只在此登记该建议。**剩余五页中 `FocusPage(service:, taskId:, taskTitle:)` 与 `SpecialDayPage` 类似，都需要动态数据装配（任务身份/当日规则），因此比统计与偏好两页贵**；导出、备份、应用锁三页需要文件与平台适配器，属于 W6 的范畴 |
| W4 | 首次引导门控为死代码，首启不会显示引导页 | **已解决**（提交 `7955037`）：按 onboarding schema 版本决定是否先显示引导页，删除两个死字段 |
| W5 | 存储键与 operation 前缀两端约定不一致，功能恒为空 | **偏好一半已修复**（提交 `2878af3`）：写入端 `SettingsPreferenceStore` 与读取端 `SettingsService` 曾各用各的键，**且 JSON 结构也不同**（写入端把偏好包在 `profile` 字段下、精力区间是平铺的；读取端期望裸 profile 且精力区间嵌在 `range` 下）——只对齐键名会让静默失效变成 `_energyWindowFromJson` 崩溃。现偏好统一由 `SettingsService` 读写，`clearLearned` 也会删除排程读取的键；跨模块回归测试 `test/application/learned_preference_storage_test.dart` 固化该约定。**变更历史一半已解决，且性质不同于原先描述**：`drift_plan_repository` 写的是计划生命周期事件（`confirm`/`create`/`undo:`），而 `analytics_dao` 统计的是 `interruption:`/`replan:`/`suggestion:` 三类行为事件——问题不是两侧字符串不一致，而是**根本没有任何代码产生这三类事件**，因此属待实现的功能缺口（与 R8 同类）。**其中 `suggestion:` 已补上写入方**（提交 `497baad`）：新增 `AnalyticsEventLog` 端口与 drift 实现，写进**既有** `change_log` 而不另开表——读取端已经在读它，再开一张只会重演"两侧各写一份约定"；偏好页的确认/拒绝/停用三个动作各自上报 `accepted`/`rejected`/`disabled`，并在组合根装配。写入端**校验读取端的假设**：读取端按第一个冒号切分且要求两侧非空，因此空 code 与含冒号的 code 一律拒绝，否则统计里会出现被截断的词（截断是静默的，比报错更难发现）。事件以**观察时刻**打戳而不是"现在"（用例覆盖"窗口之外不计入"）。事件在服务调用**之前**记录：动作保存失败时意图仍然可见——"用户点了拒绝但保存失败"正是这项统计该暴露的情况。变异验证：把分隔符从冒号改成短横线，往返用例即失败（`Expected: <2> / Actual: <0>`），正是改动前"恒为零"的症状。**仍缺两类，且各自缺什么已写明**：`replan:` 的自然产生方是 `ReplanningCoordinator`——它知道重排由什么触发，因此 code 可以带**真实原因**而不是占位符；`interruption:` 需要**先定产品含义**——全库没有任何打断采集入口，用"专注暂停"顶替等于替用户发明一种含义。**本轮把这一点查成了证据（不再只是我的判断）**：规格中"中断"只出现在两处，**FR-STAT-06「展示常见中断、重排原因以及建议接受、修改和拒绝情况」与 FR-STAT-08 的语气规则**；**没有任何一条 FR 定义"中断"是什么、也没有任何一条要求采集它**（既没有"允许用户记录打断"的功能项，也没有相应的界面要求）。因此这是**需求层面的缺口**而非实现细节：度量要求展示一份**从未被要求采集**的数据。可选出路三条，需产品侧选定：**(a) 补一条采集要求**（专注过程中可"记录一次打断"并选类型：他人打断／消息／自己分心……），代价是新增界面与一条规格条目；**(b) 由已采集的事实派生**——例如把"专注期间的暂停"定义为一次打断，或把"实际时长显著短于墙钟时长"视为中断，代价是**替用户定义了一种含义**，须在界面上如实说明口径；**(c) 明确接受该项首版为空**，并在规格里写明"该项待补采集要求"，避免它看起来像实现遗漏 | |
| W6 | 偏好证据无写入方；应用锁与通知点击入口无消费方 | `PreferenceEvidence` 在 `lib/` 中零构造；`AppLockService.verify` 无启动调用方。**通知点击部分已推进**：适配器已注册平台点击回调，端口已能把解析后的 payload 交给上层（见 R8），但**仍无消费方**（无导航）且 `NotificationService` 与端口**仍未在 `main.dart` 装配**——这两点均已解决（`PlannerApp` 按 payload 导航；`main.dart` 构造端口与服务并在启动时同步），该项剩余部分即 R8 记的冷启动路径。**应用锁部分已修**（提交 `cf542d8`）：`PlannerApp` 在启动时先解析 `isEnabled()`，锁开启时显示解锁界面，且**先于首次引导**——只挡主界面的锁会把设置与引导一并暴露在外，因此顺序本身就是要验证的行为。`/settings/app-lock` 同时补上了路由与侧边导航入口：门控存在但没有任何界面能让用户开启锁，等于用户永远无法触发它。**登记口径修正**：本行原把应用锁页与导出／备份并列，称其"需要文件与平台适配器（属 W6）"；读过代码后并非如此——该页只依赖 `AppLockService`，而 `SettingsAppLockCredentialStore` 由设置仓库支持，组合根本来就有。它缺的是**路由**，不是适配器。**代价**：侧边导航一度涨到 8 项，随后又到 9 项，正是 W3 那行"信息架构提醒"预告的膨胀；该归纳**已落地**（提交 `41b4873`，设置类页面收进 `/settings` 入口页，导航回到 6 项）。**已闭合**（提交 `c6e7f63`）。此前两端都断：`PreferenceEvidence` 零构造（无输入），且 `PreferenceService.refresh(evidence)` 无生产调用方（无触发），因此建议永远不会被生成。现四件事一起落地：① `PreferenceEvidenceRepository` 端口 + drift 实现（`preference_evidence` 表随 schema v1 已存在）；② `FocusEvidenceRecorder` 把一次结束的专注变成一条 `focusCompletion`；③ `FocusService.finish` 经**回调**触发记录（回调而非直接依赖，计时不必知道偏好学习存在，且回调失败只丢证据、不让"完成"看起来失败）；④ 偏好页打开时按证据调用 `refresh`。写入形式沿用分析器既有约定（`subjectKey=area:<id>`、`numericValue`、`metadata['timeBucket']`），而不是另立一套。**两处有意取舍 + 一处失配**：`subjectKey` 取**领域**而非任务——分析器要求同一主体 20 条、跨 14 天，按任务分组现实中攒不够，因此归属不到领域的任务**不写**证据；`numericValue` 取**实际专注分钟数**（FR-PREF-01 的字面要求），而分析器的 `difference < 0.15` 阈值是按 0..1 分数校准的（其测试用 0.9/0.6），对分钟数实际形同虚设——改阈值属独立决策，本轮未动，记为失配；崩溃恢复后**确认**的那条路径不写证据（补录时长不如实时会话能反映偏好）。**仍缺**：`manualMove` 与 `suggestionAction` 两类证据（分别依赖 R9 的拖动与建议操作入口）；FR-PREF-07 的特殊日排除未实现——专注流程不知道当天是否特殊日，故 `specialDay` 恒为 false，属登记缺口而非猜一个值 |
| W7 | 界面上不存在"生成计划"的入口 | `WeekViewPage` 仅在拖动后回报提案 ID，而拖动被禁用，因此排程提案在界面上完全无从触发。**已解决**（提交 `7955037`）：在外壳顶栏加入生成计划入口 |
| W8 | "信任自动调整"没有任何行为消费者，且开关初值还取决于是否访问过设置页 | **口径修正 + 一半已修**（提交 `0d72f61`）。上一轮我把这一项记成"设置的效果取决于这次启动是否访问过设置页"，复查消费者后发现更准确也更严重的事实：`plan_preview_page` 的 `_autoAdjust` **只被它自己渲染的那个 `SwitchListTile` 读取**，既不参与任何行为判断，也不写回持久设置（用户在这个开关上拨动的值只留在内存里）。也就是说这个设置在**生产中没有任何行为后果**，属于"用户能表达、却没有任何代码查阅"的偏好。**已修的一半**：该 store 原先每次启动都是新的内存实例，且只有打开设置页时才被灌入持久值，因此连开关的**初值**都取决于这次启动有没有进过设置页；现在组合根在启动时用 `SettingsService.loadTrustAutoAdjust()` 初始化它（与默认领域、应用锁同在一处），`PlannerApp` 改为接收该 store 而不是自建。**仍缺的一半属产品决策而非接线**：要让这个设置真正有意义，就得在用户不确认的前提下自动采用计划调整，而这会改变 FR-REPLAN 描述的确认语义；因此登记为待决策，不在此替用户决定 |
| W9 | `ReplanningCoordinator` 在生产里从未被构造 | 本轮查 W5 剩下的 `replan:` 事件时发现（此前未登记）：全库 grep 只有它自己的文件与测试构造它。后果有两层——① **`replan:` 事件没有产生方**（W5 剩下的那一类）；② 更基本的是，**"领域变化触发重排"这一机制在生产里根本不存在**：目前唯一的排程入口是外壳顶栏的"生成计划"按钮（W7 补的），而 `onDomainChange` 与 `DomainChangeKind`（任务创建、排程字段变化、完成、跳过、延期、固定日程创建、专注实际值变化）这套触发词汇在生产里无人调用。因此本项不只是"接一个事件"，而是要先决定**谁在什么时候发出 `DomainChange`**（任务保存后？固定日程保存后？专注结束时？），否则要么漏触发、要么每次保存都触发造成重排风暴。触发源定了，`replan:<DomainChangeKind>` 的 code 才带**真实原因**而不是占位符。建议粒度：先接"任务排程字段变化"与"固定日程创建"两类——它们语义最明确且都已有写入方。**与本项同源的还有 R8 的 ②**：应用里没有任何组件持有"当前待处理的提案"，而 R8 的"冲突待处理"通知正需要它（`pendingConflicts` 已是回调，见 R8 行 ③）。两者可用**同一个持有者**一次解开：装配协调器 → `onProposal` 把最近提案存进持有者 → 冲突通知读它、`replan:` 事件在同一处按 `DomainChangeKind` 记录。**持有者是内存态**，因此重启后来源为空；若要重启后仍提示冲突，冲突必须落库（更大的改动） |
| W10 | `lib/` 中有 9 个文件无人引用（本轮审计，方法可复现） | **方法**：遍历 `lib/` 全部 `.dart`（排除 `.g.dart`/`.steps.dart`），逐个检查其**基名**是否出现在任何**其它** `lib/` 文件中——import 行包含文件名，因此"被 import"即算被引用；否则该文件是死代码或不可达组件。**为什么做这次审计**：本轮刚吃了教训——R4 的缺口（事件编辑器不可达）**藏在一个不叫 `_page.dart` 的文件里**，而此前"逐页核对"式的检查看不见它。**其中 `focus_recovery_dialog.dart` 已查清并确认是"接线即可兑现"，且结构成本最低（无需穿透任何一层）**：`FocusPage`（`focus_page.dart:12`）**已经持有 `FocusService`**，服务侧三件套齐全（`recoverOpenEntry()` 返回 `FocusRecoveryRequest?`、`confirmRecovery({required DateTime endedAtUtc, required int actualMinutes, String note = ''})`、`discardRecovery()`），对话框的接口也齐（`FocusRecoveryDialog({required request, required onConfirm, required onDiscard})`，其中 `onConfirm` 收 `FocusRecoveryConfirmation({required endedAtUtc, required actualMinutes, note = ''})`）。缺的只是页面里的**一个 `initState`**：`_FocusPageState` 目前**没有** `initState`，因此没有任何地方调用 `recoverOpenEntry()`。**代码骨架（下一轮照抄，约 2 个编辑）**：在 `_FocusPageState` 加 `initState` 调 `_offerRecovery()`；该方法 `await widget.service.recoverOpenEntry()`，非空且 `mounted` 时 `showDialog` 弹 `FocusRecoveryDialog`，`onConfirm` 转发为 `confirmRecovery(endedAtUtc: value.endedAtUtc, actualMinutes: value.actualMinutes, note: value.note)`、`onDiscard` 转发为 `discardRecovery()`，两者返回的 `FocusSession` 都应 `setState` 回 `_session`（否则界面仍显示"待确认"）。**测试（1 个文件）**：用带"进行中记录"的假存储构造 `FocusPage`，断言进入页面即弹出对话框、确认后存储里是 `confirmed` 且活动分钟数为用户填写的值、丢弃后是 `discarded`；**先读对话框的按钮文案**（本行未记录），再写断言。**这是剩余项里最小的一项**（约 5–6 个编辑，不需要 `main.dart`／`PlannerApp`／router 任何改动），**已于本轮实施完成**（提交 `d9a437b`）：在 `_FocusPageState` 加 `initState` 调 `_offerRecovery()`，非空请求时弹 `FocusRecoveryDialog`，两个回调把返回的 `FocusSession` 写回 `_session`。四条新用例覆盖：进入页面即提示、确认后写入 `confirmed` 且活动分钟数等于用户填写值、选择"不计入"写入 `discarded`、**没有未结束记录时不提示**（不许凭空弹窗）。`flutter analyze` 无问题，全量 **327 项通过**。**过程中的两处编译错误属我自己**：`CallbackMonotonicClock` 不在 `core/clock.dart`，而 `monotonic_clock.dart` 在 `platform/` 下而非 `core/`——读一眼旁边的测试就能避免，记下来免得下次再找。**结果 9 个，按性质分三类**：**(a) 已登记**：`recurrence_expander.dart`（R4）、`replanning_coordinator.dart`（W9）、`event_editor_form.dart`（R4 切片 A）、`backup_page.dart` 与 `backup_archive_adapter.dart`、`sqlite_database_lifecycle_adapter.dart`（③ 备份）、`focus_recovery_dialog.dart`（FR-FOCUS-02，已登记在 FR 覆盖表的"崩溃恢复无调用点"）；**(b) 本次新发现**：`application/feedback_service.dart`、`application/plan_undo_service.dart`。**必须写明的口径（不得把审计结果直接当缺口）**："无人引用"**不等于**"功能缺失"——同一能力可能在别处实现。两个具体例子：**撤销**（FR-REPLAN-08）看起来可疑，但 `drift_plan_repository` 自己会写 `undo:` 变更日志并带有恢复路径（把旧的计划版本重新置为当前），因此撤销**可能**已经可用而 `plan_undo_service` 只是重复实现；反之 FR-STAT 的温和反馈若由统计页内联实现，则 `feedback_service` 同样是**重复实现而非缺口**。**下一步**：对这两个文件各查一次"该能力是否在别处可达"，再决定登记为**缺口**还是**死代码清理**；在此之前本行只陈述"无人引用"这个事实，不宣称需求未兑现。**查证结果（下一轮完成，两者都是真缺口，不是重复实现）**：**① 撤销（FR-REPLAN-08）不可达**。**本轮再核，更正我此前对拦截点的判断**：我曾把这里的阻塞记为"`PlanRepository` 与 `PlanHistoryRepository` **没有继承关系**，须先做一次接口拆分"——**该判断是错的**：`drift_plan_repository.dart:12` 是 `implements PlanRepository, PlanHistoryRepository`，**同一个类已经实现了两个端口**，因此**不需要任何接口拆分**。同时更正我口头（非本文件）说过的"`plan_undo_service.dart` 无人引用所以是死代码"：它**有自己的测试**（`test/application/plan_undo_service_test.dart`），本行的"无人引用"按审计口径只指"没有被其它 `lib/` 文件 import"，两者含义不同。**因此 FR-REPLAN-08 真正缺的只有界面可达性**，实测成本约 **12 个编辑**：路由参数（`PlanUndoService? planUndo`）、`PlannerApp` 参数与其透传、`main.dart` 装配（`DriftPlanRepository` 已可直接注入）、`_PlanPreviewLoader` 转发、`PlanPreviewPage` 的字段与按钮（含结果文案）、以及一条页面级用例（`test/plan_preview_test.dart` 已存在，可追加）。**撤销入口已实施（本轮），FR-REPLAN-08 至此兑现**：`PlanPreviewPage` 增加"撤销上一次计划"按钮（按键 `undo-plan`，**未注入回调时不显示**——宁可没有，也不要点了不生效的图标），回调返回 `bool`："没有可撤销的计划"是**正常结局**而非故障，因此界面分别回报"已撤销上一次计划"／"没有可撤销的已执行计划"，而不是抛异常给用户。**接线方式与一处更正**：我先想用组合接口 `PlanStore` 直接替换路由的 `plans` 参数，但一改就发现**有 6 处测试替身只实现 `PlanRepository`**，会被整体牵动；因此改为**新增独立参数 `planHistory`**，并由 `PlannerApp` 在"该仓储同时提供历史"时才转交（真实装配的 `DriftPlanRepository` 两者都实现）。`PlanStore` 组合接口**保留**，因为它是这个运行时判断的依据。**验证口径**：三条页面用例（确实撤销时的文案、无可撤销时的文案、未注入时不显示按钮）＋ `flutter test` 全量；**`main.dart`→`PlannerApp` 那一段属组合根装配，本仓库历来不测**，因此不声称它被测试覆盖——`drift_plan_repository` 确实**完整实现了**撤销（写 `operation: 'undo'` 与 `undo:<旧>-><新>` 变更日志，并把恢复出来的块标上 `undoRestore` 解释），但全库检索 `undo`／`Undo`，仓库之外**没有任何调用方**（唯一命中的是 `preference_service.undoLastAutoApply`，那是"自动采用偏好"的撤销，已由偏好页调用，与计划撤销是两回事），也**没有任何界面**提供计划撤销。因此 FR-REPLAN-08 **未兑现**，`plan_undo_service.dart` 不是重复实现。**撤销的实施计划（本轮查清，约 11 个编辑，留给完整会话）**：服务本身只有 36 行且**完整**——`PlanUndoService.undoLastAppliedPlan()` 读 `current()` 与 `previous()`，再调 `repository.restoreAsNewVersion(source: previous, replaced: current)`，并把两份 id 一并返回。**卡点是接口类型而不是逻辑**：`PlanRepository`（`plan_repository.dart:47`）只有 `current()`，而 `previous()`／`restoreAsNewVersion()` 在**另一个**接口 `PlanHistoryRepository`（同文件第 56 行）里，两者**没有继承关系**；路由器现有的参数正是 `PlanRepository? plans`，因此**无法**用它构造撤销服务——这就是"无人调用"的结构原因。**实施步骤**：**(1)** 在 `createPlannerRouter` 增加 `PlanHistoryRepository? planHistory` 参数（1 个编辑）；**(2)** `PlannerApp` 增加同名字段并透传（2 个编辑）；**(3)** `main.dart` 把已有的 `DriftPlanRepository` 实例同时以该类型传入（1 个编辑，对象复用、不新建）；**(4)** 界面落点选 **`TodayPage`**——它展示的正是当前已确认计划，语义最贴，且其构造函数极简（`TodayPage(source: scheduleSource, day: todayStartUtc)`），加一个 `onUndo` 回调约 2 个编辑，路由处 1 个编辑；**(5)** 测试：先确认计划已应用（`current()` 存在、`previous()` 存在），点撤销后断言 **`current()` 变成上一份**、且**被替换的那一份仍在历史里**（撤销本身又是一次新的已确认版本，不得毁掉历史）——最后这条是撤销最容易做错的地方；**(6)** 变异：把 `restoreAsNewVersion` 换成"直接删除当前版本"之类的写法，则应因"历史被毁"而失败。**② 温和反馈（FR-STAT-08 的呈现侧）不可达**——`domain/models/feedback_message.dart` 与统计页都已就绪（`analytics_page.dart:22` 接收 `feedbackMessages`，`feedback_cards.dart` 负责渲染），但**没有任何生产者**：检索 `FeedbackService`／`feedback`／`反馈`，除模型与统计页外只命中 `feedback_service.dart` 自身，`AnalyticsService` 并不产出 `FeedbackMessage`。因此该列表**恒为空**，用户永远看不到反馈——FR 覆盖表原先写的"反馈文案与温和原则达标"**过强，已更正**。**③ 接线方案已试做并回滚，附确切的下一步（本轮实测）**：`FeedbackService.generate(current, previous)` 是**完整实现的纯函数**，而统计页手里**已有** `AnalyticsQuery`，因此生产者**可以在页面内自己算**——取"紧邻其前的等长区间"作为对照，**不需要穿透组合根四层**。我按此改了 4 处（新增 `_feedback` 字段、在 `_load()` 里查对照窗口并 `generate`、加 `_messages` getter、渲染处改用它），`flutter analyze` 通过，但**两条既有测试失败**：`Expected: DateTime:<2026-10-01 00:00:00.000Z> / Actual: DateTime:<2026-08-31 00:00:00.000Z>`——即对照窗口的起点。**根因与修法（不是简单替换）**：测试替身**已经**把每次查询记进 `filters` 列表（`analytics_page_test.dart:97`、`analytics_tag_filter_test.dart` 同），而断言读的是 `filters.last` 当作"用户所选窗口"（`analytics_page_test.dart:35,36`；`analytics_tag_filter_test.dart:44,49,57,62,63,64,77,78,79` 共 9 处）。加了对照查询后每次加载会追加一对 [当前, 对照]，`.last` 因此指向对照；但**多次切换范围后"当前"位于偶数位**，所以**把 `.last` 一律改成 `.first` 也是错的**。两个可选设计，需择一（我回滚而不是草率改 10 处断言，正是因为这是个设计选择）：**(A) 页面两次查询**（改动最小，代价是测试要按"窗口"而不是"位置"来断言——例如断言存在某个 filter 与期望窗口相等，或让替身只记录用户发起的窗口）；**(B) 给查询端口加一个语义方法**（如 `queryWithComparison(filter)` 返回当前与对照两份报告，由 `AnalyticsService` 内部查两次）——页面对外只发一次调用，语义更清楚，代价是**接口加方法会打破全部实现该端口的测试替身**（与 R4 的端口教训同型）。**我倾向 (B)**：它把"两次查询"这个实现细节收进服务层，页面只表达"我要对比"，测试替身也只需回答一个问题。**④ 最终采用了一个比 (A)(B) 都省的解，已实施（提交 `acd5220`）**：不改端口、也不改任何测试——**把对照窗口放在前面查、当前窗口放在最后查**。这样每次加载仍是 `[对照, 当前]`，既有 10 处 `filters.last` 断言**依旧指向当前窗口**，全部无需改动；`flutter analyze` 无问题、统计页 7 条用例与**全量 323 条**全部通过。**代码里把这层意思写成了注释**（顺序是刻意的、位置耦合是既有事实、本处不新增也不掩饰）。**诚实的剩余**：生成逻辑（`feedback_service_test`）与渲染（`feedback_cards_test`）各有单测，但**"页面确实请求了对照窗口"这一条接线还没有专门断言**——**该断言已补上（提交 `d453578`）**：在 `analytics_page_test.dart` 里断言"存在一次以**当前窗口起点**（`2026-10-01`）收尾的查询"，因为对照窗口正是紧邻其前的等长区间、必然以当前窗口起点收尾（当前月窗口是 `10-01→11-01`，以 `11-01` 收尾，因此两者不会混淆）。**这次补断言的过程本身值得记下两处我自己的错**：① 起初断言 `filters.first`，假设"对照总在第一位"——初始加载成立，但本用例中途切换过范围，`first` 是别的东西（实测 `2026-10-08`）；② 改成计数后我把期望写成 **≥2**，把当前窗口也当成了"以 `10-01` 收尾"——实际是 **1**，而那 1 次**正是**对照查询，跑一次就纠正了我。最终断言**不依赖位置**。实现之前页面只发**一次**查询，因此这条断言在当时不可能通过——这就是它的红侧 |

#### 13.0.4 正确性缺陷

| 编号 | 缺陷 | 影响 |
| --- | --- | --- |
| C1 | `breakMinutes`（片段间休息）在 `lib/scheduling/` 中从未使用 | **已修复**（`52bfe83`，并经 `f49a4ec` 推广、`algorithmVersion` 4 定案）：分配与局部改进阶段要求**任意两个任务块之间**间隔 ≥ `breakMinutes`，不区分任务类型；续排容量改为从下一片段最早可开始时刻起算。决策与实测见 13.0.7 |
| C2 | `deadlineRisk` 只取 0/1000 两档 | **按政策回改中**。此前按用户决策改为"如实描述实现"（`8dd7fc`）；按"实现以需求文档为准"的原则，实现需向 §5.4 靠拢。**已完成**：排序改为总分优先（版本 5）、连续性与类别切换注入（版本 7）、移动成本注入（版本 8）、用户期望时段注入（版本 9）。**剩余**：8 个任务级因子在同一任务的候选之间恒为常数——后者要让任务排序机制也纳入评分才能兑现 |
| C3 | 已锁定块被同时计入每日可移动上限 | **已修复**（提交 `01f74b7`）：`plan_validator.dart` 不再把锁定块计入每日可移动上限，并补充双向回归测试 |
| C4 | 备份缺少 WAL checkpoint 一致性快照 | **已修复**（提交 `7289ea5`）：改为显式 FULL checkpoint，未完成时以 `BackupValidationException('walNotCheckpointed')` 让备份失败，不再静默产出过期快照 |
| C5 | 候选排序首键为 `coverageMinutes`，先于软约束总分 | **已解决**（算法版本 5）：按"实现以需求文档为准"的原则，排序改为以软约束总分为首键，与 §5.2 第 7 步一致，覆盖度退为同分时的次级依据。实测不改动 golden 周输出（该场景两种顺序恰好一致），但在覆盖度与评分不一致的输入上会改变结果，故算法版本提升为 5。**注意**：排序修正并不等于 §5.4 已完全兑现——8 个因子对同一任务的候选恒为常数、4 个因子从未被注入，这两项分别见 C2 与 R5、R6 |
| C6 | 远期任务可能整周排入 0 分钟 | **已实现**（提交 `39dea30`）。此前：分片时长不小于 `minChunkMinutes`，而均匀推进目标 `pacedNow` 可能低于该值，于是"截止仍在数周之后"的任务当周排入 0 分钟（实测：截止在 30 天后的 120 分钟任务 `scheduled=0`、`shortage=28`，连续与可拆分都一样）。现把大于零但小于最小可排片段的目标抬到确实可排的最小量：可拆分任务排入一个最小片段（实测 30 分钟），连续任务排入整块（实测 120 分钟——不可拆分任务的固有取舍，要么整体排入要么排不进）。窗口内到期的任务不受影响，golden 周输出不变。`algorithmVersion` 提升为 6 |
| C7 | `_scoreCandidate(...).totalScore!` 强解包未检查 `isEligible` | **判断已修正：当前不可达**。原先记录的触发条件（锁定块晚于截止或越出规划窗口）经实测不成立——`_improve` 首行是 `if (block.locked) continue;`，锁定块根本不进入该路径；分配循环与局部改进又都对候选做过截止过滤，重叠也已被阻止。实测三种场景（锁定块晚于截止、锁定块越出窗口、两个互相重叠的锁定块）均不抛异常。保留为**潜在**健壮性问题：将来若有改动让不可用评分的块进入该路径，此处会抛 null 断言 |
| C8 | 恢复流程"先落库日期例外、再生成提案" | **判断已修正**。原先记为违反 §6"提案应用前不替换当前计划"，但复查后顺序是**必要**的：`SettingsService.resolveForDate` 会读取并叠加该日期例外（`settings_service.dart:90,98`），若不先写入，生成的提案根本不会包含当次恢复保护。**真正的问题是另一件事**：`saveDateOverride` 是全库唯一的写入方（`recovery_planning_service.dart:124`），**且没有任何清除路径**，因此用户只要**预览**过恢复方案（哪怕随后取消、从未应用），该日期的睡眠例外就会永久生效并静默影响当天之后的所有计划。**已按登记修法实施**（提交 `424a1fc`）：把例外作为**提案输入**传入而不是先写成持久设置。新增 `ScheduleRuleOverride`（日期 + `PlanningRulesPatch`），`ScheduleProblemSource.load` 与 `ProposalCreator.createProposal` 接受它，`PlanningRuleResolver.resolveForWindow` 把它叠加在命中当天的解析结果之上（用户显式保存的当日例外仍然优先）；`RecoveryPlanningService` 不再持有 `SettingsService`，因此"预览不写库"由编译器保证而不是靠断言。**实施中发现一处未登记的连带缺陷**：原来的"先落库"顺序同时承担了另一个作用——`PlanApplicationService.apply` 会重新装配输入并比对 `inputHash`，被持久化的那个例外正是重放哈希能够一致的原因；若只把写入改成一次性输入而不动确认阶段，恢复提案会永远被判为过期而无法应用。现由 `ScheduleProposal.ruleOverride` 携带该覆盖、确认时原样重放，并做了变异验证（去掉重放后该测试失败，`Actual: <null>`），证明测试有判别力而不是碰巧通过。**仍存两点限制**：① 例外只在 `recoveryDate` 等于规划窗口首日时对睡眠与最低睡眠生效——`ScheduleProblem.rules` 是覆盖整窗口的单一对象，这两个字段属"整窗口唯一"，换一天则只有精力区间与保护时间这类按日合并的字段会生效（该行为已在测试中断言）；② **特殊日页面已接通**（提交 `226ff8f`）：新增 `/special-day` 路由、外壳顶栏入口，以及页面上的"查看调整预览"——最后一项是必需的，否则生成的提案拿到 `proposalId` 却无处确认。因此这条链路**首次在真实用户路径上成立**，不再只有测试可达。 |
| C9 | `TZDateTime` 与 `DateTime.utc` 判等失败，导致同一时刻被当作不同区间 | **已修复**（提交 `8c8dbc7`）：`localDateTimeToUtc`/`localMidnightToUtc` 曾返回 `tz.TZDateTime`；该类型即使表示 UTC 也 `isUtc=true`、微秒值与 `hashCode` 与 `DateTime.utc` 相同，但 `==` 返回 false。`TimeRange.operator ==` 用 `==` 比较端点，因此混用两种表示会让同一区间判不相等，而 `PlanValidator` 正是靠 `proposed.range != locked.range` 判断锁定块是否被移动——一旦块从数据库以 `DateTime.utc` 重建，就会误报 `lockedBlockMoved` 并让合法提案被拒。现统一规范化为普通 UTC `DateTime` |
| C10 | 用餐与固定休息从未参与排程 | **已修复**（提交 `b0a1f69`）：`AvailabilityBuilder` 内部只把 `rules.sleepRange` 落成区间，而 `rules.protectedTimes`（午餐、晚餐、固定休息）需要外部展开成具体区间后传入 `protectedIntervals`——此前没有任何生产代码做这件事，因此这些保护时间在真实运行中恒为空集。新增 `ProtectedTimeExpander` 逐日展开 |
| C11 | 保护时间的 24:00 终点，以及按日推进用了绝对时间加法 | **已修复**（提交 `da91b31`），本轮实施 R5 时以该展开器为参照而发现，此前未登记：① `LocalTimeRange` 明确允许 `endMinute == 1440`（09:00–24:00 是合法区间且不跨午夜），但展开器把 1440 直接交给 `localDateTimeToUtc`，后者只接受 [0, 1439]，会抛参数错误、让整轮排程失败——即"类型允许、运行必炸"；② 逐日推进与跨午夜终点用本地 `DateTime.add(const Duration(days: 1))`，这是**绝对时间**加法：夏令时回拨日的本地零点加 24 小时会回到当天 23:00，日期不变，于是某一天会被重复或跳过。现统一改为按 `(year, month, day + n)` 构造日历日，终点为 24:00 时改用次日本地零点。①有测试覆盖（修复前必抛异常）；②的行为取决于**系统时区**是否使用夏令时，本机时区无夏令时故无法复现，属"移除对该依赖"而非"用测试证明"，如实标注 |

#### 13.0.5 需求覆盖缺口

| 编号 | 需求 | 现状 |
| --- | --- | --- |
| R1 | FR-TASK-02 自定义标签、FR-STAT-02 按标签筛选 | **已全部完成**（数据层与服务层 `d5d2054`、`1745e59`；打标签入口 `90eedb2`；统计页按标签筛选 `cf02365`）。`tags` 表与 `task_tags` 关联表（复合主键）已随 schema v2 落地，迁移、快照与测试均已提交。**本轮补上第一环**：`PlannerTag` 领域模型、`TagRepository` 端口与 `DriftTagRepository` 实现、`TagService`（`ensureTag` 先查后建，保证同名只有一行——数据库没有唯一约束，那需要一次 schema 迁移，而本项不需要；`setTaskTags` 按差量更新关联，重复保存同一组不产生多余写入）。有判别性的验证：建出"论文修改"与"论文"两个标签、只给任务打"论文"，断言只返回"论文"——子串实现会两个都返回，而"用两张表而不是一个分隔字符串列"正是为了整词匹配；另有"关联是任务级的""空名称被拒绝且不建出空名标签"。**登记口径修正（此前写错了）**：原先记"统计侧仍靠子串匹配"，实际**从未是子串匹配**——`AnalyticsDao` 组装 `AnalyticsTaskFact` 时**从不填充 `tags`**，而模型把该字段默认为空集，于是 `!task.tags.containsAll(filter.tags)` 对任何任务都成立：**只要筛选带上非空标签，就会静默返回空集**——不是"过滤后的结果"，也不报错，看起来像"这个标签下没有数据"。**该缺陷已修**（提交 `1745e59`）：`AnalyticsDao` 一次性 join 出每个任务的标签名并填充（按名称而不是 id，因为筛选与界面都用名称）。三个测试有判别力：把填充那一行去掉即失败，得到 `Expected: Set:['论文', '深度工作'] / Actual: Set:[]` 与 `Expected: <1> / Actual: <0>`，正是上述空报表。**两处界面均已补齐，R1 至此完成**（提交 `90eedb2`、`cf02365`）：① 任务详情页的标签区——行内 `FilterChip` 切换已有标签、一个输入框加按钮建立新标签并同时打上（"只建不打"的标签对用户没有意义），经 `main.dart` → `PlannerApp` → `createPlannerRouter` 装配；② 统计页的标签筛选——可多选、语义是**交集**、并说明"尚无标签时该做什么"。**实现中发现并提前避掉一个缺陷**：`_setRange` 原先只用时间范围重建 filter，因此换一次统计周期就会把已选标签**静默丢掉**，而界面上的 chip 仍显示为选中——一个会撒谎的筛选器。现两处都从现有 filter 出发，并有变异验证（改回旧写法即失败：`Expected: Set:['论文'] / Actual: Set:[]`）。**附注**：`lib/main.dart` 的装配本身没有自动化测试（组合根历来如此），标签链路的生产可达性由"未注入服务时整块不渲染"加路由注入共同保证。**另注（流程）**：本轮得以修改 `main.dart`，是因为先把并发另一 agent 的未提交改动作为两个具名提交落下（`7af3431`、`848bfda`），而不是把它们卷进我的提交 |
| R2 | FR-TASK-02 项目、FR-STAT-02 按项目/领域筛选 | **数据层、服务层与界面均已完成**。此前 `projects`/`areas` 表已建但无任何写入路径，`task.projectId` 恒为空，领域统计退化为"未分类"。本轮补上领域与项目的**第一个写入方**：`PlannerArea`/`PlannerProject` 领域模型、`WorkspaceRepository` 端口与 `DriftWorkspaceRepository` 实现（含 `onConflict` 保留 `createdAtUtc`、归档可往返、取消归档能写回 NULL）。**关键验证**：经该仓库写入的领域与项目能被 `DriftLifeAreaLookup` 认出来，即 R2 的写入端与 R13 的读取端首次在真实数据上对齐。**本轮补上服务层与默认初始化**：`WorkspaceService`（新建/改名/设置生活标记/建项目/归档，并校验项目必须挂在已存在的领域下）与 `ensureDefaultAreas()`（只在全无领域时建立学业/科研/生活，其中"生活"被标记为生活领域——生活配额唯一的默认作用对象），并已在 `main.dart` 启动时调用。因此 `is_life` 现在**在真实运行中真的会被赋值**，生活配额与统计的"生活"分类从此有数据来源；服务层测试覆盖"标记前无人是生活任务、标记后读取端立即生效、取消标记同样立即生效且不改创建时间"，以及"重复调用不重复写入""用户已有领域时不补齐默认值"。**本轮补上任务侧的归属入口**：`TaskService.assignProject(taskId, projectId)`（`null` 即取消归属；归属未变化时不写入，避免"最近修改"被无谓推进；不重复校验项目是否存在——库里已有外键且连接时开启 `foreign_keys`，重复实现只会与库结构脱节）。测试证明**归属到生活领域下的项目后，生活标记立即对该任务生效**，取消归属同样立即生效，不存在的项目由数据库外键拒绝。**本轮补上界面控件**：任务详情页新增"归属项目"选择器（已归档项目不出现在可选项中，界面明确写出"领域与生活标记经项目推导，不归属则两者都不适用"），三个 widget 测试覆盖归属、取消归属与归档过滤。**已补齐界面**（提交 `ccd5dc9`）：新增 `/workspace` 管理界面——新建与改名领域、切换生活标记、新建与归档项目（归档可往返），作为任务的同级入口加入侧边导航；`WorkspaceService` 另补 `renameProject`（与 `renameArea` 同口径：只推进修改时间，不动归档状态）。此前登记的 ① 领域与项目的管理界面缺失、② 默认初始化只建领域不建项目的后果（选择器开机为空、用户无法归属），已分别由该界面与任务详情页的"新建项目并归属"消除，因此**"任务归属 → 项目 → 领域 → 生活标记"整条链路首次可以在界面里完整走完**，生活配额因子与统计的"生活"分类首次有了用户可控的数据来源。测试中价值最高的一条不看"页面上有没有这个开关"，而是从界面切换生活标记后，经真实数据库与真实 `DriftLifeAreaLookup` 断言该领域下的任务确实被算作生活任务。界面刻意**不含删除**：登记里的缺口列表是"创建、改名、改生活标记、归档"，归档又已被定义为可逆状态而非删除；此外删除领域还需决定其下项目与任务的去向，需求文档对此没有规定，凭空加入会是无依据的破坏性操作 |
| R3 | FR-CAL-03 日视图 | **已实现**（提交 `2989e17`）。新增 `features/calendar/day_view/day_view_page.dart`，**复用 `ScheduleViewSource`**（该端口本来就接受任意窗口）而不是另造一套装配——两个视图读同一个源，才不会对"这一天有什么"各说一套。与周视图的实质差别是**显示时刻**：周视图的卡片只有类型与标题，而日视图的意义正是"几点到几点做什么"，因此按本机时区把 UTC 区间换算成本地时刻（需求 §13）；该换算有**判别性**测试（同一条 09:00Z 在东八区必须显示 17:00，去掉换算即该用例失败），只用 UTC 断言会被"直接打印 UTC"蒙混过关。类型以**文字**与时刻并列给出，不只靠底色（需求 §12：不能只依赖颜色区分）。空状态说明"空"是什么意思，而不是留一片空白。**可达性**：与周视图**互为切换**（周视图加"查看当日"、日视图加"查看本周"，均由路由器注入），因此**不占导航项**，导航仍 6 项；选中项改按路径前缀判定，两个视图都停在"日历"。路由把日期作为参数（`/calendar/day/:dayStartMicros`），将来要加"按天进入"无需新路由 |
| R4 | FR-CAL-02 按周重复、单次/系列编辑、删除 | `recurrence_rules` 无写入方，`RecurrenceExpander` 仅测试引用，`occurrencesBetween` 不展开重复，`editScope` 被表单采集后丢弃，仓储无 delete。**本轮逐项复核，五条全部属实**，并补两点执行顺序：① 规则写入与"在 `occurrencesBetween` 里展开"**必须与一条界面路径同批交付**——只做前两者会造出"没有任何界面能创建重复规则"的中间层，而规则恰恰是要被展开的东西（与 R1、W6 同型的陷阱）；最小可行纵切是"事件编辑器加一个按周重复开关 → 服务写规则 → 仓储展开 → 周/日视图显示出来"。② "单次/系列编辑与删除"应在此之后单独做：它还需要仓储的 `delete`／例外写入与界面上的范围选择，与展开是两件事，混在一批会让两者都难以验证。**实施该纵切时已定下的判断（本轮试做后回滚，故记在此处避免重推）**：③ 规则表**没有** `title`／`locked`／`areaId`，展开出的实例必须**回连锚点事件**（按 `recurrenceRuleId` 建索引）才能拿到标题；④ **锚点事件本身不能再作为单次事件输出**，否则它那一天会出现两条（一条来自事件行、一条来自展开）——因此 `occurrencesBetween` 要按"是否带规则"**分区**，而不是加 `IS NULL` 过滤，因为规则行缺失时还要能退化成"只显示这一次"；⑤ 每次出现必须有**各自的** id（形如 `<锚点id>@<日期>`）：排程输入按 id 去重并参与哈希**（★ 本条理由本轮被核实为**错误**，见下方核对结果）**，复用规则 id 会让不同日期的实例在输入里互相覆盖；⑥ `CalendarService` 必须持有 `TimeZoneDatabase`——"每周三 09:00"是**墙上时间**，建规则要把它换算成本地星期与钟点；⑦ `DriftCalendarRepository` 需要一个 `Clock` 来写规则的创建/修改时间，**不能**用 `DateTime.now()`，否则破坏 FR-DATA-08 的可验证性；⑧ 掩码约定：`RecurrenceRules.weekdaysMask` 的第 `weekday` 位（1=周一），域模型是 `Set<int>`；⑨ 展开器已支持传入 `RecurrenceException`，但按上面的拆法，本轮纵切传空表——单次例外属于第二件事。**⑩ 逐文件实施清单（为下一个会话准备；本会话上下文余量不足以走完，故留清单而非半成品）**：**(1)** 新建 `lib/domain/repositories/recurrence_rule_repository.dart`——`saveRecurrenceRule(RecurrenceRule)` 与 `listRecurrenceRules()`；**必须用单独端口**，若直接往 `CalendarRepository` 加方法，会打破全部实现该接口的测试替身（`test/app/special_day_route_test.dart` 的 `_NoEvents`、`test/features/calendar/event_editor_test.dart` 的 `_MemoryCalendarRepository` 等）。**(2)** `lib/data/repositories/drift_calendar_repository.dart`：构造函数加 `TimeZoneDatabase zones` 与 `Clock clock`（后者用于规则的创建/修改时间，见 ⑦），持有 `RecurrenceExpander(zones)`；实现该端口（掩码 `1 << (weekday - 1)`、日期用 `yyyy-MM-dd` 文本）；在 `occurrencesBetween` 里做分区展开（见 ④⑤）。**(3)** `lib/application/calendar_service.dart`：加**可选**参数 `RecurrenceRuleRepository? recurrenceRules`（可选才能不打破既有构造点）；`save` 增加具名参数 `bool repeatWeekly = false`——**放在方法上而不是加进 `EventDraft` 的字段**，可少改两处；为真时用 `zones.toLocal(draft.startAtUtc, draft.timeZoneId)` 取本地星期与钟点建规则（⑥），并把 `rule.id` 写进锚点事件的 `recurrenceRuleId`。**(4)** `lib/features/calendar/event_editor/event_editor_form.dart`：加 `bool canRepeat`（未装配时不显示开关，避免"点了才知道没装"）与 `CheckboxListTile(key: Key('repeat-weekly'))`，`_save()` 把该值传给 `service.save(...)`。**(5)** `lib/main.dart`：`DriftCalendarRepository(database, zones: zones, clock: clock)`，把同一实例同时作为 `CalendarRepository` 与 `RecurrenceRuleRepository` 传入 `CalendarService`。**(6)** `lib/app/router.dart` 与 `lib/app/planner_app.dart`：把 `canRepeat: true` 沿"组合根 → PlannerApp → 路由 → 表单"传下去（本仓库的既有模式）。**(7)** 测试三处：服务在 `repeatWeekly: true` 时确实写规则、且默认不写；drift 仓储对"每周一次、跨三周窗口"展开出三条且**锚点那天不重复**（见 ④）、每次出现 id 互不相同；表单勾选后落库的事件带 `recurrenceRuleId`。**(8)** 变异验证：把锚点分区去掉（锚点也当单次输出）→ 应出现重复；把掩码移位改成 `1 << weekday` → 星期错位；把 `repeatWeekly` 的传递断开 → 表单用例失败。**估算**：约 11 个编辑、3 个测试文件、2 次门禁运行——**一轮内可完成，但需要完整的会话上下文**。**⑪ 上文清单的前提已被本轮核实推翻，须先补一步**：检索整个 `lib/`，`EventEditorForm` **只出现在它自己的文件里**（无任何地方渲染它），`CalendarService` 也**只出现在自己的文件里**（无生产构造点）。因此**日历的事件创建界面根本不存在**——今天连"建一条一次性日程"都无法在界面上完成，所以 (4)(6) 两步所假设的"给表单加开关并沿四层传参"**没有落点**。**修正后的实施顺序**：**(A) 先做"从界面创建一次性固定日程"**——把 `CalendarService` 装配进组合根、加一条事件编辑路由与入口（例如日视图／周视图上的"新建日程"，日视图刚由 R3 落地，是天然的落点），自身即是**完整可达**的一步，可独立提交并关掉 FR-CAL-01 的一部分；**(B) 再在同一路径上做按周重复**（本文清单 (1)(2)(3)(7)(8) 仍然有效，因为服务层与数据层与"是否可达"无关）。**修订估算**：拆成两轮更现实——(A) 约 8 个编辑，(B) 约 8 个编辑。**附带影响**：R9 的"任务转固定日程"同样依赖"能创建日历事件"这条路，因此 (A) 一次投入同时解开它的一半 |
| R5 | spec §7.1 期望时段（plan §3、§9.4 亦要求） | **评分已注入且写入端已接通**：`preferred_start_minute` / `preferred_end_minute` 随 schema v2 落地；因子由纯函数 `preferred_time_scorer.dart` 计算并注入（算法版本 9，golden fixture 同步）；本轮补上写入端——`TaskService.setPreferredWindow`（软约束语义：非法取值返回 `false` 而不抛错、两个端点都为空即清除、跨午夜区间合法）与任务详情页的输入控件（格式 `09:00-12:00`，留空即清除，并明确告知"这是软约束，排程仍可能落在区间外"）。因此该字段首次有了真实写入方。**仍缺**：批量设置、以及把期望时段纳入任务编辑表单（目前只在详情页） |
| R6 | FR-SCHED-04 十因子评分 | **候选层面已全部注入**（`8e4c868` 版本 7、`be6accb` 版本 8、`fb3eb06` 版本 9）：连续性、类别切换、移动成本、用户期望时段四项此前恒为 0 的因子均已接通并各有判别性验证。**剩余**：8 个任务级因子在同一任务的候选之间恒为常数（见 C2），要让它们影响决策需把任务排序纳入评分 |
| R7 | FR-SCHED-08 移动原因、FR-REPLAN-02 拆分与原因 | **已实现**（提交 `ee3dcbc`）：`PlanChangeType` 增加 `split`，`PlanChange` 增加 `reason`（取自片段的 `explanationCode`，保持稳定码约定，界面用 `explanationLabel` 渲染）。规则：任务在原计划已有块且提案中块数变多 → 新块记为 `split`；原计划没有该任务的块 → 记为 `added`。既有的按 ID 比较逻辑未改动，因此原有差异测试的期望 `[moved, removed, added]` 仍然成立（已用同一场景实测）。`router.dart` 的 `PlanChangeType` switch 同步补上 `split` 分支——否则新增枚举值会让该 switch 失去穷尽性而无法编译 |
| R8 | FR-NOTIFY-01/02 其余三类通知、FR-NOTIFY-04 快捷入口 | **已于服务层实现**（提交 `2d14142`）：固定日程即将开始、截止临近、冲突待处理三类都可安排，`NotificationPreferences` 增加了冲突类型的提前时间（FR-NOTIFY-02 要求每类都能设置），存于设置 JSON、无需迁移，旧数据回退默认值。三类来源以可选依赖注入，未装配时跳过该类而不是伪造。**顺带修掉一个既有缺陷**：默认截止提前时间为 24 小时，20 小时后到期的任务其提醒时刻落在过去而被静默丢弃，用户永远收不到提醒；现在已过的提醒时刻改为"尽快提醒"。**剩余**：FR-NOTIFY-04 的快捷入口已打通**平台一侧**（见本轮）——payload 契约改为两侧共用（`NotificationPayload` 的编解码取代了写入端四处内联 `jsonEncode` 与读取端私有解析，属 W5 同类的"两端各写一份约定"问题），`NotificationPort` 新增 `onTapped` 把解析好的 payload 交给上层，`windows_notification_adapter` 终于注册了 `onDidReceiveNotificationResponse`。**已通电**：`main.dart` 现在构造 `WindowsNotificationAdapter` 与 `NotificationService`（plans/settings/notifications/clock/zones/timeZoneId/calendar/tasks），启动即调用 `syncNextSevenDays()`（不阻塞首屏，失败只记日志——通知不是启动的必要条件），并把同一端口交给 `PlannerApp` 作为点击来源。此前四类通知、提前时间的钳制修正与点击回调虽都已实现并有测试，却没有任何调用方，真实运行中永远不会安排提醒。**剩余三点**：① **冷启动路径已解决**（提交 `f4b26c5`）：`NotificationPort` 新增 `launchPayload()`，适配器读 `getNotificationAppLaunchDetails()`，`PlannerApp` 在 `initState` 读一次并按 payload 导航。该接口与 `onTapped` 的分工正是这条缺口的成因——一个由平台回调送达，另一个必须显式询问。**顺序带来的安全性质**：导航发生在门控之下，因此冷启动点击**不会绕过应用锁**（锁着时先看到解锁界面，解锁后才落在通知指定的去处），并有测试固化；若把门控放进路由之内，这个功能就会变成进入锁定应用的后门。**未验证部分**：真实读取路径未被执行——`didNotificationLaunchApp` 只有在 Windows 真的由 toast 拉起进程时才为 true，本机无法构造；测试在端口处注入 payload，因此这是"边界已通、平台调用待打包运行确认"。② `hasPackageIdentity` **已接入真实判定**（提交 `7af3431`，由并发的另一 agent 提交，我代为落库）：`main.dart` 不再硬编码 `false`，改为调用 `hasWindowsPackageIdentity()`（dart:ffi 调 `GetCurrentPackageFullName`，失败一律退化为 false）。**但真实判定仍未验证**：该文件三个测试**全部注入假探针**，"无包身份返回 false"也是注入 `APPMODULE_ERROR_NO_PACKAGE` 模拟的，因此被验证的是两段式缓冲流程、无包分支与非 Windows 短路，而真正的 kernel32 调用在本机**一个方向都没执行**——不得计入已验证，首次发布前需在打包环境下确认；③ "冲突待处理"通知缺少来源：冲突不是持久事实而是每次排程的产物，`pendingConflicts` 未提供，因此该类被跳过而不是伪造一条。**本轮定点核实后可以确认：②（本项）与 W9 是同一处缺失，且服务侧其实已经准备好了**。证据两条：**其一，`pendingConflicts` 早已是回调**——`notification_service.dart:58` 的类型就是 `Future<List<PlanningConflict>> Function()?`，第 172–190 行真的 `await` 它并据此安排通知，因此**服务侧一行都不用改**，缺的只是组合根没传这个 lambda。**其二，冲突从不被持久化**：全 `lib/` 检索 `conflicts`，它只出现在引擎产出的 `ScheduleProposal`、`ApplyPlanResult`、恢复提案与预览模型这些**内存对象**中，`lib/data/` 里一次都没有。**因此真正缺的是"谁持有当前待处理的提案"**——这与 W9（`ReplanningCoordinator` 在生产里从未被构造）指向同一件事。**一个很小的持有者同时解开两项**：把 `ReplanningCoordinator` 装配起来，用它的 `onProposal` 回调把最近一次提案存进一个持有者，于是 ② 的 `pendingConflicts` 就是"从这个持有者读最近提案的 `conflicts`"，而 `replan:` 事件也可以在同一处按 `DomainChangeKind` 记录真实原因。**代价（须如实说明）**：只有"最近一次生成的提案"这一份内存状态，因此应用重启后该来源为空——若要求重启后仍能提示冲突，冲突就必须**落库**（新增持久化），那是比接线更大的改动。**③ 已实施（提交 `c392438`）**：`PlanningService` 增加**可选**回调 `onProposalCreated`（与 `FocusService.onFinished` 同型），`main.dart` 用一个局部变量持有最近提案并把它交给 `pendingConflicts`。**没有穿透任何一层**——路由器与 App 用的本来就是被挂上回调的那个服务实例，因此界面上任何路径生成的提案都会经过它；未生成过提案时返回空表，该类通知照旧被跳过。**同时查明的两点**：**(a)** 通知侧**早已有测试**（`notification_kinds_test.dart:81` 注入 `pendingConflicts` 并断言 `planner.conflict.pending` 与其 payload），因此本项缺的**只是生产来源**；**(b) `replan:` 事件的落点也就是这个回调**——它现在只缺 `DomainChange` 由谁发出的决定（W9），届时在同一处按 `DomainChangeKind` 记录真实原因即可。**补强（提交 `aff9792`）**：本轮回头检查了随 `c392438` 一起加的那条断言，认为它**判别力不足**——它只断言回调收到的提案与预览 **id 相同、conflicts 相同**，而这条回调存在的理由恰恰是"通知读的是最近提案的 conflicts"，因此真正要钉的是**回调拿到的是应用了覆盖（恢复保护／特殊日）的那一份**，而不是 `withRuleOverride` 之前的原始提案。现已补上覆盖场景：以带 `ScheduleRuleOverride` 的 `createProposal(override:)` 再生成一次，断言回调收到的那一份**确实带有覆盖**。**变异验证**：把实现改成 `onProposalCreated?.call(proposal)`（原始提案），用例失败于**新增的那条**（`Expected: not null / Actual: <null>`）——失败落点与新断言一致，说明原先两条**不足以**发现它。这一处很典型：**同一次实现里，"看起来够了"的断言往往只覆盖了不变量的一半**。**工作区并发写者（本轮亲历，须提醒后来者）**：验证时全量套件报出两条失败，均属 `preferences_page_test.dart` 的"修改学习建议"用例，而该文件与 `preference_service.dart`、`preference_analyzer.dart`、`preferences_page.dart`、`pubspec.yaml` **都处于未提交状态、由另一个写者正在改动**。我用"把本提交涉及的源文件退回上一版再跑该文件即通过"**排除了自己**，并把提交信息里原先一句未经证实的"全量 328 通过"**改为如实陈述**（analyze 无问题、本文件 6 条通过、全量数字在存在他人未提交改动的情况下不可声称）。**教训**：在这个仓库里，"全量通过"只有在工作区干净时才是可声称的事实；提交前应先看 `git status`。**并发的记账约定（本轮补）**：当某个登记项正被另一个写者改动时，本行应把它标为**"他人进行中"**而不是"仍缺"——本轮就吃过这个亏：`修改偏好值` 在并发工作期间被当作缺口，我据此设计了两次，直到对方提交 `99e60a5` 才发现已实现。**同一约定也适用于当日正在进行、随后以 `55ffbce` 落地的切片 A**：`event_editor_form.dart` 与其新增的 `test/app/calendar_event_route_test.dart` 当时处于未提交状态，因此"日历事件创建入口尚未实现"这一说法在那一刻同样**只能表述为"进行中"** |
| R9 | FR-TASK-03 批量调整、FR-TASK-04 任务转固定日程、FR-REPLAN-07 处理入口、FR-FOCUS-04/05 补录与重算、FR-STAT-05 精力与休息统计、FR-PREF-05 修改偏好值 | 未实现或无入口。**FR-TASK-05 修正剩余时长已全部落地**：服务语义见提交 `e06d26e`（只改剩余时长不改预计时长、非正值被拒绝、允许上调，并经 `TaskCorrectionLog` 保留前后值与方向）；数据层见 schema v3 的 `task_corrections` 表与 `DriftTaskCorrectionLog`（已接入 `main.dart`）；**界面入口见本轮的任务详情页**——`/tasks/:taskId` 上可查看任务事实并修正剩余时长，四个 widget 测试覆盖"从界面修正后任务被更新且修正历史真的被写下"、非正值被拒且不留历史、任务不存在时明确说明。`TaskService` 另补 `findById`，因为 `watchOpenTasks` 只返回未结束任务，用它去找会把"任务存在但已结束"误判为"不存在"。**R9 其余项仍缺**（任务转固定日程、恢复处理入口、专注**重算**（补录已实现）、精力与休息统计、修改偏好值；**"批量状态变更"已完成**）。**批量状态变更（FR-TASK-03）本轮实施**：任务清单页新增"多选"模式，进入后**点整行是选中／取消选中**而不是"完成"——两者都是"点一行"的自然含义，同时生效会让点击结果不可预料，因此进入多选就明确切换语义；另有"取消所选项"，**空选择时按钮禁用**（不给一个作用不到任何对象的按钮），退出多选即清空选择。用例三条：**批量只作用于所选**（未选中的那条必须原样不动，这是"批量"最易错的地方）、空选择时按钮不可用、退出后重进选择已清空。**批量改写字段已补上（本轮）**：多选后可用一个下拉把所选项统一设为同一优先级（`setPriority`，串行写入，空选择时禁用）。用例断言**只作用于所选项**（未选中的那条必须原样不动）、并给出结果文案。**仍未做的部分**：批量改写**截止日期**（它需要时区换算，与"设置截止时间"同一处依赖，而批量场景还要决定"统一设为哪一天"的交互）。**排序也已补上（本轮）**：清单页加"默认顺序／按截止时间／按优先级／按预计时长"四种；**默认不排序**——Dart 的 `List.sort` **不保证稳定**，用"全部返回 0"的比较器去"保持原顺序"不可靠，因此默认顺序干脆**不调用 sort**；按截止时间时**无截止时间的排最后**（不是"最早到期"，但也不该因缺字段挤到最前）。用例**断言真实顺序**（用控件纵坐标比较）并证明排序**确实反转**了默认序，**变异验证**：把优先级比较改成不取反即失败（`Expected: a value less than <479.2> / Actual: <551.2>`）。**我第一版用例只断言"三条都还在"，与顺序无关——那是自证，已改成顺序断言**。这样 FR-TASK-03 里：状态变更 ✅、优先级批量改写 ✅、**排序 ✅**；**批量改写截止日期也已补上（本轮）**：多选后"统一设为截止日期"，与单条设置**同一口径**（当天本地 23:59）。**一处刻意的签名选择**：回调收的是"**一组 id + 一个本地日期与分钟**"而不是逐条回调——整批共用同一天，**换算只需做一次**，且逐条回调会让"部分失败"更难解释；页面仍**不认识时区**，换算在路由完成。用例断言**整批一次调用**、只含所选 id、分钟为 1439。**验证口径**：路由里的换算与写入属组合根装配，**没有自动化测试**（本仓库历来如此），被验证的是页面的契约与调用次数。**专注补录（FR-FOCUS-04）本轮实施**：`FocusService.recordCompleted({taskId, minutes})` 以"**已完成＋已确认**"凭空建一条记录（时长由调用方给出、结束时刻取"现在"、开始时刻由时长倒推），因此它与计时产生的记录一样**进入统计与学习证据**——这正是补录的意义，否则它只是一条本地便签；**刻意不写 `_current`**：补录是历史记录，塞进当前会话会让界面把一条历史显示成进行中。入口在专注页（它**已持有 `FocusService`**，因此本次**不需要任何装配**）。两条用例：落库且状态为 completed+confirmed、起止相差恰为所填分钟数、且"当前状态"仍显示未开始；以及非正时长被拒且**不写库**。**专注重算仍待决策**（撞 `remainingMinutes > 0` 这条域不变量，见本行前文三条语义）。**其中"任务转固定日程"（FR-TASK-04「支持将有明确时间的事项转换为固定日程」）本轮探明两件事，其中一件需先决策**：**(a) 数据模型无法表达"转换"** —— `CalendarEvent` 的字段只有 `id`／`title`／起止／`timeZoneId`／`recurrenceRuleId`／`exceptionOfId`／`locked`／`areaId`／`updatedAtUtc`，**没有指向任务的字段**，因此"转过去"之后**任务仍在待办里**，而固定日程按 §7.2 是"默认不可被自动移动的时间占用"，于是同一件事会被**排两次**（一次作为占用、一次作为待排任务）。**(b) 因此"任务之后怎样"必须由产品决定**，三条路各有代价：**标记完成**（最贴近"转换"的字面，但这是在用户没点"完成"的情况下改任务状态）、**标记取消／归档**（语义是"不再作为任务"，但同样自动改状态）、**保持不动并要求用户自己处理**（不改状态，但把重复占用的风险留给用户，需要在界面上明确提示）。**不需要决策、可直接做的部分**：从任务页把**标题与所属领域**预填进事件编辑器（`EventDraft` 已有 `areaId`），时刻由用户在编辑器里选定——`/calendar/new` 目前**不接受任何参数**（起点固定为"今天本地 09:00"），因此需要给它加预填参数（约 1 个编辑），任务页加一个入口并注入回调（约 3 个编辑）。**在 (b) 选定之前，我不实现"转换"这一步**，避免造出会重复占用的半成品。**本轮已实施，采用的是上文选项 (c)（保留任务、明确提示）——这是我按"默认选定"替你定的**：任务详情页新增"转为固定日程"按钮（按键 `create-event-from-task`），**只把标题**带到 `/calendar/new?title=...`，事件编辑器据此预填标题；按钮下方**固定显示提示**"只创建一条固定日程；这条任务仍在待办中，需要你自行处理"——这不是装饰：默认选定"不动任务"，没有这句话用户会在同一件事上被排两次。**为什么要选 (c) 而不是 (a) 标完成**：(c) **不替用户改任何数据**，而 (a)(b) 都会在用户没点"完成"的情况下改状态。**两处如实说明**：① **"所属领域"无法预填**——事件编辑器**没有领域控件**（切片 A 未加），与其做一个"像是转换"的入口，不如写明"创建完还需自己补领域"；② 因此这一项**不是**"一键转换"，而是"带着标题的创建入口 + 一句提醒"。**两条用例**：交出的是**这条任务的标题**（否则用户到编辑器还要重输）、未接线时**不显示按钮**。**对在途 R4 实现的核对（本轮，只读）**：按上文的清单逐条对照并发写者尚未提交的 `drift_calendar_repository.dart`，结果有三点值得记：**① 他们的做法比我清单里的方案更简洁**——单次事件用 `recurrenceRuleId.isNull()` 过滤、锚点由 `innerJoin(recurrenceRules)` 取出，因此锚点**不会**被当成单次事件重复输出（清单第 ④ 条要防的正是这个）；**② 我清单第 ⑤ 条的理由是错的**：我当时写"排程输入按 id 去重，复用规则 id 会让不同日期互相覆盖"，但核实 `RepositoryScheduleProblemSource:106-108`（`fixedIntervals` 是逐个 `BusyInterval` 加入的**列表**）与 `InputSnapshotBuilder`（哈希里 `fixedIntervals` 含**每一次出现及其区间**），可知**并不按 id 去重**，且哈希能区分不同日期的区间；日视图一次只显示一天，因此也不会出现重复 Key。所以他们让每次出现共用锚点 id **在今天的代码路径上是可接受的**，我那条"必须各自 id"的断言与理由都不成立——**保留的只是一个将来的约束**：若日后有任何地方按"出现 id"做键（例如拖动或按 id 匹配），这一点必须重新审视；**③ 一处静默退化**：锚点的规则行若缺失（正常路径不会，`saveRecurring` 在**同一事务**里写事件与规则），由于单次查询排除了 `recurrenceRuleId` 非空的行、而 join 又取不到规则，该事件会**整条消失**而不是退化为"只显示这一次"——概率低，但值得在后续加固时补上。**FR-REPLAN-07"处理入口"本轮已核实其构成**：规格要求"提供调整优先级、修改截止日期、修正预计时长、取消事项或临时放宽每日上限等处理入口"，而任务详情页现有的是**项目选择、期望时段、剩余时长修正与标签**（`task_detail_page.dart` 的 DropdownButton／`correctRemainingMinutes`／`setPreferredWindow`／标签区），**优先级、截止日期、取消事项三者的编辑都不存在**；`TaskService` 的公开方法为 `watchOpenTasks`／`findById`／`quickAdd`／`saveDraft`／`correctRemainingMinutes`／`assignProject`／`setPreferredWindow`，**没有单字段更新**（如 `setPriority`）。**一处设计层面的事实须记住**：`task_service.dart:121` 明确写着"**只改剩余时长，不改预计时长**：预计时长是原始估算"，因此"修正预计时长"是**刻意不支持**的（改的是剩余时长），登记时不应把它当成遗漏。**最便宜的入口是"调整优先级"**：服务加 `setPriority`（读—改—存）＋详情页复用一个既有 Dropdown 模式＋一条 widget 测试，约 5–7 个编辑，是这一族里可单独交付的一项。**"取消事项"已实施（提交 `0f0c6d9`，比优先级更便宜）**：服务侧的 `changeStatus` **早就存在**，缺的只是入口，因此在任务详情页"开始专注"旁加了"取消事项"，点击后调用 `changeStatus(taskId, cancelled)` 并重载；**已取消后隐藏该入口**（重复点击一个已生效的动作没有意义）。用例同时断言两半：**点击真的落到存储**，**且入口随后消失**——只断言状态变化会漏掉后一半。**这一族的剩余**：设置截止日期与临时放宽每日上限。**"清除截止时间"已实施（提交 `0d0575c`）**——它是"修改截止日期"里**不需要时区换算的那一半**：设置要把本地日期换算成 UTC，而详情页没有注入时区，因此那一半仍需先打通（穿透组合根，约 4–6 个编辑）；清除不需要换算，且对"已逾期"的任务正是实用的一半。服务方法 `setDueDate(taskId, DateTime?)` 接受可空 UTC 时刻并拒绝非 UTC 值，用模型的哨兵 `copyWith` 表达"置空"（我初稿误用了 drift 的 `Value`）。入口只在有截止时间时出现；用例断言"存储被置空 + 入口消失"两半，我第一版还按**全局文案计数**断言"未设置"，而该页在期望时段为空时也会显示同一文案（实测 **2 个匹配**），运行把它挡下了——该断言因此**删除而不是放宽**。**验证口径**：`flutter analyze` 无问题，全量 **334 项通过**，提交再次被门禁在全量绿之后生成。**"清除"的变异验证（本轮补）**：把该动作改成 `setDueDate(taskId, task.dueAtUtc)`（传回原值、根本不置空），用例失败于 `Expected: null / Actual: DateTime:<2026-10-20 00:00:00.000Z>`——说明"存储被置空"这条断言确有**判别力**，而不是因别的原因通过。**"设置截止时间"已实施（本轮）**：页面用**日期选择器**取本地日期，并固定以"当天本地 23:59"为口径，把 (日期, 分钟) 交给**注入**的回调；**时区换算是路由的事**（它持有 `zones` 与 `timeZoneId`），页面本身不认识时区——与"导航由外部注入"同理，环境知识不进页面。用例驱动**真实**日期选择器并断言交回的是"挑中的那一天 + 23:59"，口径若变即失败。至此 **FR-REPLAN-07 的截止日期一项完整**（设置 + 清除）。**已由并发写者实现（提交 `99e60a5`，本行据此更正）**：`preference_service.dart`（+43）、`preference_analyzer.dart`（+36）、`preferences_page.dart`（+165）与其 widget 测试（+34）已把"修改学习建议"接成可用功能（测试名："修改学习建议后保持待确认且新值可见"）。**我此前那条判断的效力范围须说清**：它描述的是**当时**的事实（当时 `PreferenceService` 公开方法里确实没有任何修改入口），因此结论"不是纯界面活、须先在服务层表达"在当时成立；现在该入口已在服务层存在，故**登记改为已实现**，不是"我判断错了"。**留下的教训是记账层面的**：本行在并发写者工作期间被当作"仍缺"，导致我两次按"缺口"去设计——**在有并发写者时，登记应标注"他人进行中"**，本轮把这一条写进 W10 的并发写者段落——**当时的状态**（供对照）：公开方法只有 `refresh`／`list`／`confirm`／`reject`／`disable`／`clearLearned`／`undoLastAutoApply` 与一个私有的 `_change`，确实没有任何"修改建议值"的入口；据此估的 **6–8 个编辑**与**实际落地规模吻合**（服务 +43 行、页面 +165 行、分析器 +36 行）。**本轮对"专注重算"（FR-FOCUS-05）做了定点核实，发现它撞上一条域不变量，需先决策而不能自行选一种语义**：① 事实是**没有任何调用点**——`TaskService.correctRemainingMinutes`（`task_service.dart:129`）确实存在且语义完整（只改剩余时长、拒绝非正值、经 `TaskCorrectionLog` 保留前后值），但**全库只有任务详情页在调用它**（`task_detail_page.dart:197`），专注结束时不会更新剩余时长，因此"完成专注后剩余时长自动减少"并未实现。② **接线点已经有了，不必新建**：W6 为学习闭环加的 `FocusService.onFinished` 回调（组合根装配）就是天然的落点。③ **真正的障碍是模型不变量**：`PlannerTask` 要求 `remainingMinutes > 0`（`task.dart:67` 的 `_requirePositive`，且 `correctRemainingMinutes` 显式拒绝 `<= 0` 并给出"剩余时长必须大于 0 分钟"），因此"专注把剩余时间用完"这件事**无法表示**。可选语义三条，各有代价、我不替用户决定：**(a) 下限截到 1 分钟**——改动最小，但"还剩 1 分钟"对一个已做完的任务是**假信息**，会继续被排程器当作待办；**(b) 放宽不变量允许 0**（0 表示"无需再排"）——最贴近事实，但要动域模型与其全部校验路径，且需确认排程器对 0 的处理；**(c) 聚焦结束时若剩余被用尽则**自动把任务标记为完成**（改 `status`）——语义清楚，但这是**在用户没点"完成"的情况下改任务状态**，属产品决策。**在选定之前不动手**：任何一种都能在一轮内接完（接线点已存在，服务方法已在），但选错会把假信息写进用户的任务列表，比不做更糟 |
| R10 | FR-DATA-08 核心数据含创建与修改时间 | **范围已扩充（复核发现漏登记）**：除原列的 `Areas`、`Projects`、`ScheduleBlocks`、`TimeEntries` 与 `CalendarEvents.createdAtUtc` 外，**`RecurrenceRules`、`EnergyWindows` 同样没有任何时间戳，`Settings` 缺 `createdAtUtc`**——FR-DATA-08 要求"每条核心数据"都包含，因此一并纳入。**已决策（用户选择方案 1）**：历史行时间戳填**迁移时刻**，列保持非空。技术约束：SQLite **不允许**直接 `ADD COLUMN ... NOT NULL` 而没有默认值，因此实现为"声明 `NOT NULL DEFAULT 0` + 迁移时 `UPDATE ... WHERE 列 = 0` 回填迁移时刻"，并在仓库层保证新建记录始终写入真实时间；哨兵值 0 的含义（尚未设置）需在 §4.2 写明。`PlanVersions`/`PreferenceEvidence`/`ChangeLog` 属于不可变记录，各自已有创建时刻且不需要修改时刻，保持不变 |
| R11 | spec §13 以本机当前时区保存和展示 | **主体已实现**（提交 `bd3603e`、`f2a051a`）：新增 `LocalTimeZoneResolver` 按本机当前 UTC 偏移定位 IANA 标识、计入夏令时、区分"精确匹配"与"近似"；组合根 `main.dart` 已在启动时解析并逐层传下去，不写死 `'Asia/Shanghai'`。**已登记的最后一项已完成**：`SpecialDayPage.timeZoneId` 的默认值 `'Asia/Shanghai'` 已删除并改为必填——该页此前没有任何路由（见 W3），只有测试构造它，但默认值意味着任何忘记传参的调用方都会静默按东八区解释用户填写的结束时间，而在其它时区这只会表现为"时间算错"，不会报错。改为必填后，"忘记传"是编译错误。**同类隐患已处理，且登记指错了载体**（提交 `b8a3649`）：原记"`NotificationService` 与 `CalendarService` 的 `timeZoneId` 仍带默认值"。`NotificationService` 确实有，而且它**已在生产装配**（`main.dart`），所以不再是"没有构造点、因此无害"的状态——已改为必填。`CalendarService` 则**根本没有这个参数**；真正的载体是**表单输入对象 `EventDraft`**，情况比"隐患"更严重：`EventDraft.timeZoneId` 默认 `'Asia/Shanghai'`，而它唯一的构造方 `EventEditorForm` **从未传过它**，于是界面上保存的每条固定日程都被标成东八区，与需求 §13"以本机当前时区保存和展示"相悖，且在其它时区只表现为结果错误、不报错。它之所以一直不在可见清单上，只是因为 `CalendarService` 至今没有生产构造点。现两处均改为必填（漏传即编译错误），表单改为接收并透传调用方给出的时区。测试刻意断言 `'Europe/Berlin'` 而**不是**东八区——用东八区断言在修复前同样会通过，等于什么也没证明；变异验证：把表单写死为 `'Asia/Shanghai'` 即失败（`Expected: 'Europe/Berlin' / Actual: 'Asia/Shanghai'`），正是该缺陷本身。**该项的最后一处同类默认值已于后续完成**：`PlannerApp.timeZoneId` 改为**必填**（此前默认 `'Asia/Shanghai'`，忘记传就会把整个应用按东八区解释用户看到的本地时间——作息、日界、"今天"是哪一天——而在别的时区只表现为算错、不报错）。**13 个测试文件、15 个构造点**一次性显式传入 `'Asia/Shanghai'`：这正是它们此前**隐式依赖**的值，因此是零行为变化的"把隐式变显式"，而不是顺手改了测试的时区。过程中分析器抓到 `integration_test/first_plan_flow_test.dart` 一处**重复传参**（它本来就传了），并顺带说明 integration_test **不参与 `flutter test`**——所以那一处必须靠分析器而不是测试来发现。**已知局限**：同一偏移可能对应夏令时规则不同的多个时区，仅凭偏移无法区分；彻底解决需平台能力（Windows `GetDynamicTimeZoneInformation`）或首次引导中的用户选择——近似情形目前只在开发期记录诊断，用户可见提示待首次引导实现 |
| R12 | spec §7.1 任务状态 8 种 | **已实现**（提交 `39ed7b7`）：补上 `scheduled`（已安排）与 `overdue`（已逾期）。两者**由事实派生、不落库**——`overdue` 只取决于"截止已过且任务未结束"，时间流逝本身即可成立，没有写入时机；`scheduled` 取决于"已确认计划中是否存在该任务的块"，若另行落库就会产生第二个事实来源，撤销与重排必然不同步。`PlannerTask.statusAt` 定义优先级：已结束 > 已逾期 > 进行中 > 已安排 > 用户设置的状态；`TaskStatusSemantics.isClosed` / `isStored` 标明哪些值可持久化。**待接线**：① 任务清单此前只有完成勾选框、不展示派生状态，本轮已补上"已逾期"（`TaskListPage` 新增必填的 `nowUtc`，由路由器传入，并有 widget 测试）；② 统计的按状态筛选仍读数据库列，因此**不支持**按 `overdue`/`scheduled` 筛选——这不只是"再读一列"的问题：筛选谓词只有窗口起止（`AnalyticsFilter`），而"是否逾期"需要参照"现在"，因此要改 `AnalyticsQuery.query` 的签名以接受参照时刻，属接口改动 |
| R13 | 生活任务标记无数据来源 | **推导已接通，写入仍缺**：按用户决策采用领域级 `areas.is_life`，经 `tasks.project_id` → `projects.area_id` → `areas.is_life` 推导。新增 `LifeAreaLookup` 端口与 drift 实现（三表内连接），排程装配据此设置 `SchedulableTask.isLifeTask`（此前从未设置，`lifeQuota` 因子恒为 0），统计侧改为读该列并删除"领域名包含生活/娱乐/休息/life"的猜测——名字匹配既漏（"家庭""健身"不算生活）又错（"生活服务业项目"会被算成生活）。**进展与仍然存在的断点**：写入路径已在服务层落地，且启动时会建立默认领域并把"生活"标记为生活领域（提交 `5cad681`），因此 `is_life` 不再是恒 false。**服务层的归属入口已补上**（`TaskService.assignProject`，提交 `cb6eea0`），并有测试证明"归属到生活领域下的项目后，生活标记立即对该任务生效、取消归属立即失效"。**现在用户真的可以触发了**：任务详情页的"归属项目"区在项目为空时会**说明原因**，并提供**"新建项目并归属"**（选领域 + 填名称 + 一次点击即建立并归属）。因此全新安装下用户也能把任务归属到领域下的项目，`lifeQuota` 因子与统计的"生活"分类**首次在真实用户路径上生效**。此前"控件已就绪却点不动"的原因是默认初始化只建领域、不建项目，而项目只能由代码创建——这个教训保留下来：**链条的完整性取决于数据是否可得，而不只是入口是否存在**。**管理界面已补齐**（提交 `ccd5dc9`）：`/workspace` 可新建与改名领域、切换生活标记、新建与归档项目，因此"标记哪些领域算生活"从代码里搬到了用户手上，原先"仍缺一个管理界面 + 四处穿线"的待办已清空。本条保留"结构就绪 / 有写入方 / 界面可用 / 需求兑现"是四级不同的事这一教训——这些层都已完成并有测试的时期里，该能力在真实用户路径上仍然等于不存在。界面不含删除，理由见 R2 行。另：③ 周视图"生活"类别同源，曾同样卡在项目归属上，现随本项解决（该类别由 `is_life` 推导，而用户现在能设置它并归属任务）；④ `is_life` 为 `NOT NULL DEFAULT false`，无法区分"用户明确标为非生活"与"从未设置"，若将来要保留启发式兜底需改为可空。片段间休息已按用户决定对所有任务一律强制，不读取该标记 |

#### 13.0.6 测试与流程

| 编号 | 问题 |
| --- | --- |
| T1 | 本文档实现前 122 个任务复选框全部未勾选，spec §18 的 19 项验收全部未勾选，进度追踪失真（本次修订已勾选 Task 1–19；spec §18 须待 Task 20 验收后逐项附证据再勾选） |
| T2 | 存在断言不可达状态的测试 | **两项经核实均已失效，本项关闭**（提交 `0f25fd2`）。① `plan_preview_test.dart` 手写 `PreviewChangeKind.split`：`plan_differ.dart:89` 现在**确实会**产出 `PlanChangeType.split`，原前提"生产永不产生"不成立。**但同一轮 grep 发现了相反的问题**：`PlanChangeType.split` 在**全库测试里一次都没出现**——"会产出"这条分支从未被断言（渲染一个 split ≠ 决定一个 split），因此新增 `plan_differ_split_test.dart` 覆盖该合取条件的三种组合，并做变异验证（把 `&&` 改成 `\|\|` 即让两个反向用例失败，`Actual: PlanChangeType.split`）。② `app_smoke_test.dart` 断言首启显示引导文案：门控**确实已接线**（`planner_app.dart` 中 `_onboardingRequired` 决定是否渲染 `OnboardingPage`），且该文件第二个用例通过写入 schema 键拿到导航栏，证明门控本身有判别力——因此这条断言描述的是可达行为，而不是因"未接线"而碰巧通过 |
| T3 | 存在恒真/复述断言与公式自证 | **魔数一项已修**（提交 `fcfa9d7`）：`candidate_generator_test.dart` 的 `hasLength(169)`／`hasLength(13)` 改为**推导式**——前者是"各合法时长在 120 分钟窗口内的 5 分钟起点数"之和，后者是"180 分钟窗口内 120 分钟整块的合法起点数"。核实方式：推导式与实际输出一致，说明那两个数字确实可推导、并非随意。**口径**：这是**可读性修复**而非判别力提升——计数一变两种写法都会失败，收益是断言自带规则、失败信息可读，不夸大。**最后一项已完成，本项关闭**（提交 `a849c7a`）：`database_schema_test.dart` 两处都比本行原先写的更糟——① 拿 `database.allTables`（drift **依据 schema 声明生成**的列表）与字面量比对，等于把声明抄一遍，**看不见"迁移里漏了一句 CREATE TABLE"**，而那正是该用例标题所声称要检查的事；现改为查 **SQLite 自己的目录**（`sqlite_master`）并作等值比较，等值通过还顺带**确认了一件我此前只是假设的事**：drift 在这里不建任何额外的非内部表，因此不需要过滤。② `throwsA(anything)` **接受任何失败**——SQL 打错也会通过，而该用例要证明的是"**外键**拒绝了这次删除"；现要求异常文本提到 `FOREIGN KEY`，并用**变异证明**而非仅仅声称这个差别：把表名改成 `projectz` 后 SQLite 抛 `no such table: projectz`，新断言拒绝它、而旧写法会接受它。这正是 T3 针对的失效模式——**不会失败的测试比没有测试更糟，因为它报告了并不存在的覆盖**。**`default_settings_test.dart` 已核实并更正本行判断**（提交 `be093c1`）：本行原把它列为"恒真/复述"，但读过后**两条断言都成立**——第一条钉住设计文档默认值表里的具体数值（对默认值模块而言那就是规格），第二条钉住"临时例外 > 用户设置 > 已确认偏好 > 默认值"的解析优先级；把它算作"复述实现"是**我此前判断不准**。它真正缺的是用例名所声称的东西：新增用例断言这些数值**之间的关系**（夜间区间按环绕计算不短于最低睡眠；精力区间按时间递增且**互不重叠**——重叠意味着同一时刻有两个精力等级，排程无从取舍；每档各出现一次；粒度整除专注时长，否则排出的块会落在粒度网格之外；容量类默认值为正，因为 0 等于"不安排任何事"）。**口径（变异验证）**：把 `minimumSleepMinutes` 改成 500 时**两条用例都会失败**，因此对**单值**改动它并未增加判别力；增加的是**失败信息的形状**——快照报 `Expected: <420> / Actual: <500>`，它报 `Expected: a value greater than or equal to <500> / Actual: <480>`，点明被违反的关系；另外"粒度整除专注时长"此前**无处可钉**。不夸大为"补齐了覆盖"。**公式自证一项也已修**（提交 `1abf5ff`）：`pressure_calculator_test.dart` 原先的 120／252 就是实现算式的输出，没有说明为何该是这些数；现每个数字**当场推导**（截止前可见容量 420／总容量 1260 = 1/3 → 360 的 1/3 = 120；后期仅剩 180 → 缺口 180、按比例 252，取较大者），并补三条**不依赖该算式**的性质（目标不超过任务本身；总容量为零时退化为"整份都要排"而不是零；削减后期容量不会让当下该做的量变少）。**诚实的限界**：把 target 规则里的 `max` 换成 `min` 会让两条推导用例失败（`Expected: <120> / Actual: <0>`、`Expected: <252> / Actual: <180>`），但**单调性用例在该变异下通过**（序列 0,0,0,180,360 仍单调）——因此性质是**补充而非替代**，真正抓到它的是具体用例；这一点写进登记，不夸大成"性质提升了判别力" |
| T4 | 测试类型缺口 | **本项已闭合**：五条主张中**三条经核实已被后续提交补上（是本行未同步的疏漏）**，另两条各自修完——④ golden fixture 的 UTC 单一化用"紧凑场景"用例闭合（`4d71cf6`），⑤ 并发交错从"缺用例"查成一**真实缺陷**并修复（`a35afd2`）。逐条如下。① **"无 integration_test" 不成立**：`integration_test/` 有 3 个文件（`first_plan_flow_test.dart`、`emergency_replan_flow_test.dart`、`backup_restore_flow_test.dart`）。② **"无迁移测试" 不成立**：`test/drift/app_database/schema_migration_test.dart` 存在，覆盖 v1→v3。③ **"DST 仅一处且引擎层为 0" 不成立**：现共 **7 处**，其中排程/引擎层至少三处（`preferred_time_window_test.dart:100`、`protected_time_expander_test.dart:132`，均以 `America/New_York` 2026-03-08 切换日为场景），另有 `time_zone_test.dart:44`、`local_time_zone_test.dart:52`、`recurrence_expander_test.dart:11`。**这三条是我登记的疏漏**——它们是被后续提交逐个补上的，本行却没有随之更新，于是"缺口清单"里躺着三件已经做完的事。**仍成立的两条**：④ **golden fixture 固定 `UTC`**（`golden_week.json:2`，被 `schedule_engine_test.dart:20,126` 使用）**成立，但修法不是"再加一个时区"**：该 fixture 内嵌 `expected.blocks` 的**精确输出**，新时区的期望值只能由引擎自己生成，那样得到的 golden 只能钉住**未来回归**、**不能验证当前行为**。我按这个思路做了非 UTC 的不变量用例（提交 `ad49b04`：同一 fixture 只把时区换成 `America/New_York`，断言块不重叠、都在窗口内、睡眠按当地钟点成立、已排＋未排＝需求），**但变异验证证明它不能判别时区正确性**——把 `availability_builder` 里"本地钟点 → UTC"的换算改成忽略时区后，**9 条用例全部通过**；原因是该 fixture 容量宽裕（7 天 × 每日约 8 小时余量），引擎把块放进"两种解释都允许"的区间就够了。我初稿注释里那句"若引擎把本地钟点当 UTC 用，睡眠断言会失败"**被自己的变异证伪**，已在用例注释中改写为相反的说法。**该专门场景已建成，此项闭合**（提交 `4d71cf6`）：新增 `schedule_engine_time_zone_test.dart`，**直接构造问题**而不经 JSON fixture——纽约 EST 下本地 20:00 睡眠 = `01:00Z`，固定日程盖住 `13:00Z–01:00Z`，因此窗口取 `01:00Z→01:00Z` 时**没有任何空闲**，任务必须如实报出缺口；同一问题换成 `UTC` 则 `08:00Z–13:00Z` 可排——两种语义对同一个问题给出**相反结论**。变异验证（把 `availability_builder` 的换算改成忽略时区）：**该用例失败**（`Expected: empty / Actual: [Instance of 'PlannedBlock']`），而 UTC 那条仍通过，说明它确实具备判别力，与 `ad49b04` 那条冒烟用例不同。**过程中还修正了我自己的一个错误**：首版窗口起点取 `00:00Z`，引擎在 `00:00Z–01:00Z` 排了块——那一小时是本地 19:00–20:00（睡眠开始之前），**确实空闲**，即**引擎正确、我的场景不够紧**；起点改为 `01:00Z` 之后才真正"零空闲"。若仍要新增精确 golden，必须标注它是**回归钉子而非验证**。⑤ **"无真正的并发交错测试" 已闭合：定位出一处真实交错缺陷并修复，留下一条可执行用例**（提交 `a35afd2`）。范围先按"本应用是单用户本地应用"收窄：真正可能交错的只有 drift 事务与专注计时器。**先排除一个候选**：`SettingsService.saveDateOverride` 看似"读—改—写"，实际是**整块覆盖**（不 merge），后写者胜出属**定义好的语义**而非静默丢更新——核实过才排除，没有凭外观下结论。**确认存在的缺陷在 `FocusService.finish`**（`focus_service.dart:175`）：它确有幂等保护 `if (session.phase == FocusPhase.finished) return session;`，但 `_current` 是在 `await store.save(updated)` **之后**（第 189–190 行）才赋值，所以在第一次 `await` 让出执行权期间，并发的第二次 `finish()` 读到的 `_current` **仍是 running**，保护失效。后果有两条：`onFinished` **触发两次**（重复写入一条 `focusCompletion` 偏好证据，而分析器按"20 条 / 14 天"门槛判定，重复计入会扭曲学习结果）；会话结束时刻可能被后一次覆盖。**拟修法**：让并发的 `finish()` **共享同一个在途 Future**——首次进入时建立 `_finishing = _finishOnce(note)` 并返回它，后续并发调用直接返回同一个 Future，于是只结束一次、只触发一次回调；原有的 `phase == finished` 保护保留，用于"完成之后再调用"的情形。**已按"红→修→绿"走完**：用例先红（`Expected: <1> / Actual: <2>`，即完成回调确实触发两次），修好后转绿；**红→绿这一步本身就是判别力证据**，比另做一次变异更直接。**修法的关键取舍**：把 `_current = updated` 提到 `await` 之前也能关掉窗口，但会**破坏"写入失败时内存状态不提前变化"这条既有保证**（相邻用例专门钉住它），因此改用"并发调用共享同一个在途 Future"，两者同时成立。**顺带值得记的一点**：该文件第一条用例的名字就是"重复点击幂等"——保护本就是为这个顾虑写的，只是**漏了并发这一半**；所以新用例是**并列**在它旁边，而不是取代它。**本轮未改代码**：④ 需要先造出跨切换点的场景，⑤ 需要先定交错点，两者都属"先界定再写"；硬凑一个只会得到不会失败的测试，正是 T3 刚清掉的那种 |
| T5 | 无 CI；`README.md` 与 `pubspec.yaml` 保留 Flutter 模板内容；`可运行程序/` 为 debug 产物且既未跟踪也未忽略；`.superpowers/` 账本（含全部 Ruling 决策）被 `.gitignore` 排除，未纳入版本控制 |
| T6 | §14 完成定义要求"文档接口名与实现一致"，但本计划此前已出现 `ConflictCode`、`planningStartUtc/EndUtc`、路由表、目录结构等多项漂移，说明该条未被实际执行 |
| T7 | 以真实耗时为准的基准用例余量过窄 | **已修**（提交 `1c0887b`）。原先断言"单次采样 < 300ms"，整轮并发时实测 345ms 而失败、单独连跑三次为 144/138/145ms——即"会随机失败的门禁"。现改为**预热一次 + 三次取最小值 + 上界 3000ms**：预热把首次查询的解析与预编译成本排除在测量之外，最小值对调度噪声远比单次采样稳健。实测：单独跑 46/47ms，**整轮并发跑 105ms**（同一负载下旧写法是 345ms），余量约 28 倍。**口径**：它仍以真实耗时为准，因此是"防数量级退化的防线"（例如不小心写成 N+1 会到秒级），**不是性能门禁**——真正的性能门禁需要独立的基准装置，而不是混在功能用例里；这一点已写进用例注释。正确性断言未动（仍须报出 300000 分钟），因此它无法靠"查询不再干活"而通过 |

#### 13.0.7 C1 与 C2 的实测结果

以下数据由直接运行 `lib/scheduling/` 的纯 Dart 代码得到（该模块不依赖 Flutter），因此可复现。

**C1 片段间休息**

使用仓库自带的 golden 周场景（`test/fixtures/scheduling/golden_week.json`；该 fixture 已传入 `breakMinutes: 10`，但引擎此前完全不读取它）：

| 方案 | 实测结果 |
| --- | --- |
| 现状 | research 排入 4 段 90 分钟，12:00→18:00 首尾相连，片段间隔 0 分钟；`isFullyFeasible=true` |
| 软约束惩罚（新增评分因子） | 分片方式改变（变为 6 段），间隔仍为 0 分钟；golden 期望失效而需求仍未满足 → **已放弃该实现** |
| 硬约束（生成阶段要求间隔 ≥ `breakMinutes`） | 间隔 30 分钟，research 仅排入 270/360 分钟，`isFullyFeasible=false`、`unscheduled=[research:90]`；golden 期望失效 |

原因：候选排序以 `coverageMinutes` 为首键，软约束总分只在覆盖度相同时才起作用，因此惩罚项几乎不改变选择；而单纯的硬约束会让"空闲窗口恰好等于任务时长"的场景损失约 25% 容量，因为 `_continuationCapacity` 会把候选**之前**的空闲段也计入可续排容量，诱导引擎为了腾出一段用不上的空隙而把片段推后。

**决策（2026-10-02）：采用方案 C** —— 硬约束 + 让续排容量按休息预算计算。实现方式：只在候选结束后、经过 `breakMinutes` 的时刻起统计后续可用容量。实测结果（同一 golden 场景）：

| 阶段 | research 排入量 | 片段间隔 |
| --- | --- | --- |
| 修复前 | 360/360 分钟 | 0 分钟（四段 90 分钟首尾相连） |
| 仅加硬约束 | 270/360 分钟 | 30 分钟（浪费 90 分钟） |
| 方案 C（已实施） | 330/360 分钟 | 10 分钟（4 段，如实报告缺口 30 分钟） |

方案 C 的代价被压到 8%，且缺口按 FR-REPLAN-06 如实报告；`algorithmVersion` 因此提升为 2。同时 `spec` §9.3 的硬约束新增"片段间休息"一条，使需求与实现一致。

**后续决策（同日）：把休息从"同一任务的两段之间"推广为"任意两个非生活任务块之间"，仍为硬约束。已实施（提交 `f49a4ec`）。**

实测（窗口 09:00–18:00，各 60 分钟的任务，`breakMinutes` 默认 10）：

| 场景 | 改动前 | 改动后 |
| --- | --- | --- |
| 两个非生活任务 | 相邻，间隔 0 分钟 | 间隔 10 分钟 |
| 三个非生活任务 | 连续三块，间隔 0 / 0 | 间隔 10 / 10 分钟 |
| 非生活 + 生活 | 相邻，间隔 0 分钟 | 间隔 0 分钟（豁免） |
| 两个生活任务 | 相邻，间隔 0 分钟 | 间隔 0 分钟（豁免） |
| golden 周场景 | — | **输出不变**（各任务本就在不同日期与时段，无新增损失） |

实现要点（v3）：`_violatesRestGap` 不再以 `taskId` 相等为条件，而是判断"两侧是否都是非生活任务"；连续任务不再豁免；`_restReadyAt` 对生活任务返回候选结束时刻而不是 null。`algorithmVersion` 提升为 3。

**最终决策（同日，取代上一条）：取消任务类型区分，所有任务块之间一律保留休息。** 上一条中的"非生活"限定随之作废；此外该豁免在真实运行中本就不可达（`PlannerTask` 没有生活标记，装配恒传 `isLifeTask: false`，见 R13），因此简化后语义与运行期行为一致。

| 场景 | v3（区分类型） | v4（不区分类型） |
| --- | --- | --- |
| 两个普通任务 | 间隔 10 分钟 | 间隔 10 分钟 |
| 三个普通任务 | 间隔 10 / 10 分钟 | 间隔 10 / 10 分钟 |
| 普通 + 生活 | 间隔 **0**（豁免） | 间隔 **10** |
| 两个生活任务 | 间隔 **0**（豁免） | 间隔 **10** |
| golden 周场景 | 输出不变 | **输出仍不变**（`blocks match fixture: true`） |

实现要点（v4）：`_violatesRestGap` 只保留"间隔是否小于 `breakMinutes`"一个判断，不再查任务表；`_restReadyAt` 一律返回候选结束时刻加休息。四个场景中各任务仍全部排入（60 分钟任务各排满），未见新的容量损失；golden 周因各任务分处不同日期与时段而未受影响。`algorithmVersion` 提升为 4。

**关于已锁定块**：引擎不移动锁定块，因此若用户锁定的块之间本身间隔不足，引擎不会也无法修正；该规则只用于拒绝新的违规摆放。`PlanValidator` 未增加对应冲突码，原因同上——否则用户锁定的相邻块会让每个提案都被判为无效。

**C2 评分因子的实际作用范围**

对同一任务的 12:00 与 15:00 两个 90 分钟候选调用 `CandidateScorer`，在时段能量等级相同时，**10 个因子的取值完全相同**。结合分配循环（对单个任务遍历候选）可确认：`deadlineRisk`、`priority`、`progressPressure`、`lifeQuota`、`preferredTime`、`sameTaskContinuity`、`categorySwitch`、`movingExistingBlock` 这 8 个因子在同一任务的候选之间恒为常数，无法影响候选选择。实际区分候选的只有 `energyMatch`（随时段能量变化）、`fragmentation`（随片段长度变化）以及排序首键 `coverageMinutes`；其中 `preferredTime`、`sameTaskAdjacent`、`categorySwitch`、`movesExistingBlock` 连取值都从未被引擎注入。

任务紧迫度实际由 `_compareTasks` 的 `_effectiveSlack`（截止前容量 − 目标）决定，这部分实现是合理的梯度而非布尔判断。因此问题不在"`deadlineRisk` 太粗糙"，而在于 §5.4 的评分表把 10 个因子描述为主要决策依据，而其中 8 个在候选层面不生效。修正方向应为文档与实现二选一：如实修订 §5.4/§9.4（任务排序按松弛时间、候选排序按覆盖度与能量/碎片化），或重构为以评分为主决策机制。后者会改变全部排程输出，属于设计变更而非缺陷修复。

#### 13.0.8 结构变更已落地（原环境阻塞已解除）

本节四项结构变更曾因开发环境拒绝派生子进程、无法执行 `dart run build_runner` 而搁置。该限制已解除，`build_runner`、`flutter analyze`、`flutter test` 均可运行，四项已全部实施并提交（提交 `8f9c013`）。表格中的"仍缺"是要如实区分"结构已就绪"与"需求已实现"：

| 编号 | 内容 | 落地情况 |
| --- | --- | --- |
| R1 | 自定义标签（FR-TASK-02、FR-STAT-02） | `tags` 表 + `task_tags` 关联表（复合主键）已建；标签仓库、打标签入口与按标签筛选仍缺 |
| R5 | 期望时段字段（spec §7.1） | `tasks.preferred_start_minute` / `preferred_end_minute`（可空）已建，`preferredTimeScore` 已注入评分（提交 `fb3eb06`）；仍缺任务编辑入口 |
| R10 | 核心数据时间戳（FR-DATA-08） | 除原登记的表外，复核发现 `RecurrenceRules`、`EnergyWindows` 与 `Settings.createdAtUtc` 同样缺失，一并补齐 |
| R13 | 生活标记 | 按决策采用领域级 `areas.is_life`（经项目归属推导）；赋值入口已随 R2 补齐（提交 `ccd5dc9`，`/workspace` 可切换生活标记） |

实施要点，其中第 1 条是与原登记的描述不同的技术约束，第 3 条是实施中发现并修正的语义问题：

1. **SQLite 不允许对已有数据的表直接 `ADD COLUMN ... NOT NULL` 而不给默认值**，drift 迁移器同样不接受。因此新增时间戳列声明为 `NOT NULL DEFAULT 0`，迁移随后把历史行回填为迁移时刻（即用户选定的方案 1：历史值填迁移时刻、列保持非空）。哨兵值 0 的含义是"尚未设置"，仓库层保证新建记录始终写入真实时刻。若要数据库层面严格拒绝 0，需用 drift `TableMigration` + `columnTransformer` 逐表重建，更强但风险更高，暂不作为默认方案，记录于此备选。
2. 时间单位遵循代码库既有约定：**微秒**（`microsecondsSinceEpoch`）。回填最初误用毫秒，已修正并纳入测试断言。
3. 三处 upsert（设置、日程事件、专注记录）改为 `insert(... onConflict: DoUpdate(...))`，冲突分支只更新修改时间、**保留首次写入的创建时间**。若沿用 `insertOnConflictUpdate`，每次保存都会重置创建时间，与 FR-DATA-08 语义不符。
4. `RecurrenceRules`、`EnergyWindows` 目前仍无任何写入路径（R4）；相应入口落地时必须一并写入 `created_at_utc`/`updated_at_utc`，否则会留下哨兵值 0。`Areas`、`Projects` 的写入路径已随 R2 落地（`WorkspaceService` 写入两类时间戳，领域另写 `is_life`），提交 `c34d849` 与 `ccd5dc9`。

验证方式（本机实测输出）：`flutter analyze` 无问题；`flutter test` 159 项全部通过（该数字为**当时**值；本节最新一次为 323 项，见 §13.0.9）。其中新增的迁移测试会构造 v1 数据库、向每张受影响表插入数据、执行迁移，并断言既有值不变、回填时间戳恰好等于注入的迁移时刻、新列与新表可用；空库迁移另按生成的 v2 快照校验结构一致。

#### 13.0.9 收尾顺序

1. 修正文档漂移并落实进度勾选（已完成）。
2. 修复可定位缺陷：C3、C4、C9、C10、C11 已修复；C1 按方案 C 实施并推广；C5、C6 已按"实现以需求文档为准"实施；C2 的因子注入已全部完成（最后一项为用户期望时段，提交 `fb3eb06`），仅剩"任务级因子在候选之间恒为常数"这一机制问题；C7 判定为不可达；C8 已修复（`424a1fc`，含一处实施中发现的确认阶段连带缺陷）。
3. 排程链路已接线（W1、W2、W4、W7 已解决）。W3 已补上**统计、偏好、任务详情**三条路由（任务详情页为新建，R9 的"修正剩余时长"入口即由它承载）；此后又接通**应用锁**（`cf542d8`）、**数据导出**（`f62ed50`）、**专注计时**（`e95d839`，入口在任务详情页）与**特殊日恢复**（`226ff8f`，入口在外壳顶栏，并补上"查看调整预览"以免提案无处确认）。**W3 已无缺项**：数据备份一页的路由**已完成**（`/settings/backup` ＋ 设置入口页条目；备份走真实数据库文件，恢复改为"待恢复文件 ＋ 启动期替换"）。
   **依赖关系提示**：专注页接通这一点顺带解开了 W6 剩余项的一个堵点——`focusCompletion` 这类偏好证据终于有了可触发的来源，因此 `PreferenceEvidence` 的写入方现在可以接了（另两类来源仍缺：`manualMove` 需 R9 的拖动、`suggestionAction` 需 R9 的建议操作入口）。
   **登记口径修正（本轮实测）**：本项原先写"导出／备份／应用锁需要文件与平台适配器（属 W6）"，**对应用锁与导出都不成立**——两者只依赖已有的服务，而它们依赖的适配器（`SettingsAppLockCredentialStore`、`FileSelectorAdapter`、`DriftExportDataSource`）早已存在，缺的只是组合根装配与路由。真正的障碍只落在**备份与永久清除**上，而且是三件具体的事，不是"缺个适配器"：① `AppDatabase.openDefault()` 不暴露数据库路径，而 `SqliteDatabaseLifecycleAdapter` 需要 `databasePath`；② 它还需要 `closeDatabase`/`reopenDatabase` 回调，即"关掉当前库再打开"，而库实例被任务／日程／计划／设置／统计／领域／标签／修正记录等**十余处服务持有**，重开必须让它们全部换用新实例——这是组合结构改动，不是接线；③ `BackupService` 还需要一个"把全部设置序列化成 JSON"的来源（`DriftSettingsRepository` 只有按 key 读写）与一个应用版本号来源（当前没有 `package_info` 类依赖）。因此备份页应作为**独立任务**处理，先决定"关库—换实例—重开"的做法，再接页面。**本轮核到三件与我上面判断有关的新事实，其中一件推翻了障碍 ①**：**(1) 数据库路径已经可以确定地取到**——`drift_flutter 0.3.1` 的默认路径是 `getApplicationDocumentsDirectory()` ＋ `<name>.sqlite`（**读包源码确认**，见 pub 缓存里 `drift_flutter-0.3.1/lib/src/native.dart:37-50`；且支持 `DriftNativeOptions.databaseDirectory` 覆盖），因此 `AppDatabase.openDefault()` "不暴露路径"**不再是障碍**，只是"要在同一套规则下自己算一遍"。**这一点必须靠读源码确定而不能猜**：猜错目录会让应用打开一个**空库**，用户看到的将是"数据全没了"。**(2) 剩余的其实全是装配，共七处**：① `pubspec` 加 `path_provider`（当前只是传递依赖）；② `main()` **目前是同步的**（`void main()`，第 57 行），要改成 `async` 才能 `await` 目录；③ 构造 `BackupService`（`SqliteDatabaseLifecycleAdapter(databasePath:)` ＋ `BackupArchiveAdapter` ＋ `Sha256FileHashAdapter` ＋ `clock`）；④ `appVersion` **没有来源**（无 `package_info` 依赖）——诚实的下限是一个写明"需与 pubspec 同步"的常量，而不是假装它会自动更新；⑤ `settingsJson` 需要"全部设置序列化"，**当前不存在**（`DriftSettingsRepository` 只能按 key 读写），约两处编辑；⑥ `PlannerApp` 与路由各加一个参数并接 `/settings/data/backup` 路由；⑦ 设置入口页加入口。**约 12–14 次调用，可单轮完成**。**(3) 我原先的"关库—换实例—重开"担忧可以缩小**：`SqliteDatabaseLifecycleAdapter` **已经**实现了带回滚的安全替换（`.restore-new`／`.restore-old` ＋ WAL 清理 ＋ 用 `sqlite3.open` 复核），也就是说**文件替换本身是安全的**；真正未解的是**替换之后运行中的 drift 连接仍指向旧文件**（库实例被十余处服务持有）。因此**我按默认选定采用的"恢复后提示重启"正是针对这一点**：文件替换 + 明确告知重启，而不是在没有重开机制的情况下假装恢复已经生效。**本轮已按这一定默认实施完成**：新增 `lib/app/backup_assembly.dart`**负责装配与启动期替换**——`preparePlannerDatabase()` 在**打开数据库之前**解析路径（规则与 `drift_flutter` 一致：`getApplicationDocumentsDirectory()` ＋ `personal_planner.sqlite`）并应用待恢复文件；恢复**不在运行中替换**：`replaceWith` 只把校验过的备份写到 `<库>.restore-pending`，下次启动时替换，**替换前留 `<库>.restore-old` 回滚副本**并清掉旧 `-wal`/`-shm`（旧 sidecar 属于被替换的库，留着会让新库读到自己不该有的内容）。**这比"运行中替换"更诚实**：没有运行中的连接就没有"连接指向旧文件"的半恢复状态，用户看到的提示与真实行为一致。备份侧复用既有适配器（WAL checkpoint ＋ 完整性复核）。`main.dart` 因此**改为异步**（要 `await` 目录）并把服务透传到路由。**三处如实标注**：① `erasure`（永久清除）**未接线**——它同样需要"关库—换实例—重开"，因此设置入口页**不显示该入口**，而不是给出会留下半清除状态的按钮；② `appVersion` 是**写明"需与 pubspec 同步"的常量**（无 `package_info` 依赖，不肯假装自动跟随构建）；③ `settingsJson` 导出**整张设置表**（逐键枚举会随新增设置静默漏键）。**三条用例针对替换逻辑本身**（真实文件）：确实替换并留回滚与清 sidecar、**没有待恢复文件时什么都不做**（空闲时误删当前库的 WAL 就是数据丢失）、库文件不存在时也能恢复（首次安装后直接恢复）。
   **本段原先列的"只差控件与依赖穿线"已全部完成**，因此以下不再是待办：① 任务详情页的项目选择控件与"新建项目并归属"（空项目时说明原因而不是显示空列表）；② `main.dart` → `PlannerApp` → `createPlannerRouter` → `TaskDetailPage` 的 `workspaceService` 穿线；③ 领域与项目的**管理界面**（提交 `ccd5dc9`）：`/workspace` 可新建与改名领域、切换生活标记、新建与归档项目，并作为任务的同级入口加入侧边导航。这条链路（任务归属 → 项目 → 领域 → `is_life`）**首次可以在界面里完整走完**，生活配额因子与统计的"生活"分类因此有了真实数据来源；其下每一层（schema 列、默认领域初始化、`LifeAreaLookup` 三表推导、评分因子、`WorkspaceService`、`TaskService.assignProject`）此前都已具备。
   R5 同类缺口（期望时段没有界面能写入）也已解决：入口在任务详情页的期望时段控件（提交 `b4e8cb8`）。
   **保留这段记录的原因**：它是"结构就绪 / 有服务入口 / 界面可用 / 需求兑现"四级区分的实例——其下每一层都已完成并有测试，缺的确实只是控件与穿线，但在控件缺席的那段时间里，这些能力在真实用户路径上等于不存在。因此判断一项是否兑现，要看用户能不能真的触发它，而不是看各层是否就绪。
4. 补齐 T4 缺失的测试类型，并清理 T2/T3 中不可信的用例。**（已完成）** T2、T3、T4、T7 四项均已闭合：T7 见 `1c0887b`（耗基准改为预热＋三次取最小值，整轮并发下 345ms→105ms）；T2 见 `0f25fd2`（两条前提经核实均已失效，但同一轮检索发现 `PlanChangeType.split` **零覆盖**，补了三例并做变异验证）；T3 见 `fcfa9d7`、`1abf5ff`、`be093c1`、`a849c7a`（魔数改为推导式、压力用例改为"推导＋不依赖算式的性质"、默认值用例补关系断言、schema 用例不再比对 drift 依据声明生成的列表且不再 `throwsA(anything)`——后者用变异证明：表名写错时旧写法通过、新断言拒绝）；T4 见 `4d71cf6`、`a35afd2`（golden 的 UTC 单一化以**紧凑场景**用例闭合，"无并发交错测试"查成一处**真实缺陷**：`FocusService.finish` 的幂等保护在并发下失效，已修）。**两处口径说明**：T3 中"压力用例加的性质"与"默认值用例"经变异验证**并未增加判别力**（前者在 `max`→`min` 变异下仍通过，后者与快照同时失败），真正抓到缺陷的是具体用例，登记里已如实写明；T4 的五条主张中**三条是本行未同步**（`integration_test`、迁移测试、DST 覆盖早已存在）
5. 完成 Task 20 剩余部分：端到端验收与 Windows 发布配置（首次引导门控与 MSIX 配置已完成），逐项核对 spec §18 后再勾选验收清单。
6. 13.0.8 的四项结构变更已落地（已完成，见上）。
7. **剩余项按实施成本排序（本轮实测统计；每项均已查清"缺什么"，据此估算编辑数）**——本清单的存在意义是让下一轮**先做便宜的**，因为同为"接线即可兑现"，成本从 5 到 13 不等：
   - **⑧ R9 `精力与休息统计`（FR-STAT-05）不是展示缺口，而是数据层功能（本轮核实）**。**本轮把这一项拆开并更正我自己的措辞（原文说"不是展示缺口"，方向对但不够精确）**：FR-STAT-05 的原文是"展示**不同精力时段的完成效果**、**生活配额**和**休息保护情况**"，三者的处境并不相同——**① 生活配额已实现**（`LifeQuotaMetric{target,planned,actual}` 已在报告里）；**② 精力时段完成效果：判定标准已经存在，缺的是"实际发生在何时"这一输入**。`EnergyWindow`（FR-RULE-02 的高/中/低区间）**是既有且已持久化的设置**，任务本身也带 `energyLevel`，因此不是"没有精力字段"——**而这一句是我当轮写错的，随即被读代码推翻**：`AnalyticsDao._actual`（第 146–168 行）**早就在取实际投入记录**——`time_entries` 里 `recoveryState=confirmed` 的行，带 `startedAtUtc`／`endedAtUtc` 与 `activeMinutes`，服务侧也早已用它们按天分配（`_trend`）。**因此"缺的是实际发生在何时"不成立：输入就在数据集里（`AnalyticsDataset.actualEntries`）**。真正缺的只有三件：**(1) 精力区间不在数据集里**（DAO 只从设置里读了 `weeklyLifeQuotaMinutes`，没读 `energyWindows`）；**(2) 没有按区间的分桶**（区间是**本地时刻**，而库里是 UTC，因此分桶要时区，`AnalyticsService` 目前没有时区）；**(3) 没有展示**。**成本因此从 12–14 降到约 10**（DAO 读窗口 1＋数据集与指标模型 2＋服务构造加时区与分桶 2＋页面 1＋用例 1＋装配 1＋门禁 1），但这需要**先读 `analytics.dart`、`analytics_page.dart` 与装配处**再动手。要做需四处：DAO 增取专注记录（含时间戳）、数据集与事实模型各加一字段、服务按窗口分桶聚合、统计页展示；**③ 休息保护情况仍是一个待决策项而不是工作量**：什么算"休息被保护、什么算被牺牲"没有任何采集（`临时放宽`同样未被采集），与 `interruption:` 同属"需求提到指标但未定义口径"。**实测成本**：② 约 12–14 次调用（跨 `analytics_dao.dart`、`analytics.dart`、`analytics_service.dart`、`analytics_page.dart` 与测试，且每处需先读后改），可在单轮内完成但它是一个大块；③ 必须先有口径决策。**因此本轮只把①②③分清楚，不在未定口径的情况下实现"休息保护"**。**② 已实施（本轮）**：新增 `AnalyticsEnergyWindow`（本地分钟区间，`isWeekend` 为**三态**——`null` 表示平日周末都适用，因为用户的默认区间就是"不分平日周末"，当成"只适用平日"会让周末投入全落进未标记）与 `EnergyPeriodMetric{label, actualMinutes, completedTasks}`；DAO 从设置 JSON 的 `common.energyWindows` 读出区间交给数据集；服务按**本地时刻**归桶，三条口径写在代码注释里：**一段专注算在它开始的那个区间**（不切半，否则两边都不代表实际做了什么）、**完成数按完成时刻**（"完成效果"问的是结果发生在哪个时段）、**区间外的投入不计入任何一行**（没有一行能诚实代表它）。统计页该节与中断合并为"精力、中断与调整"卡片，**区间为空（未设时区或未设区间）时整节不显示**——空壳比没有更让人困惑。**五条用例**：本地 09:30 归入高精力（按 UTC 归桶会全为 0，这条即判别点）、区间外不计入、完成数按完成时刻且只算范围内、`isWeekend=null` 周末也适用、未装配时区时不产生该节。**注意 `energyPeriods` 在报告里带默认值**："没有这一节"是合法状态，因此不强制既有构造点补空列表。**「常见中断」的写入方本轮接通（FR-STAT-06 的前半）**：`FocusService` 新增 `onInterrupted` 回调，`pause()` 时触发；`main.dart` 把它接到 `DriftAnalyticsEventLog`，标签写成**人类可读的"专注中暂停"**（统计页直接把它显示给用户，不该显示内部代码）。**口径是我按"默认选定"替你定的，写在此备查**：**暂停即记一次中断，不设时长阈值**——阈值会让"中断"依赖一个没人定义过的数字；要过滤极短暂停时只需改这一处。**重复暂停不重复计数**：`pause()` 在已是暂停态时提前返回，因此用户连点两下不会凭空多出一次中断（用例专门钉这一点，另有"继续后再暂停会再记一次"与"未装配回调时照常计时"）。**仍未做的**：按"原因"分类（需新增采集，见本节前文三条出路），因此"常见"目前只有一种 code。**③ 休息保护也已实施（同一批）**：口径为**默认选定**——`protectedMinutes` 是筛选范围内本地保护段（午餐／晚餐／固定休息）的总时长，`overlappedMinutes` 是其中**被实际专注覆盖**的分钟数，并按每段专注的**实际占比**折算（与 `_actualIntersectionMinutes` 同一口径；否则一段暂停很久的专注会把整段保护算成被占用）。**两项都由既有数据算出，不需要任何新采集**；保护总时长与被占用都夹在筛选范围内，且被占用**被夹在保护总时长之下**，避免出现"占用 61 / 保护 60"这种一眼像 bug 的数字。`enabled=false` 的保护段**跳过**（否则关掉保护反而让数字变差，读起来像惩罚）；跨午夜的保护段（`endMinute<=startMinute`）**跳过**并写明原因（`protectedTimes` 只有午餐／晚餐／固定休息，睡眠另在 `sleepRange`，不猜语义）。展示并入同一张卡片。**四条用例**：保护总时长按本地日累计（含周末）、被占用按实际时长折算而非挂钟（判别点）、保护时段之外的专注不算占用、无保护段或无时区时不产生该节。**过程中用例抓到我自己的夹具错误**：服务会先按"筛选出的任务"过滤实际投入，我的数据集没给条目对应任务，占用因此恒为 0——已修正并把这一点写进用例注释：`AnalyticsReport` **没有任何**精力或休息字段，`AnalyticsService` 与 `AnalyticsDao` 也**一次都没提到** `energy`；而 `lifeQuota`（生活配额）**页面已经在显示**（`analytics_page.dart:408–410`）。因此该条剩余部分要新增 DAO 取数（任务精力等级 × 实际时长）、模型字段、服务汇总与界面呈现，**约 10+ 个编辑**。
   - **日历事件创建入口（切片 A）：**已由并发写者完成（提交 `55ffbce feat(event creation flow)`）**，原先那 13 个编辑不必再付；它同时是 R4 与 R9"任务转固定日程"的前置。**但我在上一轮据此说"R4 的成本也下降、约 8 个编辑"是过于乐观的判断，本轮核实后更正**：`EventEditorForm` 确实已带 `zones` 与 `timeZoneId`、路由已有 `/calendar/new`（省掉的是**表单与路由**那一层），可 `CalendarService` **仍然没有 `zones`**，而 R4 还缺：① 单独端口 `RecurrenceRuleRepository`（2 个方法，1 个新文件——不能加进 `CalendarRepository`，否则打破全部实现它的测试替身）；② `DriftCalendarRepository` 实现该端口 + 构造函数加 `zones` + 在 `occurrencesBetween` 里分区展开（约 3 个编辑）；③ `CalendarService` 加 `zones` 与 `save(..., {repeatWeekly})` 并建规则（约 2 个）；④ `main.dart` 把 `zones` 传给两者（1–2 个）；⑤ **表单加"按周重复"开关并把该值传进 `save`**（1–2 个，这一步并未被切片 A 省掉）；⑥ 三处测试：建规则、展开（跨三周出三条且锚点那天不重复、每次出现 id 互不相同）、开关落到草稿（2–3 个）；⑦ 门禁运行与登记（3 个）。**合计约 11–15 个编辑**，因此 R4 仍不落在单轮容量内。**该部位已由并发写者落地（提交 `a5231d9 feat(calendar): create and expand weekly events`），本轮核实并登记**：`lib/data/repositories/drift_calendar_repository.dart` 的**未提交**改动里已出现 `RecurrenceExpander` 的引入与实例、对 `recurrenceRules` 的查询与读取、`_recurrence.expand(rule, window, const [])` 以及 `saveRecurrenceRule` 的插入语句，配套的 `test/data/repository_round_trip_test.dart` 同处于未提交状态。因此**我不再重复实现 R4 的这些部分**；本行保留上面那份逐文件清单，用途改为**核对**（若对方落地后仍有缺项，按清单点出，而不是从头再做一遍）。**核对结论（本轮逐条对照其未提交实现，只读）**：**符合**——④ 锚点不会被当成单次事件重复输出（`recurrenceRuleId.isNull()` 过滤 + `innerJoin(recurrenceRules)` 取锚点）；⑥ 其 `calendar_service.dart` 已改（服务侧具备建规则所需的时区）；⑦ 规则行的 `createdAtUtc`／`updatedAtUtc` 取自事件的 `updatedAtUtc`（由 Clock 提供）而**不是 `DateTime.now()`**，`DoUpdate` 分支**保留 `createdAtUtc`** 只推进 `updatedAtUtc`，因此不会留下哨兵值 0（这正是 §13.0.9 第 4 条要求"入口落地时一并写入"的那一点）；事件与规则在**同一事务**内写入；⑧ 掩码用 `1 << (day - 1)`、周一=1，与约定一致。**我的一条要求是错的、已撤回**：⑤ 我曾要求"每次出现各自 id"，理由是"排程输入按 id 去重"，实测 `fixedIntervals` 不按 id 去重且哈希含每次出现及其区间，故共用锚点 id 可接受（详见 R9 行的核对记录）。**保留的唯一弱点**：锚点的规则行若缺失，该事件会整条消失而非退化为"只显示这一次"；正常路径由事务保证不会出现，属低概率加固项**（`main.dart` 2 ＋ `PlannerApp` 2 ＋ `router` 3 ＋ 日视图入口 1 ＋ 测试 1 ＋ 门禁与登记 4）——成本主要来自**组合根四层穿透**，不是逻辑复杂度；它是 R4 按周重复（再 +8）与 R9"任务转固定日程"（再 +3）的**共同前置**，因此一次投入可推进三项。
   - **FR-REPLAN-08 计划撤销：约 11 个编辑**（路由参数 1 ＋ `PlannerApp` 2 ＋ `main.dart` 1 ＋ `TodayPage` 入口 2 ＋ 路由 1 ＋ 测试 1 ＋ 门禁与登记 3）；卡点是 `PlanRepository` 与 `PlanHistoryRepository` **两个无继承关系的接口**（见 W10）。
   - **R4 按周重复：约 11 个编辑**（在切片 A 之上另加数据层与服务层：单独端口 1 ＋ 仓储 2 ＋ 服务 2 ＋ 表单 2 ＋ 测试 3 ＋ 门禁 1）。
   - **② R8 冲突通知来源 ＋ W9 `replan:`：一次实施解两项**（同源，均缺"最近提案持有者"；见 W9 与 R8 行 ③），成本约 6–8 个编辑，但**需先定 `DomainChange` 由谁发出**。
   - **已完成的本轮及近日项**：FR-FOCUS-02 崩溃恢复（`d9a437b`，约 5 个编辑，是本轮所有剩余项中最便宜的）、FR-STAT 温和反馈（`acd5220`，4 个编辑）、T2/T3/T4/T7 四项测试质量（`0f25fd2` 起）。
   - **仍未定的三项**：③ 数据备份页（受"关库—换实例—重开"方案制约）、⑤ `interruption:`（**需求缺口**：FR-STAT-06 要求展示但无任何 FR 定义或采集它）、⑧ R9 其余（批量调整、任务转固定日程、修改偏好值）。

R1 **已全部完成**（数据层与服务层 `d5d2054`、`1745e59`；打标签入口 `90eedb2`；按标签筛选 `cf02365`；登记里"仍靠子串匹配"的描述是错的，实际是"标签从未被读出、筛选恒返回空集"，已修正）。R3、R8、R9、R11、W3、W5、W6 仍需实现。此前的环境限制已解除，`flutter analyze` 与 `flutter test` 均可在本机运行，因此这些改动必须实测通过后才算完成；仍需人工或真机执行的部分（Windows 端到端测试、MSIX 打包、spec §18 手工验收清单）单独标注，不得混入"已验证"。

---

### Task 1: 创建可运行的 Windows Flutter 外壳

**Files:**
- Create: `pubspec.yaml`
- Create: `analysis_options.yaml`
- Create: `lib/main.dart`
- Create: `lib/app/planner_app.dart`
- Create: `lib/app/router.dart`
- Create: `test/app/app_smoke_test.dart`
- Modify: `windows/runner/Runner.rc`
- Modify: `windows/CMakeLists.txt`

**Interfaces:**
- Consumes: 无。
- Produces: `PlannerApp`、根 `ProviderScope`、稳定路由和显示名“智能日程”。

- [x] **Step 1: 初始化 Git 和 Flutter Windows 项目**

Run: `git init`，然后 `flutter create --platforms=windows --org app.personalplanner --project-name personal_planner .`

Expected: `flutter doctor -v` 的 Windows toolchain 无阻塞错误，`flutter run -d windows` 可启动默认窗口。

- [x] **Step 2: 添加并锁定首阶段依赖**

添加 `flutter_riverpod`、`go_router`、`drift`、`drift_flutter`、`uuid`、`timezone`、`intl`，以及开发依赖 `drift_dev`、`build_runner`、`flutter_lints`；提交 `pubspec.lock`。SQLite 原生运行库由 `drift_flutter` 的当前推荐配置提供，不重复引入旧式平台依赖。

- [x] **Step 3: 写失败的应用冒烟测试**

`app_smoke_test.dart` 中验证启动后显示“今日”，并能通过路由进入“任务”和“日历”。

Run: `flutter test test/app/app_smoke_test.dart`

Expected: FAIL，因为 `PlannerApp` 和路由尚未实现。

- [x] **Step 4: 实现最小应用外壳和骨架页面**

实现 `PlannerApp` 与路由；将 Windows 标题、二进制名和资源显示名改为“智能日程”/`personal_planner`。

- [x] **Step 5: 验证外壳**

Run: `flutter analyze`，`flutter test test/app/app_smoke_test.dart`，`flutter build windows --debug`

Expected: 无分析错误、测试 PASS、生成 Windows debug 可执行程序。

- [x] **Step 6: Commit**

```bash
git add .
git commit -m "build: scaffold Windows planner app"
```

### Task 2: 领域模型、默认值与输入校验

**Files:**
- Create: `lib/core/clock.dart`
- Create: `lib/core/ids.dart`
- Create: `lib/core/result.dart`
- Create: `lib/domain/models/task.dart`
- Create: `lib/domain/models/calendar_event.dart`
- Create: `lib/domain/models/planning_rules.dart`
- Create: `lib/domain/models/time_range.dart`
- Create: `lib/domain/models/preferences.dart`
- Create: `lib/domain/services/default_settings.dart`
- Test: `test/domain/default_settings_test.dart`
- Test: `test/domain/time_range_test.dart`
- Test: `test/domain/task_validation_test.dart`

**Interfaces:**
- Consumes: Dart SDK。
- Produces: `PlannerTask`、`CalendarEvent`、`PlanningRules`、`TimeRange`、`PreferenceProfile`、`DefaultSettings.v1()`、`Clock`、`IdGenerator`。

- [x] **Step 1: 写默认值和优先级失败测试**

断言 `DefaultSettings.v1()` 包含高精力 09:00–12:00、中精力 14:00–17:00、低精力 19:00–22:00、睡眠 23:30–07:30、最低睡眠 420 分钟、默认片段 50 分钟、休息 10 分钟、每日可移动任务上限 360 分钟、生活配额 360 分钟，且临时例外 > 用户设置 > 已确认偏好 > 产品默认。

Run: `flutter test test/domain/default_settings_test.dart`

Expected: FAIL，因为模型不存在。

- [x] **Step 2: 写时间和值校验失败测试**

覆盖半开区间、零/负时长拒绝、跨午夜本地范围拆分、任务排程时长向上取整到 5 分钟但保留原始分钟数。

- [x] **Step 3: 实现领域模型和默认值**

使用不可变 Dart 类和显式 `copyWith`；业务模型不得导入 `package:flutter` 或 Drift。

- [x] **Step 4: 验证领域层**

Run: `flutter test test/domain`

Expected: 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add lib/core lib/domain test/domain
git commit -m "feat: define planner domain and defaults"
```

### Task 3: Drift 数据库、DAO 与迁移基线

**Files:**
- Create: `build.yaml`
- Create: `lib/data/database/app_database.dart`
- Create: `lib/data/database/tables/*.dart`
- Create: `lib/data/database/daos/*.dart`
- Create: `lib/domain/repositories/*.dart`
- Create: `lib/data/repositories/*.dart`
- Create: `drift_schemas/`
- Test: `test/data/database_schema_test.dart`
- Test: `test/data/repository_round_trip_test.dart`

**Interfaces:**
- Consumes: Task 2 的领域模型。
- Produces: `AppDatabase.openDefault()`、`AppDatabase.forTesting(QueryExecutor)` 和 `TaskRepository`、`CalendarRepository`、`PlanRepository` 的 Drift 实现。

- [x] **Step 1: 写内存数据库失败测试**

验证 13 张核心表存在、外键启用、任务 round-trip 不丢字段、删除项目时不能留下悬空任务。

- [x] **Step 2: 定义 Drift 表和 DAO**

按第 4 节表结构实现；所有 UTC 时间显式保存为 `int` 微秒，重复规则墙上时间保存为分钟整数。

- [x] **Step 3: 实现 repository 映射**

DAO row 不得越过 data 层；repository 返回 Task 2 的领域模型。

- [x] **Step 4: 生成代码和 schema 基线**

Run: `dart run build_runner build --delete-conflicting-outputs`，`dart run drift_dev make-migrations`

Expected: 生成代码、schema v1 快照和迁移测试文件。

- [x] **Step 5: 验证事务和迁移基线**

Run: `flutter test test/data`

Expected: 全部 PASS，`PRAGMA foreign_key_check` 无结果。

- [x] **Step 6: Commit**

```bash
git add build.yaml lib/data lib/domain/repositories test/data drift_schemas
git commit -m "feat: add local planner database"
```

### Task 4: 任务、项目和固定日程 CRUD

**Files:**
- Create: `lib/application/task_service.dart`
- Create: `lib/application/calendar_service.dart`
- Create: `lib/features/tasks/*`
- Create: `lib/features/calendar/event_editor/*`
- Test: `test/application/task_service_test.dart`
- Test: `test/features/tasks/quick_add_test.dart`
- Test: `test/features/calendar/event_editor_test.dart`

**Interfaces:**
- Consumes: `TaskRepository`、`CalendarRepository`、`Clock`、`IdGenerator`。
- Produces: `TaskService.quickAdd(title, estimatedMinutes)`、`TaskService.saveDraft(TaskDraft)`、`CalendarService.save(EventDraft)`。

- [x] **Step 1: 写快速录入失败测试**

验证只填写标题和预计时长即可创建收集箱任务，空标题和非正时长显示字段错误而不写数据库。

- [x] **Step 2: 实现应用服务**

应用服务负责校验、默认值、ID 和时间戳；Notifier 只转换 UI 事件。

- [x] **Step 3: 实现任务列表、详情和固定日程表单**

覆盖领域与项目维护、搜索、筛选、批量调整、状态变更、一次性事件以及“修改单次/修改系列”入口。

- [x] **Step 4: 验证 CRUD 与键盘操作**

Run: `flutter test test/application/task_service_test.dart test/features/tasks test/features/calendar`

Expected: 全部 PASS；快速录入可只用键盘完成。

- [x] **Step 5: Commit**

```bash
git add lib/application lib/features/tasks lib/features/calendar test/application test/features
git commit -m "feat: add task and calendar editing"
```

### Task 5: 重复日程与可用时间构造

**Files:**
- Create: `lib/core/time_zone.dart`
- Create: `lib/domain/services/recurrence_expander.dart`
- Create: `lib/scheduling/availability_builder.dart`
- Test: `test/domain/recurrence_expander_test.dart`
- Test: `test/scheduling/availability_builder_test.dart`

**Interfaces:**
- Consumes: `RecurrenceRule`、`CalendarEvent`、`PlanningRules`、`TimeRange`。
- Produces: `RecurrenceExpander.expand(rule, window, exceptions)`、`AvailabilityInput` 和 `AvailabilityBuilder.build(input) -> List<AvailabilitySlot>`。

- [x] **Step 1: 写重复展开失败测试**

覆盖按周重复、修改单次、删除单次、有效起止日期、跨午夜以及夏令时跳变；本地 09:00 的重复事项在时区变化后仍保持本地 09:00。

- [x] **Step 2: 实现重复规则展开**

使用 `timezone` 的 IANA location 做本地日期到 UTC 的转换；不得用固定 UTC offset 模拟时区。

- [x] **Step 3: 写可用时间失败测试**

输入睡眠、午餐、课程、锁定块和每日 360 分钟上限，断言输出无重叠、均落在允许窗口、总可移动容量正确。

- [x] **Step 4: 实现区间合并和可用时间构造**

所有区间采用 `[start, end)`；先合并忙碌区间，再求补集，最后应用每日上限。

- [x] **Step 5: 验证边界**

Run: `flutter test test/domain/recurrence_expander_test.dart test/scheduling/availability_builder_test.dart`

Expected: 全部 PASS，包含 Review Focus 的时区、跨午夜测试。

- [x] **Step 6: Commit**

```bash
git add lib/core/time_zone.dart lib/domain/services lib/scheduling test/domain test/scheduling
git commit -m "feat: build recurring availability windows"
```

### Task 6: 排程输入、输出和最终验证器

**Files:**
- Create: `lib/scheduling/schedule_problem.dart`
- Create: `lib/scheduling/schedule_proposal.dart`
- Create: `lib/scheduling/plan_validator.dart`
- Create: `lib/scheduling/explanations.dart`
- Test: `test/scheduling/plan_validator_test.dart`

**Interfaces:**
- Consumes: Task 2 和 Task 5 的值对象。
- Produces: `ScheduleProblem`、`ScheduleProposal`、`PlanningConflict`、`PlanValidator.validate(problem, blocks)`。

- [x] **Step 1: 写硬约束验证失败测试**

分别构造固定日程重叠、保护时间重叠、锁定块移动、连续任务拆分、每日上限超出和片段总量超出，断言返回稳定 `ConflictCode`。

- [x] **Step 2: 实现不可变输入输出模型**

为所有列表做不可变封装；`ScheduleProposal` 显式包含 `inputHash` 和 `algorithmVersion`。

- [x] **Step 3: 实现最终验证器和解释代码映射**

验证器不修复结果，只报告冲突；中文解释由代码和参数在 UI 层格式化。

- [x] **Step 4: 验证模型和约束**

Run: `flutter test test/scheduling/plan_validator_test.dart`

Expected: 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add lib/scheduling test/scheduling/plan_validator_test.dart
git commit -m "feat: define schedule proposal contract"
```

### Task 7: 远期压力、候选生成与评分

**Files:**
- Create: `lib/scheduling/pressure_calculator.dart`
- Create: `lib/scheduling/candidate_generator.dart`
- Create: `lib/scheduling/candidate_scorer.dart`
- Create: `lib/scheduling/scheduling_weights.dart`
- Test: `test/scheduling/pressure_calculator_test.dart`
- Test: `test/scheduling/candidate_generator_test.dart`
- Test: `test/scheduling/candidate_scorer_test.dart`

**Interfaces:**
- Consumes: `ScheduleProblem`、`AvailabilitySlot`。
- Produces: `PressureCalculator.calculate(task, capacityModel)`、`CandidateGenerator.generate(task, slots)`、`CandidateScorer.score(candidate, context)`。

- [x] **Step 1: 写远期压力失败测试**

验证 6 小时任务在 21 天后截止时会在七日内获得均匀推进量；未来容量不足时提高七日必须完成量；无截止任务不虚构截止压力。

- [x] **Step 2: 实现容量估算和压力公式**

按第 5.3 节公式实现，重复日程最多展开 180 天。

- [x] **Step 3: 写候选和评分失败测试**

验证 6 小时可拆分任务生成 30–90 分钟片段，高脑力任务优先高精力时段，生活配额缺口提高娱乐任务得分，但任何评分不绕过硬约束。

- [x] **Step 4: 实现候选与 `SchedulingWeights.v1`**

候选以 5 分钟步长生成；所有分数为整数并返回逐因素明细。

- [x] **Step 5: 验证算法组件**

Run: `flutter test test/scheduling/pressure_calculator_test.dart test/scheduling/candidate_generator_test.dart test/scheduling/candidate_scorer_test.dart`

Expected: 全部 PASS。

- [x] **Step 6: Commit**

```bash
git add lib/scheduling test/scheduling
git commit -m "feat: score schedule candidates"
```

### Task 8: 确定性排程引擎与不可行报告

**Files:**
- Create: `lib/scheduling/schedule_engine.dart`
- Create: `lib/scheduling/plan_differ.dart`
- Test: `test/scheduling/schedule_engine_test.dart`
- Test: `test/scheduling/infeasible_schedule_test.dart`
- Create: `test/fixtures/scheduling/*.json`

**Interfaces:**
- Consumes: Tasks 5–7 的构件。
- Produces: `DeterministicScheduleEngine implements ScheduleEngine`、`PlanDiffer.diff(current, proposed)`。

- [x] **Step 1: 写黄金场景失败测试**

用固定 JSON fixture 覆盖课程、科研、娱乐配额、6 小时拆分任务和连续任务；断言时间块、顺序、解释代码和 `algorithmVersion='1'`。

- [x] **Step 2: 写不可行与确定性失败测试**

断言总需求大于容量时不违反睡眠且报告精确缺口分钟；相同输入连续运行 100 次输出相同；输入列表顺序变化不改变结果。

- [x] **Step 3: 实现贪心分配和有界局部改进**

局部改进使用确定性的 200 次操作预算，并按稳定候选顺序尝试交换或移动。不得以墙上运行时间作为停止条件，否则同一输入可能在不同机器上产生不同结果。

- [x] **Step 4: 每次改进后调用验证器**

最终结果只在 `PlanValidator` 无硬冲突时标记完全可行；否则保留可行部分并生成冲突。

- [x] **Step 5: 验证引擎**

Run: `flutter test test/scheduling`

Expected: 全部 PASS，包含 Review Focus 的容量不足场景。

- [x] **Step 6: Commit**

```bash
git add lib/scheduling test/scheduling test/fixtures
git commit -m "feat: generate deterministic weekly plans"
```

### Task 9: 排程服务、快照哈希与原子应用

**Files:**
- Create: `lib/application/planning_service.dart`
- Create: `lib/application/plan_application_service.dart`
- Create: `lib/application/input_snapshot_builder.dart`
- Test: `test/application/planning_service_test.dart`
- Test: `test/application/plan_application_service_test.dart`

**Interfaces:**
- Consumes: repositories、`ScheduleEngine`、`Clock`。
- Produces: `PlanningService.createProposal()`、`PlanApplicationService.apply(proposal)`、`InputSnapshotBuilder.hash(snapshot)`。

- [x] **Step 1: 写快照和过期提案失败测试**

生成提案后修改任务，断言 `apply` 返回 `staleProposal` 且当前计划未改变；只改变无关 UI 状态不应改变哈希。

- [x] **Step 2: 实现规范化快照和 SHA-256**

JSON key 和列表按稳定规则排序；哈希只包含会影响排程的事实数据与设置。此任务加入 `crypto` 依赖并提交更新后的 `pubspec.lock`。

- [x] **Step 3: 写事务回滚失败测试**

模拟写入第三个时间块失败，断言计划版本、时间块和 change log 全部回滚。

- [x] **Step 4: 实现提案创建和原子应用**

排程在独立 isolate 中运行；确认前仅内存保存提案，应用时重新计算哈希并再次运行验证器。

- [x] **Step 5: 验证服务**

Run: `flutter test test/application/planning_service_test.dart test/application/plan_application_service_test.dart`

Expected: 全部 PASS，包含 Review Focus 的过期提案测试。

- [x] **Step 6: Commit**

```bash
git add lib/application test/application
git commit -m "feat: preview and atomically apply plans"
```

### Task 10: 七日周视图、今日页和调整预览

**Files:**
- Create: `lib/features/calendar/week_view/*`
- Create: `lib/features/today/*`
- Create: `lib/features/planning/*`
- Modify: `lib/app/router.dart`
- Test: `test/features/calendar/week_view_test.dart`
- Test: `test/features/today/today_page_test.dart`
- Test: `test/features/planning/plan_preview_test.dart`

**Interfaces:**
- Consumes: Task 9 应用服务及 repository watch streams。
- Produces: 可操作的 `/today`、`/calendar`、`/planning/preview/:proposalId` 页面。

- [x] **Step 1: 写页面状态失败测试**

分别覆盖 loading、empty、content、recoverable error；周视图不只通过颜色区分类别。

- [x] **Step 2: 实现今日页和周视图**

显示固定日程、保护时间、任务块和生活时间；拖动任务后调用应用服务创建新提案，而不是直接改数据库。

- [x] **Step 3: 写调整预览失败测试**

验证新增、移动、拆分、移除和冲突分组；每项可展开原因；过期提案禁用确认按钮。

- [x] **Step 4: 实现预览确认和自动调整设置**

自动调整默认关闭；开启后仍保存 diff 和解释历史。

- [x] **Step 5: 验证基础排程版**

Run: `flutter analyze`，`flutter test`，`flutter build windows --debug`

Expected: 全部通过，可从录入任务走通到确认七日计划。

- [x] **Step 6: Commit**

```bash
git add lib/features lib/app/router.dart test/features
git commit -m "feat: deliver weekly planning workflow"
```

### Task 10A: 规划规则与默认值设置页面

**Files:**
- Create: `lib/application/settings_service.dart`
- Create: `lib/features/settings/planning_rules/*`
- Create: `lib/features/settings/notifications/*`
- Modify: `lib/app/router.dart`
- Test: `test/application/settings_service_test.dart`
- Test: `test/features/settings/planning_rules_page_test.dart`

**Interfaces:**
- Consumes: `PlanningRules`、`DefaultSettings.v1()`、settings repository。
- Produces: `SettingsService.resolveForDate(localDate)`、`saveUserRules(rules)`、`saveDateOverride(date, override)`、完整规划规则设置页面。

- [x] **Step 1: 写规则优先级失败测试**

断言指定日期例外 > 用户长期设置 > 已确认学习偏好 > 产品默认值；未标记精力时段返回中性权重而不是低精力。

- [x] **Step 2: 写硬约束修改失败测试**

验证最低睡眠、用餐、每日上限和生活配额只有明确保存用户表单时才改变；偏好学习写入不能修改这些字段。

- [x] **Step 3: 实现设置服务和页面**

页面覆盖工作日/周末睡眠、用餐、休息、多个精力区间、默认专注片段、拆分片段范围、每日任务上限、生活娱乐配额、通知提前量、免打扰和自动调整开关。

- [x] **Step 4: 写并实现输入校验**

拒绝重叠且级别冲突的精力区间、负时长、零长度区间和超过 24 小时的单日上限；保存前显示字段级错误。

- [x] **Step 5: 验证设置流程**

Run: `flutter test test/application/settings_service_test.dart test/features/settings/planning_rules_page_test.dart`

Expected: 全部 PASS；重新启动内存测试容器后用户设置仍优先于默认值。

- [x] **Step 6: Commit**

```bash
git add lib/application/settings_service.dart lib/features/settings lib/app/router.dart test/application test/features/settings
git commit -m "feat: configure planning rules and defaults"
```

### Task 11: 特殊日与次日恢复保护

**Files:**
- Create: `lib/application/recovery_planning_service.dart`
- Create: `lib/features/calendar/special_day/*`
- Test: `test/application/recovery_planning_service_test.dart`
- Test: `test/features/calendar/special_day_test.dart`

**Interfaces:**
- Consumes: `PlanningRules`、固定事件、`PlanningService`。
- Produces: `RecoveryPlanningService.createOverride(SpecialDayDraft)` 和次日最早可安排时间计算。

- [x] **Step 1: 写晚归恢复失败测试**

活动延长到 01:00、最低睡眠 420 分钟时，断言次日 08:00 前不可安排；若 07:30 有早课，返回 `minimumSleepConflict` 而非移动早课。

- [x] **Step 2: 实现单日覆盖和恢复服务**

特殊日只写日期范围例外，不修改常规睡眠和学习偏好。

- [x] **Step 3: 实现特殊日 UI 和处理选项**

提供取消可移动任务、安排补觉、单次接受较短睡眠，并展示每项影响。

- [x] **Step 4: 验证恢复流程**

Run: `flutter test test/application/recovery_planning_service_test.dart test/features/calendar/special_day_test.dart`

Expected: 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add lib/application lib/features/calendar/special_day test
git commit -m "feat: protect recovery after late events"
```

### Task 12: 专注计时与崩溃恢复

**Files:**
- Create: `lib/application/focus_service.dart`
- Create: `lib/platform/monotonic_clock.dart`
- Create: `lib/features/focus/*`
- Test: `test/application/focus_service_test.dart`
- Test: `test/features/focus/recovery_dialog_test.dart`

**Interfaces:**
- Consumes: `Clock`、单调时钟、time entry DAO。
- Produces: `FocusService.start(taskId)`、`pause()`、`resume()`、`finish()`、`recoverOpenEntry()`。

本任务加入开发依赖 `fake_async` 并提交更新后的 `pubspec.lock`。

- [x] **Step 1: 用 `fake_async` 写状态机失败测试**

覆盖运行、暂停、继续、完成、重复点击幂等和非法转换。

- [x] **Step 2: 写崩溃与时钟跳变失败测试**

断言重启发现 running 记录时要求确认；墙上时间跳变超过 5 分钟不直接计入实际时长。

- [x] **Step 3: 实现持久化状态机**

每次状态转换先落库再更新 UI；统计只读取 `confirmed` 记录。

- [x] **Step 4: 实现专注页和恢复对话框**

用户可修正结束时间、实际时长和完成备注。

- [x] **Step 5: 验证计时**

Run: `flutter test test/application/focus_service_test.dart test/features/focus`

Expected: 全部 PASS，包含 Review Focus 的崩溃恢复测试。

- [x] **Step 6: Commit**

```bash
git add lib/application/focus_service.dart lib/platform lib/features/focus test
git commit -m "feat: record recoverable focus sessions"
```

### Task 13: 重新排程触发和撤销

**Files:**
- Create: `lib/application/replanning_coordinator.dart`
- Create: `lib/application/plan_undo_service.dart`
- Test: `test/application/replanning_coordinator_test.dart`
- Test: `test/application/plan_undo_service_test.dart`

**Interfaces:**
- Consumes: task/calendar/focus changes、`PlanningService`、`PlanRepository`。
- Produces: `ReplanningCoordinator.onDomainChange(change)`、`PlanUndoService.undoLastAppliedPlan()`。

- [x] **Step 1: 写触发矩阵失败测试**

新增、修改、完成、跳过、延期任务和新增固定事件应触发；纯备注修改不触发；短时间连续变化合并为一次请求。

- [x] **Step 2: 实现 500 毫秒去抖和取消旧计算**

新输入到达时取消仍在运行的旧提案；已完成的旧提案因哈希不匹配不可应用。

- [x] **Step 3: 写撤销失败测试**

应用计划 B 后撤销，恢复计划 A 的块并创建新的审计记录，不删除历史版本。

- [x] **Step 4: 实现协调器与撤销服务**

- [x] **Step 5: 验证重排生命周期**

Run: `flutter test test/application/replanning_coordinator_test.dart test/application/plan_undo_service_test.dart`

Expected: 全部 PASS。

- [x] **Step 6: Commit**

```bash
git add lib/application test/application
git commit -m "feat: coordinate and undo replanning"
```

### Task 14: Windows 本地通知

**Files:**
- Create: `lib/domain/repositories/notification_port.dart`
- Create: `lib/platform/notifications/windows_notification_adapter.dart`
- Create: `lib/application/notification_service.dart`
- Test: `test/application/notification_service_test.dart`

**Interfaces:**
- Consumes: 当前确认计划、通知设置、免打扰规则。
- Produces: `NotificationPort.scheduleOneShot`、`cancel`、`NotificationService.syncNextSevenDays()`。

本任务加入 `flutter_local_notifications` 依赖并提交更新后的 `pubspec.lock`。

- [x] **Step 1: 写通知计划失败测试**

验证只安排未来 7 天一次性通知、免打扰推迟普通提醒、payload 不包含标题和备注、计划变更取消旧通知。

- [x] **Step 2: 实现可 mock 的端口和协调服务**

- [x] **Step 3: 接入 `flutter_local_notifications` Windows 适配器**

不得调用 Windows 不支持的 repeating API；无包身份时显示功能限制诊断。

- [x] **Step 4: 验证通知服务**

Run: `flutter test test/application/notification_service_test.dart`

Expected: 全部 PASS；在 Windows debug 环境手动验证一条 2 分钟后通知。

- [x] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/platform/notifications lib/application lib/domain/repositories test
git commit -m "feat: schedule Windows planner notifications"
```

### Task 15: 数据导出

**Files:**
- Create: `lib/application/export_service.dart`
- Create: `lib/platform/files/file_selector_adapter.dart`
- Create: `lib/features/settings/data/export_page.dart`
- Test: `test/application/export_service_test.dart`

**Interfaces:**
- Consumes: repositories、文件选择端口。
- Produces: `ExportService.exportJson(directory)`、`exportCsv(directory)`。

本任务加入 Flutter 官方维护的 `file_selector` 依赖并提交更新后的 `pubspec.lock`。

- [x] **Step 1: 写导出失败测试**

验证 JSON 包含 schema 版本和所有用户事实数据；CSV 使用 UTF-8 BOM 供常见 Windows 表格工具读取；计划与实际字段明确区分。

- [x] **Step 2: 实现流式导出和临时文件原子改名**

取消或失败时删除临时文件，不覆盖既有同名文件。

- [x] **Step 3: 实现导出 UI 和完成摘要**

- [x] **Step 4: 验证导出**

Run: `flutter test test/application/export_service_test.dart`

Expected: 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add lib/application/export_service.dart lib/platform/files lib/features/settings/data test
git commit -m "feat: export local planner data"
```

### Task 16: 备份、恢复、永久清除与应用锁

**Files:**
- Create: `lib/application/backup_service.dart`
- Create: `lib/application/data_erasure_service.dart`
- Create: `lib/platform/app_lock/app_lock_service.dart`
- Create: `lib/features/settings/data/backup_page.dart`
- Create: `lib/features/settings/app_lock/*`
- Test: `test/application/backup_service_test.dart`
- Test: `test/application/data_erasure_service_test.dart`
- Test: `test/platform/app_lock_service_test.dart`

**Interfaces:**
- Consumes: database lifecycle port、文件端口、hash adapter。
- Produces: `BackupService.create(destination)`、`validate(source)`、`restore(source)`、`DataErasureService.eraseAll(confirmation)`、`AppLockService.verify(password)`。

本任务加入 ZIP 与 PBKDF2-HMAC-SHA256 所需的最小维护依赖并提交 `pubspec.lock`；依赖选择需通过 Windows 支持、许可证和最近维护状态检查。

- [x] **Step 1: 写备份 round-trip 失败测试**

创建包含任务、计划和计时的数据库，备份后恢复到新数据库，断言业务数据和 schema 版本一致。

- [x] **Step 2: 写恶意或损坏备份失败测试**

覆盖错误哈希、截断 SQLite、新版本 schema 和 ZIP 路径穿越，断言全部在临时目录被拒绝且当前数据库字节不变。

- [x] **Step 3: 实现 manifest、哈希、integrity check 和原子恢复**

- [x] **Step 4: 写并实现永久清除测试**

要求用户输入明确确认短语；清除数据库、备份索引、通知和应用锁凭据，但不删除用户自行导出的外部文件。

- [x] **Step 5: 写并实现应用锁测试**

验证密码不明文保存、错误尝试递增等待、关闭锁需再次验证；界面明确说明数据库未加密。

- [x] **Step 6: 验证数据安全功能**

Run: `flutter test test/application/backup_service_test.dart test/application/data_erasure_service_test.dart test/platform/app_lock_service_test.dart`

Expected: 全部 PASS，包含 Review Focus 的损坏备份测试。

- [x] **Step 7: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/application lib/platform/app_lock lib/features/settings test
git commit -m "feat: protect and recover local planner data"
```

### Task 17: 自选时间范围统计

**Files:**
- Create: `lib/application/analytics_service.dart`
- Create: `lib/domain/models/analytics.dart`
- Create: `lib/data/database/daos/analytics_dao.dart`
- Create: `lib/features/analytics/*`
- Test: `test/application/analytics_service_test.dart`
- Test: `test/features/analytics/analytics_page_test.dart`

**Interfaces:**
- Consumes: tasks、confirmed plan blocks、confirmed time entries。
- Produces: `AnalyticsService.query(AnalyticsFilter)` -> `AnalyticsReport`。

本任务加入 `fl_chart` 依赖并提交更新后的 `pubspec.lock`。

- [x] **Step 1: 写统计口径失败测试**

覆盖跨范围边界的时间块交集、计划与实际区分、完成率分母、按期完成、预估为零、生活配额、常见中断、重排原因、建议接受行为和自定义日期范围。

- [x] **Step 2: 实现 Drift 聚合查询和应用服务**

所有百分比模型同时返回 numerator、denominator 和 `isAvailable`，避免 UI 猜测口径。

- [x] **Step 3: 实现统计页面**

使用 `fl_chart` 展示领域分布、趋势和计划/实际对比；图表同时提供文本摘要和可访问标签。

- [x] **Step 4: 写性能基准测试**

生成 10,000 条 time entries，查询一年范围；记录基准结果。只有结果在目标设备上超过 300 毫秒才引入日汇总缓存。

- [x] **Step 5: 验证统计**

Run: `flutter test test/application/analytics_service_test.dart test/features/analytics`

Expected: 口径测试全部 PASS，基准结果记录在测试输出。

- [x] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/application/analytics_service.dart lib/domain/models/analytics.dart lib/data lib/features/analytics test
git commit -m "feat: visualize planned and actual time"
```

### Task 18: 正向反馈与改善建议

**Files:**
- Create: `lib/application/feedback_service.dart`
- Create: `lib/domain/models/feedback_message.dart`
- Create: `lib/features/analytics/feedback_cards.dart`
- Test: `test/application/feedback_service_test.dart`

**Interfaces:**
- Consumes: `AnalyticsReport` 当前期和对比期。
- Produces: `FeedbackService.generate(current, previous)` -> 最多 3 条 `FeedbackMessage`。

- [x] **Step 1: 写文案规则失败测试**

验证只根据真实可用指标生成反馈、最多三条、包含证据值；休息增加、娱乐达标、延期和低完成率不生成羞辱或惩罚文案。

- [x] **Step 2: 实现稳定规则和文案代码**

规则输出 message code、参数和证据，不在服务中拼接不可测试长文本。

- [x] **Step 3: 实现统计页反馈卡片**

允许用户隐藏单条建议，并说明统计范围。

- [x] **Step 4: 验证反馈**

Run: `flutter test test/application/feedback_service_test.dart test/features/analytics`

Expected: 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add lib/application/feedback_service.dart lib/domain/models/feedback_message.dart lib/features/analytics test
git commit -m "feat: add evidence-based positive feedback"
```

### Task 19: 可解释偏好学习

**Files:**
- Create: `lib/application/preference_service.dart`
- Create: `lib/domain/services/preference_analyzer.dart`
- Create: `lib/features/settings/preferences/*`
- Test: `test/domain/preference_analyzer_test.dart`
- Test: `test/application/preference_service_test.dart`
- Test: `test/features/settings/preferences_page_test.dart`

**Interfaces:**
- Consumes: `PreferenceEvidence`、当前 `PreferenceProfile`。
- Produces: `PreferenceAnalyzer.analyze`、`PreferenceService.confirm`、`reject`、`disable`、`clearLearned`、`undoLastAutoApply`。

- [x] **Step 1: 写门槛和异常排除失败测试**

19 条记录不建议，20 条且覆盖 14 个活跃日并有至少 15% 效果差异才建议；特殊日全部排除；同向手动移动 5 次可建议时段偏好。

- [x] **Step 2: 实现统计分析器**

每条建议返回证据数、日期范围、差异、建议值和 explanation code。

- [x] **Step 3: 写优先级和自动采用失败测试**

断言临时例外 > 用户设置 > confirmed/autoApplied 偏好 > 默认；自动采用不能修改最低睡眠、用餐和每日上限。

- [x] **Step 4: 实现偏好服务与审计撤销**

- [x] **Step 5: 实现偏好页面**

用户可查看依据、确认、拒绝、停用、清除和撤销自动更新。

- [x] **Step 6: 验证偏好学习**

Run: `flutter test test/domain/preference_analyzer_test.dart test/application/preference_service_test.dart test/features/settings/preferences_page_test.dart`

Expected: 全部 PASS。

- [x] **Step 7: Commit**

```bash
git add lib/application/preference_service.dart lib/domain/services lib/features/settings/preferences test
git commit -m "feat: learn explainable scheduling preferences"
```

### Task 20: 首次引导、端到端验收与 Windows 发布

**Files:**
- Create: `lib/features/onboarding/*`
- Create: `integration_test/first_plan_flow_test.dart`
- Create: `integration_test/emergency_replan_flow_test.dart`
- Create: `integration_test/backup_restore_flow_test.dart`
- Create: `docs/testing/manual-windows-checklist.md`
- Create: `docs/release/windows-release.md`
- Modify: `pubspec.yaml`
- Modify: `windows/runner/Runner.rc`

**Interfaces:**
- Consumes: 全部前序模块。
- Produces: 完整首次体验、自动化验收、版本化 Windows release 和 MSIX。

本任务加入 MSIX 打包依赖，锁定应用版本、包标识和升级策略，并提交 `pubspec.lock`。

- [ ] **Step 1: 写首次引导 widget 失败测试**

验证展示关键默认值、允许一键采用或修改、允许稍后设置；不开启自动调整和应用锁。

- [ ] **Step 2: 实现首次引导和空状态示例**

完成后写入 onboarding schema 版本，未来新增关键设置时可增量提示而不重复整个引导。

- [ ] **Step 3: 写三个端到端流程**

`first_plan_flow_test`：录入课程和任务、生成并确认首个七日计划；`emergency_replan_flow_test`：新增晚归活动、出现恢复保护和预览；`backup_restore_flow_test`：备份、修改、恢复并验证数据。

- [ ] **Step 4: 运行完整自动化验证**

Run: `dart run build_runner build --delete-conflicting-outputs`，`flutter analyze`，`flutter test`，`flutter test integration_test -d windows`

Expected: 生成代码无差异、分析无错误、全部单元、widget 和 integration 测试 PASS。

- [ ] **Step 5: 构建并验证 Windows 产物**

Run: `flutter build windows --release`，然后运行 `dart run msix:create` 生成 MSIX。

Expected: release EXE 启动成功，MSIX 可安装和卸载，本地通知、备份恢复和异常重启按手工清单通过。

- [ ] **Step 6: 核对需求验收清单**

逐项执行需求规格第 18 节；每项附自动化测试或手工证据，任何未通过项不得标记首版完成。

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "release: complete personal planner MVP"
```

## 14. 完成定义

一个任务只有在以下条件全部满足时才算完成：

1. 该任务列出的失败测试已先观察到预期失败。
2. 实现后相关测试、`flutter analyze` 和受影响的迁移测试通过。
3. 没有把领域规则复制到页面或 DAO。
4. 新增用户可见行为有错误、空状态和可访问性处理。
5. 数据模型变化包含 schema 快照和迁移测试。
6. 文档和测试使用的接口名与实现一致。
7. 改动以任务为单位提交，提交不混入无关修改。
8. 勾选该任务的全部步骤复选框，并把本任务引入的任何降级、偏差或接口改名登记到 §13.0，同时更新 §17 覆盖映射的真实状态。
9. 本任务新增的页面、服务或引擎必须在 `router.dart` 或组合根中完成接线，并有证据（测试或手工记录）表明其在运行期可达。仅有单元测试、无生产调用方的模块不计入完成。

第 8、9 条是针对本计划前 19 个任务实际暴露的问题而补充：此前复选框长期未勾选、§17 声称的覆盖在运行期无法兑现（详见 §13.0），说明这两类收尾动作必须成为完成定义的一部分，而不是事后补做。

## 15. 技术风险与控制

| 风险 | 控制措施 |
| --- | --- |
| 排程组合数量增长 | 5 分钟粒度、候选剪枝、有界局部改进、独立 isolate 和取消能力。 |
| 时区或重复事项错误 | 本地墙上时间 + IANA 时区、半开区间、DST 和跨午夜专门测试。 |
| 提案覆盖新数据 | 输入快照 SHA-256、应用前重算、事务与计划版本。 |
| 数据库升级丢数据 | Drift schema 快照、生成迁移、外键检查和真实旧版本迁移测试。 |
| Windows 通知行为受包身份限制 | 正式版使用 MSIX；只安排一次性通知；适配器可诊断能力。 |
| 偏好学习形成错误结论 | 明确样本门槛、排除特殊日、默认建议确认、可撤销和用户设置最高优先。 |
| 备份覆盖正常数据 | 临时目录验证、哈希、integrity check、schema 检查和原子替换。 |
| 未来移动端被桌面代码绑定 | 领域与排程无 Flutter 或平台依赖，平台能力走端口，页面使用响应式布局。 |

## 16. 暂不实施的技术项

- 账号、服务器 API、云同步和冲突解决；
- 数据库加密和加密备份；
- Android/iOS 打包与商店发布；
- 第三方日历双向同步；
- 大模型任务拆解或自然语言输入；
- 黑盒机器学习模型；
- 多用户、团队空间和实时协作。

这些能力需要独立需求、威胁模型和实施计划，不能在首版任务中顺手加入。

## 17. 需求覆盖映射

下表反映**复核后的真实状态**，不是计划意图。`真实状态` 列取值：已实现（可在运行期兑现）／部分／未实现。任何标注偏差编号的条目须先解决 §13.0 对应项，才能视为覆盖。

| 需求规格范围 | 主要实施任务 | 计划核心验证 | 真实状态 |
| --- | --- | --- | --- |
| FR-TODAY-01 至 04 | Task 10、12、13 | 今日页状态、快捷操作、完成后重排 | 部分：今日页已接入真实数据源（固定日程、保护时间、已确认计划块）（W2 已解决）；仍无"当前/下一项/剩余时间"汇总（FR-TODAY-01）、无跳过与延期入口（FR-TODAY-02）、无进度与休息提示（FR-TODAY-03）。偏差 W2 |
| FR-TASK-01 至 05 | Task 2、4 | 快速录入、完整编辑、筛选、批量调整和剩余时长 | 部分：快速录入、完整编辑与筛选已实现；修正剩余时长已全链路可用（数据层＋服务层＋任务详情页入口，见 R9）；标签已可用（R1 已闭合，提交 `d5d2054`…`56a1a52`）；领域与项目已可用（R2，提交 `ccd5dc9`）；无批量调整（R9）；任务转固定日程未实现（R9） |
| FR-CAL-01 至 06 | Task 4、5、10 | 一次性/重复日程、单次例外、周视图、拖动与冲突 | 部分：**一次性日程的界面入口不存在（本轮更正，此前写"缺 delete"是低估）**——`EventEditorForm` 在整个 `lib/` 里只出现在自己的文件中（无处渲染它），`CalendarService` 也没有生产构造点，因此"新建／修改一条一次性日程"在界面上**无法完成**，不只是删不掉；**重复日程已可创建并展开**（提交 `a5231d9`：表单有"按周"开关并把 `recurrenceWeekdays` 交给服务，仓储按规则展开；全套 340 项通过）；**R4 第二半的"数据与服务"这一层已完成（本轮），界面入口仍缺**——新增**单独端口** `CalendarEventDeletion`（不往 `CalendarRepository` 加方法，因为它有 **5 个测试替身**，加一个成员会一次牵动 5 个文件）、`DriftCalendarRepository` 实现它（**幂等**：删不到即已删掉，避免过期视图引发无关报错）、`CalendarService.deleteEvent` 返回 `bool`（未装配端口时返回 false，不假装删掉）。两条用例用**真实 drift 仓储**（SQL 行为替身证明不了）：删除后区间查询里不再出现**且其余日程不受影响**（只断言"被删的没了"会让"全删"也通过）、重复删除幂等。**删除的界面入口与组合根装配已接（本轮），因此"删除"这条链路首次在用户路径上成立**：日视图每条日程右侧有删除按钮（键为 `delete-<id>`；**未注入删除端口时整块不渲染**，不留点了不生效的图标），页面只交回条目 id，路由把 `calendarService.deleteEvent` 注入，`main.dart` 把同一个仓储实例也作为删除端口装配——**没有这一行，按钮会显示却不生效**，这正是"死控件"的成因。用例断言两条：点击**交回的是那一条的 id**（"被点了"与"删对了"是两件事）、未注入时**没有**该按钮。**删除后不需要手动刷新**：日程视图由 drift 的 `watch` 驱动，写入会使它重新发出。**仍缺：单次/系列的例外语义，而且本轮查明它不只是"没做"，而是数据路径会静默丢弃例外**。三条经代码核实的事实：**(1) 没有表示"这一次被删除"的列**——`calendar_events` 的列为 id／title／起止／`timeZoneId`／`recurrenceRuleId`／`exceptionOfId`／`locked`／`areaId`／时间戳，而领域层的 `RecurrenceException.deleted`（展开器已支持）**没有存储对应物**；**(2) 例外行只在锚点查询里被排除，在单次查询里却会作为"独立事件"出现**（单次查询当时只按 `recurrenceRuleId.isNull()` 过滤）。**本条是我上一轮写错了的判断，本轮由一条断言当场纠正**：我原写"两个查询都排除它"，据此推断"例外行完全不可见"；实测恰恰相反——那条例外行**自己作为一条事件出现**，于是同一次既以"独立事件"现身、又由展开器输出"替换结果"，**同一次出现两遍**（实测 `[10-05 09:00, 10-12 14:00, 10-12 14:00]`）；**(3) 展开时传的是 `const []`**（同文件第 74 行），因此**展开器根本不接收例外**——被覆盖的那一次仍按常规出现。**替换型例外已修好（本轮）**：仓储现在把例外行按锚点分组、以规则时区换算成本地日期、转成 `RecurrenceException.replaced` 交给展开器，并让单次查询**排除例外行**（它只通过展开器生效）。三条用例：没有例外时两周展开两次（先立基线，否则无法区分"替换生效"与"本来就少一条"）、**恰好两条**且被改的那次为新时间、窗口之外的例外不影响窗口内各次。**仍未表示的是"删掉这一次"**——那需要下方的表示方式决策。**仍然成立的是****这需要一个产品／数据模型决策，三条路**：**(a) 加一列**（如 `deleted_at_utc` 或 `exception_kind`）——语义最清楚，代价是一次 **schema v4 迁移**＋迁移测试＋快照；**(b) 用约定**（例如"零长度或 `locked=false` 的例外行表示删除"）——无需迁移，但**等于给数据库定义一条隐含规则**，后来者必须知道它；**(c) 首版明确不支持单次例外**，在规格里写明，而不是留着一个会静默丢数据的半成品。**在选定之前不动**：任何一条都能让"删这一次"可用，但选错会造出"用户以为删掉了、下次打开又出现"的行为。**原登记**：——`EventEditScope`（单次/系列）仍只被采集、`CalendarRepository` 仍无 `delete`，因此"单次例外与删除"未实现；日视图已实现（R3，提交 `2989e17`）；四类时间块的区分现已显示真实数据（W2 已解决），但拖动仍禁用（R9）；创建时不检测冲突 |
| FR-RULE-01 至 06 | Task 2、10A、11 | 作息、精力、配额、工作日/周末和指定日期例外 | 基本实现：作息/精力/配额/工作日与周末规则已实现；指定日期例外机制正确但无 UI 入口 |
| FR-DEFAULT-01 至 08 | Task 2、10A、19、20 | 默认值、中性回退、首次引导、优先级、记录与撤销 | 部分：默认值与优先级正确；首次引导门控已生效（W4 已解决）；自动采用无门控（FR-DEFAULT-05）；变更日志不记前后值（FR-DEFAULT-07） |
| FR-SCHED-01 至 09 | Task 5 至 9 | 七日窗口、远期压力、硬约束、评分、拆分、连续性和可复现 | 部分：生产数据源与七日窗口已接线，引擎可在运行期产出计划（W1 已解决）；评分表中 8 个因子在候选层面不生效（R6、C2）；片段间休息已实施（C1，算法版本 2）；无移动原因（R7）；locked 重复计入上限（C3，已修复） |
| FR-REPLAN-01 至 08 | Task 9、10、13 | 提案、diff、确认/自动应用、过期拒绝、冲突和撤销 | 部分：快照哈希与过期拒绝已实现（FR-REPLAN-05）；**本行原有三处断言已过期，本轮更正**——① "预览为空桩（W2）"**不成立**：W2 早已解决，`_PlanPreviewLoader` 由真实提案装配模型（并已在 C8 的恢复链路上验证可达）；② "diff 缺 split 与 reason（R7）"**不成立**：`plan_differ.dart:89` 会产出 `PlanChangeType.split`（我为本规则补了三例并做变异验证），且 reason 由 `after.explanationCode ?? before.explanationCode` 填充；③ "冲突无 UI"**不成立**：`router.dart:673` 把 `proposal.conflicts` 映射为标签，`plan_preview_page.dart` 的 `_ConflictGroup` 负责渲染。**仍成立**：自动应用路径不存在（W8，属产品决策——见该行）；**处理入口部分可用**（FR-REPLAN-07：**"取消事项"已可用**，提交 `0f0c6d9`；优先级、截止日期、临时放宽每日上限仍缺，"修正预计时长"按设计不支持）；**撤销**的数据层已完整实现但无调用方与界面（W10，约 11 个编辑）
| FR-RECOVERY-01 至 06 | Task 11 | 晚归、最低睡眠、早课冲突、补觉和单次放宽 | 基本实现但不可达：最低睡眠计算、早课冲突告警、单日例外均正确；单次例外已改为提案输入；路由已接通（提交 `226ff8f`）；先落库后提案（C8） |
| FR-FOCUS-01 至 05 | Task 12 | 计时状态机、异常恢复、补录与剩余时长更新 | 部分：计时状态机与单调钟正确；**崩溃恢复已可达**（提交 `d9a437b`：进入专注页即提示确认上次未结束的计时，可确认实际时长或选择不计入；此前 `FocusRecoveryDialog` 全库无人引用、页面没有 `initState`，异常退出的记录会永远停在待确认）；补录与剩余时长重算未实现（R9，其中"重算"撞上 `remainingMinutes > 0` 的域不变量，需先选定语义） |
| FR-STAT-01 至 09 | Task 17、18 | 自选范围、指标口径、趋势、计划/实际区分和温和反馈 | 部分：范围与趋势已实现；**"反馈文案与温和原则达标"原先写得过强，本轮更正**——`feedback_message.dart` 模型与统计页（接收 `feedbackMessages`）都已就绪，但**没有任何生产者**（`feedback_service.dart` 全库无人引用、`AnalyticsService` 不产出该类型），因此该列表恒为空、用户看不到反馈，属**不可达**（W10）；标签筛选已可用（R1 已闭合）、无筛选 UI；精力与休息统计未实现（R9）；建议类事件已有来源（W5 部分，提交 `497baad`） |
| FR-PREF-01 至 08 | Task 7、19 | 证据采集、门槛、解释、确认、自动采用、异常排除和清除 | 部分：门槛常量与设计一致、只影响软约束；证据写入方已接通（W6，提交 `c6e7f63`）；**"无修改偏好值入口"已不成立**——并发写者已实现"修改学习建议"（提交 `99e60a5`，含"保持待确认且新值可见"的用例）；存储键断裂（W5）；**特殊日排除仍不生效**（`FocusEvidenceRecorder` 始终写 `specialDay: false`，FR-PREF-07 的排除因此形同虚设——这一条此前只记在别处，此处补上）；自动采用（FR-PREF-04 的"可选自动采用"）仍缺行为（W8） |
| FR-NOTIFY-01 至 04 | Task 10A、14 | 一次性通知、分类设置、免打扰和快捷入口 | 部分：仅"任务开始"一类、免打扰正确；其余三类无实现（R8）；点击快捷入口已在冷启动被消费（W6，提交 `f4b26c5`） |
| FR-DATA-01 至 08 | Task 3、15、16 | 本地存储、备份校验、导出、清除、应用锁和同步预留字段 | 部分：备份校验顺序、导出、永久清除达标；备份缺 WAL 快照（C4）；应用锁已拦截启动（W6，提交 `cf542d8`）；时间戳不齐（R10） |
| 非功能与发布 | Task 1、3、8、9、16、20 | Windows 构建、性能、迁移、事务、恢复、可访问性和 MSIX | 部分：事务与恢复机制达标；迁移测试已具备（T4 该条已更正）；排程不可取消且有界性不足；无 MSIX、无 release 产物、无 CI（T5） |
