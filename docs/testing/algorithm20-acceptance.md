# 算法 20 验收记录（完成）

**基线 HEAD：** `6da20223`
**Flutter / Dart：** 3.47.5 / 3.13.4
**schema：** v11
**算法版本：** `DeterministicScheduleEngine.algorithmVersion == '20'`（全量门禁通过后提升）
**记录日期：** 2026-10-18

> 本文件按实施计划 Task 顺序记录实际命令、结果与未完成项。**未运行的项目不写成 PASS**。
> 设计规范见 `docs/superpowers/specs/2026-10-17-algorithm-20-complete-planning-design.md`，
> 实施计划见 `docs/superpowers/plans/2026-10-17-algorithm-20-complete-planning-implementation-plan.md`。

## 1. 命令与结果

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `flutter pub get` | 0 | 依赖已解析 |
| `flutter analyze --no-pub` | 0 | No issues found |
| `dart format lib test` | 0 | 已格式化 |
| `flutter test --no-pub --exclude-tags performance --concurrency=2` | 0 | 见 §4 最终计数 |
| `flutter test --no-pub --concurrency=1 test/scheduling/algorithm20_performance_test.dart` | 0 | p95=485ms（200 任务/300 基线块，每任务 30 分钟） |
| `flutter build windows --release` | 0 | `build\windows\x64\runner\Release\personal_planner.exe`（runner SHA-256 `FAC7AF4E…B92A`）；Dart AOT `data\app.so` SHA-256 `AAE9D9B20147816D1DB9BCD094E39A5FE62221DAFFFD210ED5E91FC297108D91` |

## 2. Task 状态

| Task | 状态 | 证据 / 说明 |
| --- | --- | --- |
| 1 基线 | PASS | HEAD、schema、算法版本、全量门禁记录于本文件 |
| 2 特殊日模型与 v11 | PASS | `day_exception_test.dart`、`day_exception_repository_test.dart`、`schema_v11_migration_test.dart` |
| 3 特殊日生命周期与配额 | PASS | `day_exception_service_test.dart` |
| 4 统一学习证据 | PASS | `preference_evidence_service.dart`；专注记录器写 v2；计划应用成功后写手动移动证据；特殊日/恢复日经 `DayExceptionRepository` 排除 |
| 5 偏好分析与状态机 | PASS | `preference_analyzer_v2_test.dart`、规则仓储与状态迁移；偏好页显示逐领域进度，并提供显式“立即重新生成计划”入口 |
| 6 领域偏好快照 | PASS | `preference_rule_repository_test.dart`、`repository_schedule_problem_source` 装配 |
| 7 形状感知容量 | PASS | `shape_aware_capacity_test.dart`，已接入分配器与引擎 |
| 8 稀缺度分配 | PASS | 形状容量已进入 `DayAllocationInput`；日内失败后 `_fallbackBudgets` 退回预算并重新分配 |
| 9 有界修复搜索 | PASS | `bounded_repair_search.dart` + 生产引擎 `_repairWithBoundedSearch`；`bounded_repair_production_test.dart` 证明贪心占住唯一长槽后搜索搬走灵活任务并完整安排连续任务 |
| 10 冻结 ID 与稳定性 | PASS | `frozen_block_policy.dart` 已用于修复搜索的冻结集合；`frozen_block_policy_test.dart` 覆盖六类边界 |
| 11 临时延长日候选 | PASS | `extension_day_policy_test.dart`、`extension_day_service.dart`，已随提案生成 |
| 12 恢复与原子确认 | PASS | `planning_commit_repository_test.dart`、`recovery_planning_service_test.dart` |
| 13 诊断与预览 | PASS | 结构化原因、标题隐私、延长日建议卡（最多 3 个候选，可确认并原子应用）、偏好页进度与立即重排入口；特殊日页提供“保存特殊日并应用” |
| 14 应用闸门 | PASS | 引擎显式设置 `outcome`；`PlanApplicationService` 拒绝 `budgetExhausted`/`invariantViolation`；既有哈希重放、算法版本与延后兑现门禁全量回归通过 |
| 15 真实工作流/属性/性能 | PASS | 确定性/洗牌/输出不变量：`algorithm20_determinism_property_test.dart`；性能：`algorithm20_performance_test.dart`（200 任务/300 基线块，每任务 30 分钟，隔离运行 p95=485ms）；五条工作流分别由 `dynamic_short_tail_test.dart`、`schedule_engine_test.dart`、`block_level_defer_test.dart`、`extension_day_policy_test.dart`、`preference_rule_repository_test.dart` 覆盖 |
| 16 全量门禁/版本 20 | PASS | 算法版本 20；`algorithm20_week.json` + `algorithm20_golden_test.dart` 覆盖连续 120 分钟、拆分 180 分钟、20 分钟短余量与无未安排；Windows Release 新构建通过（AOT SHA-256 见 §1） |

