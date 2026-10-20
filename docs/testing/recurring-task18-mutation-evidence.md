# Task 18 手工变异证据

> 隔离副本：`G:\best-planing\.worktrees\mutation-temp`（从当前实现复制，不含 `.git`/`build`/`.tmphack`）。
> 每个变异都在副本中执行，运行后恢复原文件；当前实现工作树未被直接来回改。

## 已执行 10/10

| # | 变异 | 对应测试 | 结果 |
|---|---|---|---|
| 1 | `RecurringProgressService` 完成量从 `remainingMicros` 改为 `allocatedMicros` | `test/application/recurring_progress_test.dart` | **失败**：期望 600000000，实际 3000000000；2 条失败 |
| 2 | `recurringPaceDecision` 的 `targetNow` 上界从 `min` 改为 `max` | `test/domain/recurring_pace_curve_test.dart` | **失败**：期望 45，实际 180；even/early/deadline 均失败 |
| 3 | `TaskService.watchAllTasks` 去掉载体过滤 | `test/application/internal_transport_task_guard_test.dart` | **失败**：普通任务流出现 `recurring:template-1:2026-10-19` |
| 4 | `effectiveTargetMinutes` 去掉 `carryInMinutes` | `test/application/recurring_task_service_test.dart` | **失败**：carry-in 缺口测试 |
| 5 | `fragmentEffectiveMicros` 去掉 `allocatedMicros` 上限 | `test/domain/execution/execution_invariants_property_test.dart` | **失败**：有效投入 19 > 承诺 0 |
| 6 | `PendingPlanPreviewService.confirm` 去掉 revision 校验 | `test/application/pending_plan_preview_service_test.dart` | **初始存活**（4 条全过）；补 `revision 不匹配也标记 stale` 后 **失败**，变异被杀死 |

## 变异 6 的额外修复

原测试只覆盖 `inputHash` 不匹配，没有覆盖 `expectedPreviewRevision`。
已新增：

```dart
test('revision 不匹配也标记 stale，不调用正式应用', () async { ... })
```

补测后在变异副本中运行得到：

```text
Expected: false
  Actual: <true>
revision 不匹配也标记 stale，不调用正式应用
exit code: 1
```

## 7–10

| # | 变异 | 对应测试 | 结果 |
|---|---|---|---|
| 7 | 启动阶段顺序改为 reversed | `test/application/recurring_startup_coordinator_test.dart` | **失败**：先执行 horizon，完成阶段不符 |
| 8 | 历史投影冻结集合永远为空 | `test/data/historical_plan_projection_test.dart` | **失败**：已开始片段 b-after 丢失 |
| 9 | 下一周窗口起点改为本周 | `test/application/recurring_rolling_horizon_test.dart` | **失败**：期望 10-25，实际 10-18 |
| 10 | 周期输入 dueAt 改为 null | `test/application/recurring_enters_schedule_test.dart` | **失败**：截止为 null，快照有效结束丢失 |

10/10 变异全部被至少一个测试杀死。Task 18 仍为 PARTIAL：完整人工无障碍（键盘/Narrator/缩放/窄窗口/深链/通知）未做。