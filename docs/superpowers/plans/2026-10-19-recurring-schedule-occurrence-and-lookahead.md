# 周期目标：单次执行、跨周预排与历史一致性实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Every task is test-first and uses checkbox (`- [ ]`) tracking. 只允许一个写入者顺序实施；禁止多个代理并行修改本计划涉及的共享领域模型、数据库、排程输入、执行账本或路由文件。

**Goal:** 在 1.11.0 的执行事实架构上，消除周期目标的身份混用，使每个可见周期片段可以独立完成，历史计划不会因补记或重排消失，并在本周内可靠展示下一完整周的可确认预排。

**Architecture:** 模板只提供系列默认值；周实例保存结算快照；隐藏的普通任务只作为排程兼容载体；执行实例保存一次承诺谱系；执行片段对应一个可独立完成的可见块；真实活动和声明完成以不可重复记账的证据进入周实例。正式计划与待确认预排分库存储，预排经基线、输入摘要、算法版本和完整校验后才能合并进入正式计划。

**Tech Stack:** Dart 3、Flutter、Drift/SQLite、GoRouter、现有 `TimeZoneDatabase`、1.11.0 `ExecutionOccurrence`/credit 基础、`flutter_test`；不增加云服务、网络依赖或第二套执行系统。

**Spec:** `docs/superpowers/specs/2026-10-19-recurring-schedule-occurrence-and-lookahead-design.md`

**Target:** 应用版本 1.11.0；数据库 schema 保持 11，新增表并入 v11。算法版本只在全部门禁通过后提升，实施者必须从当前代码读取真实旧值，不能照抄文档中的假定值。

---

## 0. 实施纪律、基线与完成口径

### 0.1 开工前硬门禁

- [ ] 在开始任何生产代码前，记录当前提交、分支、`pubspec.yaml` 版本、`AppDatabase.schemaVersion`、排程算法版本、全量测试结果。
- [ ] 确认 1.11.0 的执行事实迁移、事务接线、启动恢复和已有验收全部完成；任何一项仍为 PARTIAL，本计划不得开始写新的 schema 扩展。
- [ ] 当前工作树若仍包含 1.11.0 未提交改动，先完成并提交 1.11.0，或从其已确认提交创建专用工作树。不得在含未知未提交变更的工作树上叠加本计划。
- [ ] 保存 schema v11 数据库快照和至少一份含周期目标、拆分计划块、手动记录、已结算历史的升级夹具。
- [ ] 运行并保存以下基线输出：

```powershell
git status --short
git rev-parse HEAD
rg -n "schemaVersion|algorithmVersion" lib
flutter analyze
flutter test
```

若基线本身失败，先单独定位并修复基线；不得把既有失败混入本计划，也不得用删除测试、放宽断言或更新 golden 的方式消除红灯。

### 0.2 单写入者规则

本计划的模型、迁移、执行链接、排程输入、历史投影和路由高度耦合。推荐单一执行流，Task 1–19 严格顺序实施：

1. 一个 Task 的生产改动、专项测试、相关回归未全部通过，下一 Task 不得开始；
2. 每个 Task 结束时记录改动文件、测试命令、测试数量和未验证项；
3. 可做只读审查，但不得让第二写入者在共享工作树并行修改相邻接口；
4. 生成文件只能由生成器产生，禁止手改 `*.g.dart` 和 `app_database.steps.dart`；
5. 不自动提交。若项目负责人要求提交，每个 Task 使用独立、可回滚的逻辑提交。

### 0.3 “完成”的严格定义

以下情况只能标记 PARTIAL，禁止写成“已完成”：

- 只有接口和单元测试，真实组合根没有接线；
- 服务可调用，但 Today、日历、任务详情或路由仍走旧 `taskId` 语义；
- 页面测试使用假回调通过，但生产仓储、事务或 GoRouter 链路没有覆盖；
- 预排能生成但不能跨重启恢复，或确认时不能原子合并；
- 数据迁移只测空库，未测真实 v11 数据；
- 只测成功路径，未测重复点击、并发、过期输入、断电前后恢复；
- 全量测试通过但应用内真实链路未做至少一条 app-router 端到端验证；
- 手工验收未执行时，必须明确标成“自动化通过、手工待验”，不能合并成一句“全部通过”。

---

## 1. 文件职责与冻结边界

### 1.1 预计新增生产文件

| 文件 | 单一职责 |
| --- | --- |
| `lib/domain/execution/execution_fragment.dart` | 执行片段和值对象；不访问仓储 |
| `lib/domain/models/recurring_completion_evidence.dart` | 周期声明完成、手动补记与撤销证据模型 |
| `lib/domain/models/pending_plan_preview.dart` | 持久化预排、基线和状态模型 |
| `lib/domain/repositories/pending_plan_preview_repository.dart` | 预排读写、失效、确认端口 |
| `lib/application/recurring_cycle_maintenance_service.dart` | 滚动创建相交周实例、预排维护和 single-flight |
| `lib/application/recurring_progress_service.dart` | 真实活动、声明完成、手动补记、撤销的统一记账入口 |
| `lib/application/pending_plan_preview_service.dart` | 生成、验证、拒绝、确认与自动应用预排 |
| `lib/application/recurring_template_scope_service.dart` | 仅本周／下周起／整个系列和生命周期操作 |
| `lib/data/repositories/drift_pending_plan_preview_repository.dart` | v11 预排仓储 |
| `lib/scheduling/recurring_pace_curve.dart` | 纯函数推进曲线与 `targetNow` 计算 |
| `lib/scheduling/recurring_cycle_capacity.dart` | 整周容量预测及当前窗口必排量 |

名称如需调整，必须先更新本节、对应测试名和 §21 审计矩阵，防止实现与文档漂移。

### 1.2 预计修改的核心生产文件

| 文件 | 必须承担的变化 |
| --- | --- |
| `lib/data/database/tables/execution_tables.dart` | 执行片段、block link 的 `fragmentId`、完成证据或其关联 |
| `lib/data/database/tables/planner_tables.dart` 或现有周期表文件 | 周实例完整快照、精确 UTC 边界、预排表 |
| `lib/data/database/app_database.dart` | schema v11 扩展、单向迁移、索引和约束 |
| `lib/data/database/daos/recurring_task_dao.dart` | “区间相交”查询，禁止只比较周一日期 |
| `lib/data/repositories/drift_recurring_task_repository.dart` | 幂等创建结果、证据记账、删除墓碑、跨周拆分 |
| `lib/data/repositories/drift_execution_repository.dart` | 片段链接、回填、完成与撤销事务 |
| `lib/application/recurring_task_service.dart` | 去除 `periods.first`、错误 `now` 归属和无条件达标 |
| `lib/application/execution/execution_plan_linker.dart` | occurrence 下建立独立 fragment，不再用同一 occurrence 表示所有拆分块完成状态 |
| `lib/application/execution/execution_service.dart` | 从“按 task 找第一 occurrence”改成显式 fragment/occurrence 命令 |
| `lib/application/repository_schedule_problem_source.dart` | 先维护周实例再读取输入；读取全部相交周；带入有效边界和软精力偏好 |
| `lib/features/calendar/week_view/schedule_view_source.dart` | 按 fragment 和计划版本投影，历史不依赖任务终态 |
| `lib/features/tasks/task_list_page.dart` 及过滤器 | 隐藏内部载体并从普通计数、批量操作剔除 |
| `lib/features/today/today_page.dart` | 完成本次、撤销和深链均使用 fragment 身份 |
| `lib/application/notification_service.dart` | 片段级去重；预排不发正式提醒；不路由到隐藏任务 |
| `lib/data/database/daos/analytics_dao.dart` | 普通任务与周期目标口径分离；按证据与历史版本统计 |
| `lib/data/repositories/drift_export_data_source.dart` | 导出周期、执行片段、证据、预排及版本字段 |
| `lib/application/backup_service.dart` | v11 备份／恢复兼容与恢复后重建派生状态 |
| `lib/app/router.dart`、`lib/main.dart` | 真实页面、服务和仓储接线；不得内嵌业务判断 |

### 1.3 不得跨越的边界