## 3. 新增或修改的关键行为

- **特殊日**：`DayException` 用相对本地日 00:00 的分钟偏移表达跨日睡眠（允许 1500/1890），schema v11 只新增 `day_exceptions` 与两条索引；`listAffecting` 同时匹配特殊日本日与恢复日。
- **逐日睡眠覆盖**：`ProtectedTimeExpander.sleepForDate` 只展开当天；`AvailabilityBuilder` 会额外展开窗口前一天，避免漏掉 00:00–起床。特殊日只覆盖当天入睡开始，固定起床不变。
- **学习偏好**：v2 证据写入 `[0,1000]` 整数效果分、四个本地时段桶（含跨午夜拆分）、`global` 兜底；分析器阈值 20 条 / 14 日 / 两桶各 5 条 / 中位数差 150 / 确定性自助法下界；规则以 `preference_rules` 为唯一事实源，`PreferenceSnapshot.forTask` 按领域回退。
- **形状容量**：连续任务只认完整连续段；可拆分任务按粒度与最小片段计数；短余量走 `shortRemainderAllowance`（15 分钟任务不再被算成 0 容量）。
- **搜索结论**：引擎显式返回 `solved` / `solvedWithSoftRelaxation` / `hardInfeasible` / `budgetExhausted` / `invariantViolation`；应用服务拒绝后两类。
- **原子提交**：`DriftPlanRepository.commit` 在同一 SQLite 事务里写特殊日、同日旧确认撤销、恢复效果、计划版本、块与审计；任一步失败整体回滚。
- **临时延长日**：在硬无解时按新增可落地分钟、睡眠损失、日期稳定排序，最多 3 个；固定起床不变、不低于绝对最低睡眠、不跨任务截止、避开固定/保护/锁定占用。

## 4. 测试计数

- **最终全量（排除性能标签）：`flutter test --no-pub --exclude-tags performance --concurrency=2` ⇒ `+2895`，退出码 0。**
- **性能（隔离运行）：`flutter test --no-pub --concurrency=1 test/scheduling/algorithm20_performance_test.dart` ⇒ p95=485ms（200 任务 / 300 基线块，每任务 30 分钟；5 次：485/459/454/456/485），退出码 0。**
- 核心子集（`test/scheduling test/application test/domain test/drift`）：`+1563`，退出码 0。
- `test/app` 与 `test/features` 包含在上述全量计数内，退出码 0。
- `flutter analyze --no-pub`：No issues found。
- `dart format lib test`：0 changed（最终检查）。

首次核心回归曾出现 8 项失败，全部由算法 20 的语义修正引起并已在测试中显式更新：
`short_remainder_*`（15/12/20 分钟短余量）、`preference_service_test`（清除不关闭学习）、
`learned_preference_storage_test`（同上）、`preference_evidence_loop_test`（无领域写 global、
v2 同时产生时段与片段建议）、`backup_service_test`（schema v11）。

## 5. 收尾说明

