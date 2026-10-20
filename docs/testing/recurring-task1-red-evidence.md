# Task 1 旧实现红灯证据

> 基线提交：`dfc347aff32c52869d954839178754d69df2a9c5`（1.10.2）
> 隔离工作树：`G:\best-planing\.worktrees\old-dfc347af`（detached，只读用途）
> 当前实现工作树未被修改。

## 已复现

### 内部周期载体进入普通任务流

测试文件：`test/old_characterization_test.dart`（临时工作树内）

命令：

```powershell
flutter test --no-pub test/old_characterization_test.dart
```

断言：

```dart
expect(
  all.any((task) => task.id == cycle.taskId),
  false,
  reason: '旧实现把 recurring: 载体当成普通任务暴露',
);
```

实际结果：

```text
Expected: <false>
  Actual: <true>
旧实现把 recurring: 载体当成普通任务暴露
Failing tests:
  test/old_characterization_test.dart: 旧实现：内部周期载体出现在普通任务流
exit code: 1
```

结论：旧实现确实把周期载体当普通任务暴露，红灯成立。

## 已复现（2/5）\n\n### 一个完成让三个块全部打勾\n\n测试：`test/features/calendar/schedule_view_source_test.dart`（旧工作树内新增）\n\n命令：`flutter test --no-pub test/features/calendar/schedule_view_source_test.dart --plain-name 旧实现红灯`\n\n结果：\n\n```text\nExpected: <1>\n  Actual: <3>\n旧实现按 task 状态把所有块都标完成；期望只完成一个片段\nexit code: 1\n```\n\n结论：旧实现按 task 状态给同任务三个块全部打勾，红灯成立。\n\n## 已复现（3/5）\n\n### 旧接口没有下一完整周预排服务\n\n临时测试：`import package:personal_planner/application/recurring_cycle_maintenance_service.dart;`\n\n命令：`dart analyze test/old_lookahead_compile_test.dart`\n\n结果：\n\n```text\nerror - Target of URI doesn't exist: package:personal_planner/application/recurring_cycle_maintenance_service.dart\nexit code: 3\n```\n\n结论：旧接口无法编译表达“下一完整周维护/预排”，属于用户允许的“接口无法表达”记录，不是运行时红灯。\n\n## 无法复现（旧实现已通过）\n\n### 手动补记后历史消失\n\n在 `dfc347af` 运行旧 `schedule_view_source_test.dart` 的“今天做完的事”3 条：\n\n```text\n今天做完的事：当前版不再排它时，仍然显示在做它的那个时间\n今天做完的事：当前版仍然排着它时，不会因此多出一条\n今天做完的事：只补整段已经过去\nAll tests passed! (3), exit 0\n```\n\n结论：该基线已包含历史保留修复，无法在 `dfc347af` 复现“历史消失”红灯。\n\n### 精力偏好过滤空闲\n\n旧引擎把精力匹配作为候选评分（`candidate_scorer.dart`），不是硬过滤；golden week 测试通过（exit 0）。\n\n结论：旧实现没有“精力偏好把其他合法空闲视为不可用”的硬过滤，无法复现该红灯。\n\n## 旧接口代码证据（未写成运行时红灯）

- 旧周视图按 `TaskStatus.completed` 收集 `completedIds`，再对每个块写
  `isCompleted: completedIds.contains(block.taskId)`；一个任务完成会让同一周期的所有块显示完成。
  证据：`lib/features/calendar/week_view/schedule_view_source.dart`（dfc347af）。
- 旧代码没有 `RecurringProgressService`、fragment 仓储、`PendingPlanPreviews` 或
  `RecurringCycleMaintenanceService` 类型；因此“只完成中间片段”“下一完整周待确认预排”
  无法用旧接口编译表达，不能伪造运行时红灯。
- 旧 `TaskService.watchAllTasks()` 没有周期载体过滤，已由上面的运行时红灯覆盖。

## 尚未复现

- 一个完成让三个块全部打勾的 **UI 级**红灯；
- 手动补记后历史块消失的运行时红灯；
- 下一完整周预排缺失的运行时红灯（旧接口无对应类型）；
- 精力偏好过滤空闲的运行时红灯。

这些需要继续在隔离工作树中补旧接口可表达的最小夹具；未完成前 Task 1 保持 PARTIAL。