- 不新建第二套 focus/session/occurrence 系统；复用并扩展 1.11.0。
- 内部排程载体保留仅为调度兼容，不能继续成为用户可操作实体。
- 计划历史不可变；删除周期目标只能匿名化/墓碑化，不得级联删除历史计划块。
- 正式计划和待确认预排不能共享“当前计划”标志。
- 精力、期望时段和节奏是软偏好，不得把其他合法空闲时间直接删掉。
- 周界和本地日期全部由 `TimeZoneDatabase` 计算；禁止用 `Duration(days: 7)` 代替本地周推进。
- 所有业务命令显式接收一次捕获的 `nowUtc`；领域与仓储内部不得各自调用 `DateTime.now()`。

---

## 2. 冻结的数据与服务契约

实施前先以失败测试冻结以下语义。字段名可按仓库风格微调，但含义不得丢失。

```dart
final class RecurringCycleSnapshot {
  const RecurringCycleSnapshot({
    required String cycleId,
    required String templateId,
    required String transportTaskId,
    required DateTime periodStartUtc,
    required DateTime periodEndUtc,
    required String periodStartLocalDate,
    required String periodEndLocalDateExclusive,
    required String planningTimeZoneId,
    required DateTime effectiveStartUtc,
    required DateTime effectiveEndUtc,
    required int targetMinutes,
    required String pace,
    required String energyPreference,
    required Set<int> allowedWeekdays,
    required int templateRevision,
    required int cycleRevision,
    required String state,
    DateTime? settledAtUtc,
  });
}

final class ExecutionFragment {
  const ExecutionFragment({
    required String fragmentId,
    required String occurrenceId,
    required String cycleId,
    required String planVersionId,
    required String blockId,
    required DateTime plannedStartUtc,
    required DateTime plannedEndUtc,
    required int plannedMinutes,
    required String state,
    required int revision,
  });
}

enum RecurringEvidenceKind {
  activity,
  fragmentCompletion,
  manualAdjustment,
  correction,
}

final class RecurringCompletionEvidence {
  const RecurringCompletionEvidence({
    required String evidenceId,
    required String cycleId,
    required RecurringEvidenceKind kind,
    required int creditedMinutes,
    required DateTime occurredAtUtc,
    required String idempotencyKey,
    String? fragmentId,
    String? sourceSegmentId,
    String? reversesEvidenceId,
  });
}

enum PendingPreviewStatus {
  proposed,
  confirmed,
  rejected,
  stale,
  superseded,
}

final class PendingPlanPreview {
  const PendingPlanPreview({
    required String previewId,
    required String basePlanVersionId,
    required String normalizedInputHash,
    required String algorithmVersion,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required PendingPreviewStatus status,
    required DateTime createdAtUtc,
    required int revision,
  });
}
```

仓储写入必须返回明确结果，禁止用“查到确定性 ID 就认为本次创建成功”推测并发结果：

```dart
sealed class CreateCycleResult {
  const CreateCycleResult();
}
final class CycleCreated extends CreateCycleResult { /* snapshot */ }
final class CycleAlreadyExists extends CreateCycleResult { /* snapshot */ }
final class CycleCreateRejected extends CreateCycleResult { /* typed reason */ }
```

核心命令必须是片段级且支持幂等：

```dart
Future<FragmentCompletionResult> completeFragment({
  required String operationId,
  required String requestHash,
  required String planVersionId,
  required String blockId,
  required String fragmentId,
  required int expectedFragmentRevision,
  required DateTime occurredAtUtc,
});

Future<RecurringProgressResult> recordManualProgress({
  required String operationId,
  required String requestHash,
  required String cycleId,
  required int minutes,
  required DateTime occurredAtUtc,
  required DateTime nowUtc,
});

Future<PreviewApplyResult> confirmPreview({
  required String operationId,
  required String requestHash,
  required String previewId,
  required String expectedBasePlanVersionId,
  required String expectedInputHash,
  required int expectedPreviewRevision,
  required DateTime nowUtc,
});
```

幂等规则固定为：相同 `operationId + requestHash` 返回第一次持久化结果；相同 `operationId` 携带不同 `requestHash` 返回冲突，不得执行第二次。

---

## Task 1：建立故障特征测试和审计台账

**目的：** 在修改结构前证明现有缺陷确实存在，防止实现过程中把错误行为当兼容行为保留。

**新增／修改测试：**

- `test/application/recurring_occurrence_characterization_test.dart`
- `test/application/recurring_history_characterization_test.dart`
- `test/application/recurring_lookahead_characterization_test.dart`
- `test/features/tasks/recurring_transport_task_visibility_test.dart`
- `test/features/execution/recurring_fragment_completion_test.dart`
- `docs/testing/recurring-schedule-occurrence-acceptance.md`

**步骤：**

- [ ] 复制真实失败形状到最小夹具：一个周实例、三个拆分块、一个已结束未完成块、一个未来块、一个跨周活动段。
- [ ] 写失败测试证明完成第一个块不会完成第二、第三块；当前旧实现应失败。
- [ ] 写失败测试证明手动补记后，已经开始、结束或完成的历史块仍可见且状态不变。
- [ ] 写失败测试证明本周能看到下一完整周预排，而不是仅看到 `now + 7×24h` 覆盖的尾部。
- [ ] 写失败测试证明内部载体不进入普通任务数量、搜索结果、批量完成、详情深链。
- [ ] 写失败测试证明精力偏好不能导致其他合法空闲时间被视为不可用。
- [ ] 给每个失败测试标注 §21 的需求 ID；记录“预期失败原因”，避免因为编译错误产生假红灯。
- [ ] 运行专项测试，确认失败来自旧语义：

```powershell
flutter test test/application/recurring_occurrence_characterization_test.dart test/application/recurring_history_characterization_test.dart test/application/recurring_lookahead_characterization_test.dart test/features/tasks/recurring_transport_task_visibility_test.dart test/features/execution/recurring_fragment_completion_test.dart
```

**停止条件：** 若无法在无 UI 截图依赖的最小夹具中复现三项主故障，不得继续设计迁移；先查清实际数据链路。

---

## Task 2：schema v11 扩展与可回滚迁移证据

**目的：** 先建立稳定身份、周界快照、片段、证据和持久预排，不允许服务层靠内存或标题猜测。

**版本口径（覆盖旧稿残留）：** 源数据库 schema **v10**，目标数据库 schema **v11**，产品版本 **1.11.0**；禁止创建 schema v12，禁止任何 v11→v12 演练。

**修改：**

- `lib/data/database/tables/execution_tables.dart`
- 周期表所在的数据库声明文件
- `lib/data/database/app_database.dart`
- `test/data/database_schema_test.dart`
- `test/drift/app_database/migration_test.dart`
- `drift_schemas/app_database/`

**步骤：**

- [x] 先写 v10→v11 迁移测试，覆盖非空数据库：v10 模板行迁移后仍可见（标题/目标/时区/状态不变），并保留空库 v10→v11 校验。
- [x] 扩展 `recurring_task_cycles`，至少保存 `cycle_id`、精确 UTC 周界、有效区间、计划时区、完整排程快照、revision、settledAt。
- [x] 新增 `execution_fragments`，对 `(plan_version_id, block_id)` 唯一；`execution_block_links` 增加非空或迁移后可收紧的 `fragment_id`。
- [x] 新增完成证据表，`idempotency_key` 唯一；反向证据用外键或可验证引用，不物理修改原证据。
- [x] 新增 `pending_plan_previews` 和 preview blocks；正式计划表不得复用。
- [x] 为 `(template_id, period_start_local_date)`、cycle 状态与边界、fragment、evidence、preview 状态建立必要唯一约束和索引。
- [x] v10 数据迁移先生成稳定 `cycleId`，再生成 occurrence/fragment 链接；无法唯一映射的旧块写 `needsReview`/歧义 outbox，不得悄悄链接到第一条 occurrence。
- [x] 生成 Drift 文件和迁移步骤：

```powershell
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev make-migrations
```

- [x] 运行迁移测试和数据库约束测试：

```powershell
flutter test test/data/database_schema_test.dart test/drift/app_database/migration_test.dart
```

