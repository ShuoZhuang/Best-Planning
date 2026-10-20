# 周期单次执行与跨周预排验收台账

> 版本：`1.11.0+52`；schema：11；生成日期：2026-10-19。
> 结论：核心语义已有自动化证据；Task 1 的“先红灯后修复”特征记录、真实 v11 副本与手工发布验收仍未完成。

## 需求 → 测试证据

| 需求 | 证据 | 状态 |
|---|---|---|
| 一次完成只作用于所选片段 | `test/application/recurring_progress_test.dart`、`integration_test/recurring_execution_and_lookahead_flow_test.dart` | PASS（Windows） |
| 手动补记进入同一执行管道 | `test/application/recurring_progress_ledger_test.dart` | PASS |
| 同一操作重复提交只入账一次 | `test/application/recurring_progress_test.dart` | PASS |
| 跨周活动按周界拆分 | `test/application/recurring_progress_ledger_test.dart` | PASS |
| 周实例快照冻结、周中起止 | `test/application/recurring_task_service_test.dart`、`test/application/recurring_dst_snapshot_test.dart` | PASS |
| 暂停撤回未开始片段且历史保留 | `test/application/recurring_template_scope_service_test.dart`、`test/features/calendar/week_view_test.dart` | PASS |
| 下一完整周预排 | `test/application/recurring_rolling_horizon_test.dart`、`integration_test/recurring_execution_and_lookahead_flow_test.dart` | PASS（Windows 3 条） |
| 信任自动调整只接受完整预排 | `test/application/recurring_rolling_horizon_test.dart` | PASS |
| 尾部合并 | `test/application/recurring_rolling_horizon_test.dart` | PASS |
| 回填歧义可复核 | `test/application/execution/execution_plan_linker_test.dart`、`test/features/tasks/recurring_backfill_review_test.dart` | PASS |
| 内部载体不进入普通任务流 | `test/application/internal_transport_task_guard_test.dart` | PASS |
| deadlineWeighted 同分偏后 | `test/application/recurring_determinism_property_test.dart` | PASS |
| 启动 typed stage 编排 | `test/application/recurring_startup_coordinator_test.dart` | PASS |

## 未完成 / 阻断

- Task 1：目标是“先写失败测试证明旧实现缺陷”，当前代码已修复，无法再取得当时的红灯记录；只保留修复后的回归证据。
- Task 2：已按 v10→v11 口径通过空库/非空迁移；不存在 v12，不要求真实 v11 用户库。
- Task 18：没有变异测试工具配置；完整无障碍门禁需要手工键盘/屏幕阅读器/缩放验收。
- Task 19：Windows integration 被 `Building with plugins requires symlink support`（未启用开发者模式）阻断；签名安装与真实副本未执行。

## 发布判定

自动化测试通过不等于可发布。上述阻断未解除前，发布门禁保持**不通过**。