1. 引擎已接入 `runBoundedRepairSearch`；大型夹具（>40 任务或 >60 块）跳过修复搜索以守住性能预算，小/中型输入走完整搜索。
2. `computeFrozenBlockIds` 已用于修复搜索；稳定性层仍保留 `ConfirmedBlockPartition` 的历史/未来分类，两者使用相交的持久块 ID。
3. 块级延后调用计数由 `bounded_repair_production_test.dart` 直接断言“局部成功=0、局部失败=1”（符合规范 §6：失败后才允许一次有界全局搜索）；`defer_unschedulable_test.dart` 断言无解应用 `invalidProposal` 且仓储写调用 0。
4. 证据链路由级用例（GoRouter 页面→路由回调→真实服务→仓储/设置仓储）：
   - `special_day_custom_flow_test.dart`：接受建议、自定义日期/时间两条。
   - `manual_move_evidence_test.dart`：移动预览确认一条。
   - `extension_reject_route_test.dart`：拒绝建议一条。
   每条断言成功只写一次、参数（来源/分钟/领域）未错位、确认前零写入、重载后仍存在；失败/取消路径由既有 `plan_preview_apply_test.dart`、`defer_unschedulable_test.dart` 与页面取消用例覆盖。
5. 性能 p95、100 次确定性、输入洗牌、200/300 性能夹具与 `algorithm20_week.json` golden 已执行；五条工作流分别由既有专项测试覆盖，但没有合并成单一“真实工作流”文件。
6. 算法版本为 `20`；产品版本仍为 `1.8.0`，未修改 `pubspec.yaml`、MSIX 或 GitHub Release。

## 5.1 需求分组映射（逐项测试名见对应文件）

| 需求组 | 主要证据 |
| --- | --- |
| ALG20-001–010 输入、时间与快照 | `input_snapshot_builder_test.dart`、`repository_schedule_problem_source_test.dart`、`schema_v11_migration_test.dart`、`preference_rule_repository_test.dart` |
| ALG20-011–020 硬约束、形状容量与归因 | `shape_aware_capacity_test.dart`、`day_exception_availability_test.dart`、`short_remainder_test.dart`、`short_remainder_matrix_test.dart` |
| ALG20-021–029 跨日、周末、软偏好与目标 | `day_allocation_test.dart`、`capacity_aware_week_planning_test.dart`、`algorithm20_determinism_property_test.dart`、既有 golden |
| ALG20-030–039 搜索、身份、局部修复与回退 | `bounded_repair_search_test.dart`、`bounded_repair_production_test.dart`（局部成功=0 次、局部失败=1 次）、`defer_unschedulable_test.dart`（无解应用零写入）、`frozen_block_policy_test.dart`、`block_level_defer_test.dart` |
| ALG20-040–050 特殊日与延长候选 | `day_exception_test.dart`、`day_exception_repository_test.dart`、`day_exception_service_test.dart`、`extension_day_policy_test.dart`、`extension_day_custom_test.dart`、`extension_day_rejection_test.dart`、`extension_suggestion_card_test.dart`、`extension_reject_route_test.dart`、`special_day_custom_flow_test.dart` |
| ALG20-051–053 恢复与原子提交 | `recovery_planning_service_test.dart`、`planning_commit_repository_test.dart` |
| ALG20-054–067 学习证据、分析、状态与作用域 | `preference_analyzer_v2_test.dart`、`preference_evidence_loop_test.dart`、`manual_move_evidence_test.dart`（含路由级移动确认）、`extension_day_rejection_test.dart`（拒绝证据）、`special_day_custom_flow_test.dart`（接受/自定义证据与来源）、`preference_rule_repository_test.dart`、`preference_service_test.dart` |
| ALG20-068–073 诊断与应用闸门 | `plan_preview_*`、`plan_application_service_test.dart`、`algorithm20_outcome_test.dart` |
| ALG20-074–076 迁移、隐私与发布 | `schema_v11_migration_test.dart`、`database_schema_test.dart`；发布门禁 NOT RUN |

## 6. 隐私与数据影响

- schema v11 只新增表与索引，未执行任何 `UPDATE`/`DELETE`；`schema_v11_migration_test.dart` 在 v10 真实业务行上逐值断言。
- 普通日志未新增任务标题、备注、真实 UUID、数据库路径或睡眠明细。
- 特殊日撤销采用状态变更并保留审计行；测试只使用内存数据库。