**必须断言：** 行数守恒；历史计划块不被删除；所有旧周期进度可追溯；重复迁移不可重复加分钟；preview 表初始为空；外键检查通过。

**停止条件：** 无法保留旧历史链接、或迁移只能通过删除异常行时立即停止。旧版本应用不能安全打开 v11 数据库，回退方案必须是恢复升级前快照，而不是降级二进制直接开库。

---

## Task 3：冻结周实例快照与时区权威

**目的：** 周实例不再在每次排程时读取可变模板，也不再用当前设备／服务全局时区重算历史周界。

**修改：**

- `lib/domain/models/recurring_task.dart`
- `lib/application/recurring_period.dart`
- `lib/data/database/daos/recurring_task_dao.dart`
- `lib/data/repositories/drift_recurring_task_repository.dart`
- `lib/application/recurring_task_service.dart`
- 对应 domain/data/application 测试

**步骤：**

- [ ] 先测上海周界、DST 时区周界、周中开始、周中结束、跨年周和半开区间。
- [ ] 以工作区计划时区生成本地周一／下周一，再转换成 UTC；禁止 `startUtc.add(Duration(days: 7))`。
- [ ] DAO 的可生成条件改为有效区间与周区间相交：`effectiveStart < periodEnd && effectiveEnd > periodStart`。
- [ ] 创建周实例时一次性复制 target、pace、energy、weekday、拆分与上限等全部排程字段。
- [ ] 所有已创建周期从自身快照读取；模板只用于尚未创建的未来周期。
- [ ] 仓储返回 `CycleCreated` / `CycleAlreadyExists` / typed rejection；只捕获唯一约束冲突，其他异常原样上抛。
- [ ] 运行：

```powershell
flutter test test/application/recurring_period_test.dart test/data/recurring_task_dao_test.dart test/application/recurring_task_service_test.dart
```

**停止条件：** 任一历史周界仍需依赖当前时区数据库或模板当前值时，不得进入模板范围实现。

---

## Task 4：模板作用域与生命周期状态机

**目的：** 真正区分“仅本周／从下周／整个系列”，并让暂停、恢复、跳过、归档、删除具有可验证语义。

**新增／修改：**

- `lib/application/recurring_template_scope_service.dart`
- `lib/application/recurring_task_service.dart`
- `lib/data/repositories/drift_recurring_task_repository.dart`
- `test/application/recurring_template_scope_service_test.dart`
- `test/application/recurring_lifecycle_test.dart`

**步骤：**

- [ ] 先写矩阵测试：编辑 target、pace、energy、weekday、有效日期，每项分别测三种范围。
- [ ] “仅本周”只改开放 cycle snapshot，并增加 cycle revision。
- [ ] “从下周”改模板和未开始 future cycles；当前周、已结算周不动。
- [ ] “整个系列”改模板、当前开放周和未开始 future cycles；历史只保留原快照。
- [ ] 暂停保留历史块；暂停区间内未开始的未来正式块失效并触发受控重排。
- [ ] 恢复只从恢复时刻后重新安排，不复活已经过去的块。
- [ ] 跳过本周生成显式结算／跳过事实；不能伪装成 0 分钟达标。
- [ ] 归档停止未来实例和提醒，不删除历史。
- [ ] 删除改为 tombstone／匿名化；历史计划版本、fragment、evidence 保留引用完整性。
- [ ] 每个业务动作提交后只发一个重排事件，禁止递归回调再次进入 `ensureCycles`。
- [ ] `RecurringCycleRun.changed` 同时覆盖创建、结算、carry-in 改变、快照改变、载体投影改变和状态更正；不能继续只统计“创建／结算”。

```powershell
flutter test test/application/recurring_template_scope_service_test.dart test/application/recurring_lifecycle_test.dart
```

---

## Task 5：业务事务、幂等和成员资格防线

**目的：** 所有内部载体的写操作只能通过周期／执行服务进入，任何普通任务入口不得绕过不变量。

**修改：**

- 周期、执行、计划相关 repository interfaces
- Drift 对应仓储
- `lib/application/task_service.dart`
- `lib/application/execution/execution_commands.dart`
- `lib/app/router.dart`
- `test/application/recurring_transaction_boundary_test.dart`
- `test/application/internal_transport_task_guard_test.dart`

**步骤：**

- [ ] 写测试覆盖重复点击、两个并发创建、两个并发完成、事务中途失败、重排事件重复投递。
- [ ] 建立统一业务事务入口：周期事实、执行链接、进度证据、计划变更和 outbox／失效信号必须同事务提交。
- [ ] 对所有按 `taskId` 的修改、完成、删除、批量、深链动作增加“内部载体”成员资格检查。
- [ ] 普通 API 遇到内部载体返回 typed denial，并给调用者周期详情／fragment 路由信息；不能直接改其 task row。
- [ ] 幂等键由调用端产生并持久化；重试返回第一次结果，不能再次记账。
- [ ] single-flight key 至少包含工作区和维护窗口；并发维护共享同一结果。

```powershell
flutter test test/application/recurring_transaction_boundary_test.dart test/application/internal_transport_task_guard_test.dart
```

**停止条件：** 计划、链接和证据无法在同一数据库事务内原子提交时停止；不得用补偿式“尽量恢复”替代本机 SQLite 原子性。

---

## Task 6：执行片段身份与 1.11 occurrence 回填

**目的：** occurrence 表示承诺谱系，fragment 表示一次可独立完成的可见块，彻底消除同 occurrence 多块联动打勾。

**修改：**

- `lib/domain/execution/execution_models.dart`
- `lib/domain/execution/execution_fragment.dart`
- `lib/application/execution/execution_plan_linker.dart`
- `lib/data/repositories/drift_execution_repository.dart`
- `test/application/execution/execution_plan_linker_test.dart`
- `test/application/execution/execution_fragment_backfill_test.dart`

**步骤：**

- [ ] 写失败测试：一个 occurrence 经 `continuedFromId` 拆成三个块，三个 fragment ID 必须不同。
- [ ] 每个已确认块恰好创建／复用一个 fragment；链接键为 plan version + block ID，不能只看 task ID。
- [ ] 重排保留 occurrence 谱系，但新可见块获得新 fragment；旧 fragment 状态仍用于历史投影。
- [ ] 启动回填扫描 1.11 已确认计划，为缺 fragment 的块补齐；有歧义时记录 review 状态，不能选择“第一条 occurrence”。
- [ ] 回填可重复运行且结果逐值相同。

```powershell
flutter test test/application/execution/execution_plan_linker_test.dart test/application/execution/execution_fragment_backfill_test.dart
```

---

## Task 7：统一周期进度账本与跨周活动拆分

**目的：** 真实活动、声明完成、手动补记和更正均进入同一可审计账本，分钟守恒且不重复。

**新增／修改：**

- `lib/application/recurring_progress_service.dart`
- `lib/data/repositories/drift_recurring_task_repository.dart`
- `lib/data/repositories/drift_execution_repository.dart`
- `lib/domain/execution/execution_progress.dart`
- `test/application/recurring_progress_ledger_test.dart`
- `test/application/recurring_cross_week_allocation_test.dart`

**步骤：**

- [ ] 写真实活动 23:50–00:20 跨本地周界的测试，按精确交集拆成两段，而不是全部归开始周。
- [ ] `_applyActivity` 根据 target kind 写入 recurring cycle credit，不得硬编码普通 task。
- [ ] 手动补记显式接收 `occurredAtUtc` 和目标 `cycleId`；禁止用保存时的 `now` 替代发生时刻。
- [ ] 进度为有效正向证据减反向证据；原证据不可改写。
- [ ] 建立信用守恒测试：任一 activity segment 在所有 target 上的有效分配合计不得超过其分钟数。
- [ ] 重建／重试不会重复生成 credit；删除或更正创建反向证据。

```powershell
flutter test test/application/recurring_progress_ledger_test.dart test/application/recurring_cross_week_allocation_test.dart test/data/execution/execution_cycle_allocation_test.dart
```

---

## Task 8：片段级完成、撤销与达标推导

**目的：** 点击一个块只完成该块；周目标状态由证据推导，不能因调用 `completeCycle` 无条件变成达标。

**修改：**

- `lib/application/execution/execution_service.dart`
- `lib/application/recurring_progress_service.dart`
- `lib/application/recurring_task_service.dart`
- `lib/domain/execution/execution_result.dart`
- `test/features/execution/recurring_fragment_completion_test.dart`
- `test/application/recurring_completion_undo_test.dart`

**步骤：**

- [ ] 写三片段测试：完成 B 后只有 B 显示完成，A/C 不变，周期累计只增加 B 尚未被活动覆盖的部分。
- [ ] 若片段计划 50、真实活动已覆盖 40，声明完成只写 10 的 `fragmentCompletion` 证据。
- [ ] 若真实活动已覆盖 55，完成动作只改变 fragment 状态，不增加 credit。
- [ ] 撤销完成只反向该片段的声明证据；不删除真实活动，不撤销同 occurrence 的其他 fragment。
- [ ] `met` 仅由 `creditedMinutes >= targetMinutes` 推导；显式结束周若不足目标，状态为未达标或用户结束，不得写 `met`。
- [ ] 达标后不新增未来块；已有历史块和额外真实投入保留。
- [ ] 下一周实例可先保存明确标记的 provisional carry-in，供预排解释使用；上周正式结算后必须在同一维护事务中重算为 settled carry-in，并让依赖旧值的预排变 stale。
- [ ] `skipped` 周不结转缺口；普通未达标周是否结转及上限严格读取实例快照，不能从当前模板临时推测。

```powershell
flutter test test/features/execution/recurring_fragment_completion_test.dart test/application/recurring_completion_undo_test.dart test/application/recurring_task_progress_test.dart
```

---

## Task 9：排程输入顺序、全相交周期与硬边界

**目的：** 先生成／维护周期，再读取 open tasks；一次计划加载所有与两个窗口相交的周期，并尊重有效起止。

**修改：**

- `lib/application/repository_schedule_problem_source.dart`
- `lib/application/repository_recurring_cycle_reader.dart`
- `lib/application/recurring_cycle_maintenance_service.dart`
- `test/application/recurring_schedule_input_order_test.dart`
- `test/application/recurring_intersecting_cycles_test.dart`

**步骤：**

- [ ] 先测“库中尚无本周载体，首次生成计划也能包含它”；旧先读任务后 ensure 的顺序应失败。
- [ ] 维护所有与执行窗口和预排窗口相交的周期，而不是只处理 `periods.first`。
- [ ] 每个周期传入 `availableFromUtc = max(effectiveStart, periodStart, now/窗口起点)` 和 `deadlineUtc = min(effectiveEnd, periodEnd)`。
- [ ] 过滤已结算、跳过、归档和无有效交集的周期；暂停周期按暂停区间截断。
- [ ] 精力、期望时段只进入评分／偏好，不删除合法候选。
- [ ] 生成回调只发一次维护完成事件，禁止 `ScheduleProblemSource → ensureCycles → replan → ScheduleProblemSource` 递归。

```powershell
flutter test test/application/recurring_schedule_input_order_test.dart test/application/recurring_intersecting_cycles_test.dart test/application/recurring_enters_schedule_test.dart
```

---

## Task 10：整周容量预测与节奏推进算法

**目的：** 当前窗口只承担整周中“现在必须完成”的分钟，避免工作日被提前挤满，也避免周末无容量时拖到最后。

**新增／修改：**

- `lib/scheduling/recurring_pace_curve.dart`
- `lib/scheduling/recurring_cycle_capacity.dart`
- `lib/application/repository_schedule_problem_source.dart`
- 调度输入模型／评分器相关文件
- `test/scheduling/recurring_pace_curve_test.dart`
- `test/scheduling/recurring_cycle_capacity_test.dart`
- `test/application/recurring_weekend_balance_test.dart`

**冻结公式：** 对周期剩余量 `R`、当前窗口之后仍可用的整周合法容量 `C_after`、周期进度比例 `r∈[0,1]`：

```text
requiredNow = max(0, R - C_after)
curve_even(r) = r
curve_early(r) = 1 - (1 - r)^2
curve_deadlineWeighted(r) = r^2
targetNow = clamp(max(requiredNow, ceil(R * curve(r))), 0, R)
```

**步骤：**

- [ ] 先写纯函数边界：0、1、分数、剩余容量不足、允许星期过滤、周中起止。
- [ ] `C_after` 使用完整硬约束容量，不用裸空闲分钟：连续长度、拆分上下限、每日上限、固定日程、保护时间、允许星期都生效。
- [ ] 均匀、提前、截止加权三种 pace 只决定累计目标，不越过 `requiredNow` 安全底线。
- [ ] `deadlineWeighted` 在日内／跨日评分中真正偏后；禁止只改公式名称却仍用“最早候选胜出”的 tie-break。
- [ ] 当周末确实有足够合法容量时，均匀节奏不把整周目标提前塞满工作日；当周末被占用时，`requiredNow` 提前安排必需量。
- [ ] 相同规范输入逐值确定，集合和候选显式排序。

```powershell
flutter test test/scheduling/recurring_pace_curve_test.dart test/scheduling/recurring_cycle_capacity_test.dart test/application/recurring_weekend_balance_test.dart test/application/recurring_even_distribution_test.dart
```

**停止条件：** 若容量预测与真正排程器使用不同硬约束集合，不得上线；两者必须共享同一约束事实或由一致性测试证明等价。

---

## Task 11：正式计划与持久化预排的双窗口维护

**目的：** 当前执行计划和下一完整周预排各自持久、可恢复、可失效，不用内存临时对象冒充产品能力。

**新增／修改：**

- `lib/application/recurring_cycle_maintenance_service.dart`
- `lib/application/pending_plan_preview_service.dart`
- `lib/data/repositories/drift_pending_plan_preview_repository.dart`
- 排程提案／计划仓储接口
- `test/application/recurring_rolling_horizon_test.dart`
- `test/data/pending_plan_preview_repository_test.dart`
- `test/application/pending_preview_restart_test.dart`

**步骤：**

- [ ] 本地日滚动、启动、恢复、计划应用、模板变更、固定事件变更后触发维护；相同 key single-flight。
- [ ] 正式窗口至少覆盖未来 7 个本地日；预排窗口是下一完整本地周一至周一，不能用 `now + 7 days`。
- [ ] 保存 `basePlanVersionId`、规范输入 hash、算法版本、窗口、所有 preview blocks 和解释摘要。
- [ ] 重启后读取同一 preview；不允许“页面重开就消失”。
- [ ] 新事实到达时把旧 preview 标为 stale/superseded，不覆盖审计记录。
- [ ] 预排不创建正式 occurrence/reminder；只创建预排身份或独立 projection。
- [ ] 相同输入、基线和算法版本重复维护时复用稳定 preview/block 身份和时间；不能每天刷新出一套新 UUID。
- [ ] 用户拒绝预排后保存 `rejected` 状态和拒绝依据；输入摘要未变化时不得立即再次展示等价方案。只有输入、算法版本、窗口或用户显式“重新计算”变化时才能产生新候选。

```powershell
flutter test test/application/recurring_rolling_horizon_test.dart test/data/pending_plan_preview_repository_test.dart test/application/pending_preview_restart_test.dart
```

---

## Task 12：预排确认、尾部合并与信任自动调整

**目的：** 确认下一周预排时只合并合法尾部，不替换当前计划前缀；自动应用必须比手动确认更严格。

**修改：**

- `lib/application/pending_plan_preview_service.dart`
- `lib/application/plan_application_service.dart`
- `lib/data/repositories/drift_plan_repository.dart`
- `test/application/pending_preview_apply_test.dart`
- `test/application/pending_preview_staleness_test.dart`
- `test/application/pending_preview_atomicity_test.dart`

**步骤：**

- [ ] 写测试固定当前计划的过去、进行中和用户锁定块，确认预排后这些块逐值不变。
- [ ] 应用前重新检查 preview status、base plan、input hash、算法版本、完整可行性、计划校验器和 revision。
- [ ] 任何检查失败零写入，返回明确 stale／conflict／invalid，不得自动重算后偷偷应用另一份方案。
- [ ] 合并生成新的不可变正式 plan version；旧版本完整保留。
- [ ] 同事务建立新 blocks、occurrence/fragment links、current pointer 和变更日志。
- [ ] 信任关闭：只显示待确认预排，不自动应用。
- [ ] 信任开启：仅完整可行、非部分、非预算耗尽、非 stale 的 preview 自动应用；否则保留待确认状态。
- [ ] 拒绝和“重新计算”是两个不同命令：拒绝保留审计并抑制等价方案；重新计算显式解除本次抑制，但仍执行全部 stale 和可行性校验。
- [ ] 重复确认返回第一次结果，不创建重复版本。

```powershell
flutter test test/application/pending_preview_apply_test.dart test/application/pending_preview_staleness_test.dart test/application/pending_preview_atomicity_test.dart
```

**停止条件：** 只要尾部确认会改变当前确认计划中窗口起点前的任一 block ID、时间、状态或执行链接，就必须停止。

---

## Task 13：历史投影与计划版本切换

**目的：** 历史日历由当时计划版本、fragment 状态和证据投影，不再依赖任务当前终态，也不因新计划替换而消失。

**修改：**

- `lib/features/calendar/week_view/schedule_view_source.dart`
- `lib/features/calendar/week_view/schedule_view_models.dart`
- 计划历史查询仓储
- `test/features/calendar/recurring_history_projection_test.dart`
- `test/features/calendar/recurring_plan_cutover_test.dart`

**步骤：**

- [ ] 日内查询按时间切点选择有效计划版本，不用“当天只有一个版本”的粗粒度假设。
- [ ] 已开始、已结束、已完成、被替换的 fragment 都能在相应历史版本显示。
- [ ] 新计划 cutover 后，切点前使用旧版本，切点后使用新版本；同一真实块不得双重显示。
- [ ] 历史完成图标来自 fragment/evidence，不来自 transport task 的 `isCompleted`。
- [ ] 删除模板后的历史使用 tombstone 显示安全标题／类别，引用不失效。

```powershell
flutter test test/features/calendar/recurring_history_projection_test.dart test/features/calendar/recurring_plan_cutover_test.dart test/features/calendar/schedule_view_source_test.dart
```

---

## Task 14：任务、今日、日历、详情和路由真实接线

**目的：** 用户所有入口使用统一身份；内部载体不可见、不可被普通操作修改，周期块操作清楚表达“本次”。

**修改：**

- `lib/features/tasks/task_list_page.dart`
- `lib/features/tasks/task_list_filter.dart`
- `lib/features/today/today_page.dart`
- 周期详情／历史组件
- 日历周视图／日视图交互
- `lib/app/router.dart`
- `lib/main.dart`
- 对应 widget 和 app-router 测试

**步骤：**

- [ ] 普通任务全部、待安排、已安排、已完成计数排除 transport tasks；搜索和批量选择同样排除。
- [ ] 周期目标留在独立区域，显示本周 credited/target、各 fragment 状态、预排状态和不足原因。
- [ ] Today／日历卡操作文案为“完成本次”“撤销本次完成”；命令传 `fragmentId`，不能传 taskId 后取第一 occurrence。
- [ ] 深链和通知落到 fragment／周期详情；旧 `/tasks/<transportId>` 被 guard 后重定向到周期详情而不是暴露内部任务。
- [ ] “待确认预排”使用文字、图标、边框和语义标签共同区分，不能只换颜色；屏幕阅读器读出状态。
- [ ] 预排支持“确认整份”“重新计算”，不提供伪装为正式块的单块完成。
- [ ] 给查看预排、确认整份、拒绝／重新计算至少各补一条真实 GoRouter 页面→服务→仓储测试；不能只测 fake callback。

```powershell
flutter test test/features/tasks/recurring_transport_task_visibility_test.dart test/features/today/recurring_progress_test.dart test/features/calendar/recurring_goal_badge_test.dart test/app/recurring_task_route_test.dart test/app/recurring_preview_route_test.dart
```

**完成口径：** 本 Task 若只有页面测试而没有 `PlannerApp/createPlannerRouter → service → Drift repository` 的真实链路，必须标记 PARTIAL。

---

## Task 15：提醒、通知与预排静默规则

**目的：** 一个正式片段只产生一组提醒；预排不发正式提醒；删除、替换、完成和撤销能正确协调通知。

**修改：**

- `lib/application/notification_service.dart`
- `lib/application/recurring_notification_service.dart`
- execution reminder coordinator
- 通知 payload/route
- `test/application/recurring_notification_dedup_test.dart`
- `test/app/recurring_notification_route_test.dart`

**步骤：**

- [ ] reminder identity 由正式 fragment 和提醒类型构成，不再只用 transport task。
- [ ] preview blocks 永不注册正式开始提醒；未确认接近执行日只在应用内显示非模态标记。
- [ ] 重排取消失效 fragment 提醒，保留未变化 fragment 的稳定通知 ID。
- [ ] fragment 完成取消其后续提醒，不影响兄弟 fragment。
- [ ] 通知点击进入对应 fragment／周期详情，不能进入隐藏任务页。
- [ ] 并发刷新和重复启动不制造重复通知。

```powershell
flutter test test/application/recurring_notification_dedup_test.dart test/app/recurring_notification_route_test.dart test/application/notification_service_test.dart
```

---

## Task 16：统计、搜索、导出、备份与删除完整性

**目的：** 新身份进入所有数据出口，普通任务统计不被内部载体污染，备份恢复后仍能重建同一事实。

**修改：**

- `lib/data/database/daos/analytics_dao.dart`
- `lib/application/analytics_service.dart`
- `lib/data/repositories/drift_export_data_source.dart`
- `lib/application/export_service.dart`
- `lib/application/backup_service.dart`
- 删除／清除数据服务
- 对应 data/application/widget tests

**步骤：**

- [ ] 普通任务完成率、任务数量、逾期统计排除 transport tasks。
- [ ] 周期统计按 cycle target、有效证据、达标／未达标／跳过计算；不从当前 plan 推断历史。
- [ ] 搜索返回周期模板／详情，不返回内部载体。
- [ ] 导出包含模板、cycle snapshots、fragments、evidence、preview metadata/blocks、版本和时区；不导出无意义内部 UUID 给面向用户的摘要。
- [ ] 备份恢复 v11 全表；恢复后运行幂等回填和维护，不重复 credit、fragment 或 preview。
- [ ] 数据擦除遵守引用顺序；模板普通删除走 tombstone，只有“清除全部数据”可物理清除完整图。
- [ ] 导出和诊断日志不包含不必要的真实标题、备注、数据库路径或敏感作息细节。

```powershell
flutter test test/data/analytics_dao_test.dart test/application/analytics_service_test.dart test/application/export_service_test.dart test/application/backup_service_test.dart test/data/execution/execution_erasure_test.dart
```

---

## Task 17：启动、恢复、本地日滚动与升级编排

**目的：** 让维护和回填在真实生产入口运行一次且可恢复，避免“服务存在、生产零调用”。

**修改：**

- 应用启动／生命周期协调器
- `lib/main.dart`
- `lib/app/router.dart`
- `lib/application/recurring_cycle_maintenance_service.dart`
- `test/app/recurring_startup_maintenance_test.dart`
- `test/app/recurring_resume_rollover_test.dart`
- `test/app/recurring_upgrade_backfill_test.dart`

**步骤：**

- [ ] schema 升级成功后按顺序执行：fragment backfill → credit consistency check → cycle horizon maintenance → preview refresh → reminder reconciliation。
- [ ] 跨周维护固定先结算结束周期并确定 carry-in，再允许新周预排／正式提醒刷新；不得用 provisional carry-in 发送正式提醒。
- [ ] 启动和从后台恢复捕获一次 `nowUtc`，检测本地日期是否变化；变化时维护窗口。
- [ ] 并发启动、恢复和手动刷新共享 single-flight；业务事务阻塞时延后重试，不交错写入。
- [ ] 任一步失败记录 typed stage；已提交阶段保持幂等，下次可继续。
- [ ] 生产 `main.dart` 确实构造真实 Drift repositories 并注入协调器；测试不能只调用 service 自身。

```powershell
flutter test test/app/recurring_startup_maintenance_test.dart test/app/recurring_resume_rollover_test.dart test/app/recurring_upgrade_backfill_test.dart
```

---

## Task 18：端到端、性质、变异、性能与无障碍门禁

**目的：** 用跨层证据证明实现满足用户场景，而不是只证明各函数单独工作。

**新增：**

- `integration_test/recurring_execution_and_lookahead_flow_test.dart`
- `test/application/recurring_credit_conservation_property_test.dart`
- `test/application/recurring_determinism_property_test.dart`
- `test/application/recurring_concurrency_test.dart`
- `test/scheduling/recurring_horizon_performance_test.dart`
- `test/features/calendar/recurring_preview_accessibility_test.dart`

**必须覆盖的真实流程：**

- [ ] 新建 210 分钟周期目标 → 生成三个正式 fragment → 完成中间一个 → 只有中间一个打勾 → 周进度只增加合法分钟。
- [ ] 已经过期块存在 → 手动补记过去时间 → 重排 → 过期块仍在历史，未来块只安排剩余量。
- [ ] 周四查看日历 → 能看到下一完整周的待确认预排 → 重启仍存在 → 确认后当前周前缀逐值不变。
- [ ] trust 开启时完整预排自动应用；构造部分／过期／预算耗尽结果时不得自动应用。
- [ ] 编辑“从下周”后当前周不变、下周变；编辑“仅本周”后模板与下周不变。
- [ ] 周中开始、周中结束、暂停后恢复、跳过、归档、删除墓碑均保持历史。
- [ ] 同一活动跨周拆分、完成后撤销、重复点击、两个并发窗口，所有信用守恒。
- [ ] 通知只属于正式 fragment；preview 静默；通知点击进入真实路由。
- [ ] v10 代表性夹具升级 v11 后全部记录可见、无重复、可继续计划。

**性质测试：**

- 任一 cycle 的 `creditedMinutes` 等于有效证据代数和且不小于 0；
- 任一 activity segment 的分配总和不超过 segment 分钟；
- 任一正式 block 恰好一个 fragment link；
- 任一 preview block 不得拥有正式 reminder；
- 相同规范输入和基线得到逐值相同 proposal；
- 计划版本 cutover 前后不丢、不重叠、不双显；
- 任意失败注入下，当前正式计划要么完整保持，要么完整换成新版本，不存在半提交。

**变异检查：** 至少手工或自动验证以下错误会被测试抓住：

1. 把 complete fragment 改回 complete task；
2. 去掉 evidence 唯一键；
3. 用活动开始时刻归属整段跨周分钟；
4. 把区间相交改回比较 period Monday；
5. 用 `nowUtc + 7 days` 生成下周窗口；
6. 忽略 preview input hash；
7. 确认 preview 时替换整个当前计划；
8. 删除模板时级联删历史 blocks；
9. 让 preview 注册正式通知；
10. 让 energy 过滤合法候选。

**性能门槛：** 使用真实规模夹具（至少 50 普通任务、10 周期模板、当前周与下一周、200 固定／保护块）记录冷启动维护、增量维护、预排生成和确认耗时。门槛以现有算法 20 基线和产品可接受阈值共同确定；未先记录基线不得随意写一个宽松数字。

```powershell
flutter test test/application/recurring_credit_conservation_property_test.dart test/application/recurring_determinism_property_test.dart test/application/recurring_concurrency_test.dart test/scheduling/recurring_horizon_performance_test.dart test/features/calendar/recurring_preview_accessibility_test.dart
flutter test integration_test/recurring_execution_and_lookahead_flow_test.dart -d windows
```

---

## Task 19：全量发布门禁、演练和状态归档

**目的：** 只有全部自动化与明确的手工证据齐全后，才提升 schema／算法／应用版本并宣告完成。

**步骤：**

- [ ] 检查本计划所有 checkbox 和 §21 每个需求 ID 都有测试名、结果和证据链接。
- [ ] 对本次修改文件执行格式化，再执行只检查格式的命令；不要格式化无关用户文件。
- [ ] 运行生成器并确认生成后工作树只含预期文件。
- [ ] 执行静态分析、全部单元／组件测试和 Windows integration test。
- [ ] 用 v11 副本执行真实升级，核对迁移前后数量、分钟、计划历史和链接。
- [ ] 演练应用在预排下载／计算中退出、确认事务前退出、确认后首次启动，验证恢复。
- [ ] 手工验收键盘、屏幕阅读器、125%/150% 缩放、窄窗口、深链和通知点击。
- [ ] 只有全部通过后才提升算法版本和应用版本；失败时保持旧版本标识，禁止先改版本掩盖未完成状态。

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
flutter test integration_test -d windows
git diff --check
git status --short
```

**发布阻断条件：**

- 任一 §21 P0/P1 场景缺少自动化证据；
- 任何真实生产入口仍调用旧 task-wide 完成／撤销；
- 任何 migration／backfill 可重复执行时增加数据；
- 任何预排确认改变当前窗口前缀；
- 任何信用守恒性质失败；
- 任何自动应用绕过 stale／partial／budget 检查；
- 任何历史块会因模板删除或新计划生成而消失；
- app-router 端到端链路只覆盖拒绝，未覆盖确认和完成本次；
- 仍有“服务已有但组合根没有生产调用”的能力。

---

## 20. 禁止的实施顺序与常见伪修复

1. 不得先改 UI 打勾逻辑来遮住 task-wide 状态；先建立 fragment 和证据。
2. 不得在回填完成前把 Today 全部切到 fragment，否则旧数据会无操作目标。
3. 不得在持久化、stale 校验、原子合并和通知静默完成前启用自动应用。
4. 不得直接删旧手动补记路径；先把它改成新 service adapter，并用兼容测试证明，再清理死代码。
5. 不得通过把 recurrence task `isCompleted` 重置为 false 来修复同周联动；这会破坏历史和提醒。
6. 不得通过“历史日历永远显示所有旧 block”规避版本 cutover；会造成双显和冲突。
7. 不得把 energy 从 hard filter 改成 fallback 两段查询却继续给出错误“可用时间不足”；必须统一候选和诊断证据。
8. 不得把下一周目标全部塞进滚动窗口尾部；必须先算整周容量和推进目标。
9. 不得把预排存成 current plan 再加一个 UI 标签；其提醒、统计和执行副作用不同。
10. 不得吞掉所有数据库异常并解释成并发唯一冲突。
11. 不得修改生成文件、隐藏 failing test、扩大 timeout 或降低断言来通过门禁。
12. 不得声称“单测通过即全部完成”；生产装配和真实路由必须有证据。

---

## 21. 需求—测试—证据审计矩阵

实施时在“证据”列填写具体测试名和最近一次通过记录。没有证据的行就是未完成。

| ID | 优先级 | 需求 | 最低自动化证据 | 初始状态 |
| --- | --- | --- | --- | --- |
| RCG-001 | P0 | 完成一个周期片段不影响兄弟片段 | `recurring_fragment_completion_test` | RED/待实施 |
| RCG-002 | P0 | 完成片段不直接完成 transport task 或 cycle | 同上 + state test | RED/待实施 |
| RCG-003 | P0 | 片段已有真实活动时只补差额 | progress ledger test | 待实施 |
| RCG-004 | P0 | 撤销只反向本片段声明证据 | completion undo test | 待实施 |
| RCG-005 | P0 | 真实活动永不因撤销声明而删除 | completion undo test | 待实施 |
| RCG-006 | P0 | 周进度由有效证据代数和推导 | credit property test | 待实施 |
| RCG-007 | P0 | 活动分配分钟守恒 | conservation property test | 待实施 |
| RCG-008 | P0 | 手动补记使用发生时间，不使用保存时间 | progress ledger test | RED/待实施 |
| RCG-009 | P0 | 跨本地周活动按交集拆分 | cross-week allocation test | RED/待实施 |
| RCG-010 | P0 | 历史块不因补记／重排消失 | history projection test | RED/待实施 |
| RCG-011 | P0 | 计划版本切点前后不丢、不重、不双显 | plan cutover test | 待实施 |
| RCG-012 | P0 | 历史状态来自 fragment/evidence，不来自任务终态 | history projection test | RED/待实施 |
| RCG-013 | P0 | 每个正式块恰好一个 fragment | linker/property test | 待实施 |
| RCG-014 | P0 | 同 occurrence 的拆分块拥有独立 fragment | linker test | RED/待实施 |
| RCG-015 | P0 | v11 旧块可幂等回填 fragment | backfill test | 待实施 |
| RCG-016 | P0 | 当前计划前缀在预排确认时逐值不变 | preview apply test | 待实施 |
| RCG-017 | P0 | 预排确认原子提交计划、链接和 current pointer | preview atomicity test | 待实施 |
| RCG-018 | P0 | stale/base/hash/algorithm 不匹配零写入 | staleness test | 待实施 |
| RCG-019 | P0 | 部分／预算耗尽方案不得自动应用 | trust flow test | 待实施 |
| RCG-020 | P0 | v10→v11 非空迁移保留全部历史与分钟 | migration test | 待实施 |
| RCG-021 | P1 | 本周内可见下一完整周预排 | lookahead test | RED/待实施 |
| RCG-022 | P1 | 预排重启后仍存在 | restart test | 待实施 |
| RCG-023 | P1 | 预排不发正式提醒 | notification test | 待实施 |
| RCG-024 | P1 | 信任关闭只显示待确认，不自动应用 | preview route/UI test | 待实施 |
| RCG-025 | P1 | 信任开启仅自动应用完全有效方案 | trust flow test | 待实施 |
| RCG-026 | P1 | 预排状态不只靠颜色表达 | accessibility test | 待实施 |
| RCG-027 | P1 | 滚动维护在启动、恢复、本地日变化执行 | startup/resume tests | 待实施 |
| RCG-028 | P1 | 滚动维护并发 single-flight | concurrency test | 待实施 |
| RCG-029 | P1 | 首次计划先创建周期再读取任务 | input order test | RED/待实施 |
| RCG-030 | P1 | 一次读取全部相交周期，不只 periods.first | intersecting cycles test | RED/待实施 |
| RCG-031 | P1 | 周中开始／结束按实际有效区间排程 | period/capacity tests | 待实施 |
| RCG-032 | P1 | 周目标不因部分周静默按比例缩减 | period/UI test | 待实施 |
| RCG-033 | P1 | 工作区时区冻结周界，历史不随当前时区漂移 | recurring period test | 待实施 |
| RCG-034 | P1 | DST 周推进不用固定 7×24h | recurring period test | 待实施 |
| RCG-035 | P1 | energy/期望时段是软偏好，不删除合法时间 | capacity/scheduler test | RED/待实施 |
| RCG-036 | P1 | 均匀节奏不会无故优先挤满工作日 | weekend balance test | RED/待实施 |
| RCG-037 | P1 | 周末容量不足时会提前安排 requiredNow | capacity test | 待实施 |
| RCG-038 | P1 | deadlineWeighted 真正偏后而非最早 tie | pace/scoring test | 待实施 |
| RCG-039 | P1 | 仅本周只改当前 cycle snapshot | scope matrix test | RED/待实施 |
| RCG-040 | P1 | 从下周只改模板及未来 cycle | scope matrix test | RED/待实施 |
| RCG-041 | P1 | 整个系列不改已结算历史 | scope matrix test | 待实施 |
| RCG-042 | P1 | 暂停、恢复、跳过、归档具有独立状态语义 | lifecycle test | 待实施 |
| RCG-043 | P1 | 删除模板不删除计划历史 | tombstone/history test | RED/待实施 |
| RCG-044 | P1 | 内部载体不进普通列表、数量、搜索、批量 | visibility test | RED/待实施 |
| RCG-045 | P1 | 普通 task API 拒绝修改内部载体 | membership guard test | 待实施 |
| RCG-046 | P1 | Today/日历操作显式使用 fragmentId | app-router E2E | RED/待实施 |
| RCG-047 | P1 | 通知点击不进入隐藏任务详情 | notification route test | 待实施 |
| RCG-048 | P1 | 周期提醒按 fragment 去重 | notification dedup test | 待实施 |
| RCG-049 | P1 | 普通任务统计排除内部载体 | analytics tests | RED/待实施 |
| RCG-050 | P1 | 周期统计来自 cycle/evidence 和历史版本 | analytics tests | 待实施 |
| RCG-051 | P1 | 导出包含周期／fragment／证据／预排 | export round-trip test | RED/待实施 |
| RCG-052 | P1 | 备份恢复不重复分钟或身份 | backup restore test | 待实施 |
| RCG-053 | P1 | 并发创建准确返回 created/alreadyExists | concurrency test | RED/待实施 |
| RCG-054 | P1 | 只把唯一冲突解释成竞争，其他异常上抛 | repository failure test | RED/待实施 |
| RCG-055 | P1 | 重排回调不递归生成额外计划 | maintenance reentrancy test | 待实施 |
| RCG-056 | P1 | 达标由分钟推导，结束不足周期不写 met | cycle settlement test | RED/待实施 |
| RCG-057 | P2 | 达标后停止新增块但保留超额真实投入 | progress/scheduling test | 待实施 |
| RCG-058 | P2 | 用户长期不确认时仅应用内非模态提示 | UI/notification test | 待实施 |
| RCG-059 | P2 | 相同规范输入逐值确定 | determinism property test | 待实施 |
| RCG-060 | P2 | 真实规模维护和预排满足性能基线 | performance test | 待实施 |
| RCG-061 | P1 | carry-in 预估值在上周结算后确定化并使旧预排失效 | settlement/preview test | 待实施 |
| RCG-062 | P1 | skipped 周不结转缺口，普通结转遵守实例快照 | settlement test | 待实施 |
| RCG-063 | P1 | 拒绝预排后，相同输入不得立即重复呈现等价方案 | preview rejection test | 待实施 |
| RCG-064 | P1 | 未变化的预排刷新保持 block/fragment 身份和时间稳定 | preview stability test | 待实施 |
| RCG-065 | P1 | 跨周结算先于新周正式提醒和预排刷新 | startup/notification ordering test | 待实施 |

---

## 22. 最终手工验收脚本

### 场景 A：独立完成

1. 创建每周 180 分钟、允许拆分的周期目标。
2. 生成至少三个正式安排。
3. 在第二个安排点“完成本次”。
4. 期望：只有第二个块打勾；第一、第三块不变；周期进度只增加第二块未被真实活动覆盖的分钟。
5. 撤销第二块完成。
6. 期望：真实专注分钟保留；声明补足分钟被反向；其他块不变。

### 场景 B：手动补记和历史

1. 等第一个安排时间结束但不完成。
2. 给该周期补记一个发生在过去的时间。
3. 触发重新排程。
4. 期望：旧块仍在历史中且状态准确；未来仅重新安排剩余分钟；没有整周全部打勾。

### 场景 C：下一周预排

1. 在周三或周四查看日历。
2. 期望：下一完整周周一至周日的预排均可见，标有“待确认预排”。
3. 关闭并重开应用。
4. 期望：同一 preview 仍在；未产生正式提醒。
5. 确认预排。
6. 期望：当前周过去／进行中／锁定块不变；下一周转为正式计划并生成 fragment/reminder。

### 场景 D：作用域

1. 对当前周期目标分别修改“仅本周”“从下周”“整个系列”。
2. 逐一查看当前周、下一周、历史周。
3. 期望：变化范围与 §2.3 完全一致；历史永不被当前模板覆盖。

### 场景 E：容量与软偏好

1. 设置高精力偏好，但只在普通精力时段留有足够空闲。
2. 生成计划。
3. 期望：系统可安排在普通时段并解释为偏好退让，不得报告“可用时间不足”。
4. 再构造工作日忙、周末空的均匀节奏。
5. 期望：计划不会无理由优先挤满工作日；只有周末硬容量不足时才提前安排安全底线量。

### 场景 F：升级和恢复

1. 用 v10 数据副本升级至 v11。
2. 核对周期、历史块、进度、执行记录和普通任务数量。
3. 重复执行回填／维护。
4. 期望：第二次不新增任何重复 fragment、credit、preview 或提醒。

---

## 23. 交付物与状态报告模板

每个 Task 完成后追加：

```text
Task N：<名称>
状态：DONE / PARTIAL / BLOCKED
生产文件：<列表>
测试文件：<列表>
专项命令：<命令>
专项结果：<通过数、失败数>
相关回归：<命令与结果>
需求 ID：<RCG-...>
生产接线证据：<真实入口/路由/组合根测试>
未验证项：<不得省略>
```

最终状态必须分开报告：

- 设计完成度；
- 生产实现完成度；
- 自动化验收完成度；
- 真实 Windows 端到端完成度；
- 手工可访问性／升级演练完成度。

文档写完不等于生产修复完成。本计划创建时，生产实现完成度为 **0%**；只有 Task 1–19 的证据全部满足，才可将该修复标为完成。

---

## 24. 现状根因审计登记

本表记录写计划前已从代码确认的结构缺口。实施者必须在对应 Task 结束时逐行标记“已关闭／仍存在／判断更正”，不能因主场景测试变绿就删掉登记。

| 审计 ID | 已确认现状／风险 | 主要证据位置 | 关闭 Task |
| --- | --- | --- | --- |
| AUD-001 | 普通任务流直接读取全部任务，内部周期载体进入普通列表、数量和批量操作 | `lib/features/tasks/task_list_page.dart`、`task_list_filter.dart` | 5、14 |
| AUD-002 | 普通任务服务和路由缺少内部载体成员资格 guard | task service、`lib/app/router.dart` | 5、14 |
| AUD-003 | `occurrenceForTask` 按 task 找第一条 occurrence，无法定位用户点中的块 | `lib/application/execution/execution_service.dart` | 6、8、14 |
| AUD-004 | 现有 1.11 occurrence/credit 可复用，不应另造第二套执行系统 | `lib/domain/execution/`、`lib/application/execution/` | 全局边界 |
| AUD-005 | 同一 occurrence 可链接多个 `continuedFromId` 块，occurrence 级完成仍会联动 | `lib/application/execution/execution_plan_linker.dart` | 6、8 |
| AUD-006 | 周期 badge／文案只按当前周解释，下周块可能仍显示“本周” | recurring goal badge/detail widgets | 14 |
| AUD-007 | `ensureCycles` 的 carry/sync 只处理 `periods.first` | `lib/application/recurring_task_service.dart` | 3、4、9 |
| AUD-008 | ScheduleProblem 先读取 open tasks，后创建周期，首次计划会漏输入 | `lib/application/repository_schedule_problem_source.dart` | 9 |
| AUD-009 | 历史投影按天选版本，并用终态任务补漏，会丢块或误打勾 | `lib/features/calendar/week_view/schedule_view_source.dart` | 13 |
| AUD-010 | 旧手动周期补记直接写旧记录，绕过 execution ledger | `lib/application/recurring_task_service.dart` | 7 |
| AUD-011 | 手动补记把 `now` 当发生时间，补历史周时会落入错误周期 | 同上 `recordManualMinutes` 路径 | 7 |
| AUD-012 | 跨周 activity/time entry 按开始时刻整段归属，不按交集拆分 | `lib/data/repositories/drift_recurring_task_repository.dart` | 7 |
| AUD-013 | 周结算可无条件写 met，未由有效分钟推导 | `lib/application/recurring_task_service.dart` | 8 |
| AUD-014 | 撤销是 task-wide，不是 fragment/evidence 级 | execution/recurring undo paths | 8 |
| AUD-015 | `_applyActivity` 的 target kind 生产接线仍偏普通 task，recurringCycle 不完整 | execution service/repository | 7 |
| AUD-016 | 当前排程只取当前周周期，下一周没有稳定提前可见能力 | schedule problem source / cycle reader | 9、11 |
| AUD-017 | 正式窗口用 `nowUtc + Duration(days: 7)`，跨 DST 不等于七个本地日 | `lib/application/repository_schedule_problem_source.dart` | 3、9、11 |
| AUD-018 | `early` 使用固定 48 小时偏移，跨 DST／部分周会漂移 | 同上 | 10 |
| AUD-019 | 周期的 `availableFromUtc` 在部分路径为空，未来周期可能越界排到本周 | 同上周期任务装配 | 9 |
| AUD-020 | 高精力／期望时段可能被当硬过滤，造成明明有空却报不足 | 排程输入装配与候选过滤 | 9、10 |
| AUD-021 | `deadlineWeighted` 缺少真正的后置评分，tie 时仍可能选最早 | 排程评分／候选排序 | 10 |
| AUD-022 | 模板有效日查询只比较周期周一，周中开始的首周可能被跳过、结束后可能越界 | `lib/data/database/daos/recurring_task_dao.dart` | 3 |
| AUD-023 | cycle 使用服务全局时区，模板／历史边界没有冻结时区快照 | recurring period/service/repository | 3 |
| AUD-024 | cycle 排程仍混读当前模板；`thisCycle/fromNextWeek/entireSeries` 会串扰 | recurring task service/repository | 3、4 |
| AUD-025 | 当前 thisCycle 只能可靠保存部分字段，节奏／精力／片段等范围语义不完整 | recurring model/editor/service | 4 |
| AUD-026 | 暂停、归档、删除、恢复没有统一 schedule invalidation，可能残留正式块 | recurring lifecycle paths | 4、5 |
| AUD-027 | 状态转换未形成封闭状态机，可能产生 skipped/met/open 组合矛盾 | recurring task service/model | 4、8 |
| AUD-028 | 错过的内部载体仍保持 open，继续污染排程和普通任务 | cycle settlement/transport projection | 4、8 |
| AUD-029 | create 的 `created` 由确定性 task ID 推测；并发双方可能都报告 created | recurring task service/repository | 3、5 |
| AUD-030 | 捕获所有异常并视为唯一冲突，会掩盖磁盘、外键或编程错误 | recurring repository create path | 3、5 |
| AUD-031 | 生成 cycle 的回调可能在 ScheduleProblem 读取期间递归触发第二轮 replan | cycle service / invalidation callback | 5、9、17 |
| AUD-032 | 预排只存在于计算结果，没有独立持久状态，重启会丢失 | 当前 plan/preview repository 结构 | 11 |
| AUD-033 | 尾部预排若直接应用整份方案，会替换／移动当前确认计划前缀 | plan application repository/service | 12 |
| AUD-034 | 预排缺少 base plan、input hash、algorithm、revision 校验，会应用过期输入 | 当前 preview/application 路径 | 11、12 |
| AUD-035 | 相同输入刷新时没有稳定预排身份，可能每天换 UUID 并制造噪声 | preview generation/linking | 11 |
| AUD-036 | 拒绝预排没有持久记忆，等价提案可能马上再次出现 | preview persistence/UI | 11、12、14 |
| AUD-037 | provisional carry-in 与上周正式结算没有明确切换和失效顺序 | cycle maintenance/notification ordering | 8、17 |
| AUD-038 | 通知用内部 task 路由，可能重复提醒或打开不可用详情 | notification services/payload | 15 |
| AUD-039 | 普通任务统计和当前计划统计会被内部载体／当前版本口径污染 | `lib/data/database/daos/analytics_dao.dart` | 16 |
| AUD-040 | 导出未覆盖 recurring 和完整 execution 表，证据链无法带出 | `lib/data/repositories/drift_export_data_source.dart` | 16 |
| AUD-041 | 普通删除直接删 `schedule_blocks` 会破坏不可变计划历史和 execution link | `lib/data/repositories/drift_recurring_task_repository.dart` | 4、13、16 |
| AUD-042 | 旧数据库启动时没有覆盖所有既有正式块的 occurrence/fragment 回填 | migration/startup wiring | 2、6、17 |
| AUD-043 | 没有滚动 horizon 维护，跨日／恢复后下一周仍可能不出现 | app lifecycle / recurring service | 11、17 |
| AUD-044 | 统计失效、通知对账和排程失效尚未统一进入业务事务 outbox | recurring/execution services | 5、15、16 |
| AUD-045 | 接口或 service 即使存在，只要 `main.dart`/router 没有生产接线仍是零调用 | 组合根与真实 app route | 14、17、18 |

若实施中发现本表某一判断与最新代码不符，必须附具体代码与测试证据更正，不能静默删除该行。
