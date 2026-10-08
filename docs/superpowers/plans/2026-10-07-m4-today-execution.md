# M4 实施计划：今日执行与调整信任

> 规格：`docs/superpowers/specs/2026-10-07-m4-today-execution.md`
> 路线图 §8。**不重新实现专注与重排引擎**；**不抬版本、不单独打包**；**不带入 M5+**（§14）。
> 方法：**先红后绿**。

## 阶段

| 阶段 | 内容 | 主要文件 |
| --- | --- | --- |
| P1 | `ScheduleViewItem` 增加可选 `taskId`，由视图源填入 | `schedule_view_models.dart`、`schedule_view_source.dart` |
| P2 | 今日页动作：当前块「开始专注」「完成」；其它块菜单（详情/延后/请求调整/锁定） | `today_page.dart` |
| P3 | 路由装配（页面不认识路由，导航由 router 注入） | `router.dart` |
| P4 | 重排提示可关闭（会话内），关闭不取消方案 | `today_page.dart` |
| P5 | 预览分组与时间字段（§4.5，最大一块，按余量决定是否本轮交付） | `plan_preview_page.dart` |
| P6 | 完整验证 + 文档 | 测试、`m4-acceptance.md`、路线图 §19、用户指南 |

---

## P1 计划块 → 任务可达性

**先写的失败测试**（`test/features/calendar/week_view_test.dart` 或视图源测试）：
1. 任务块 `ScheduleViewItem.taskId` 等于其 `PlannedBlock.taskId`；
2. 固定日程与保护时间的 `taskId` 为 `null`（它们没有任务）。

**实现**：`ScheduleViewItem` 加 `final String? taskId;`（可选构造参数），
`schedule_view_source.dart` 的 `addBlock` 里填 `taskId: block.taskId`。

**风险**：`today_page.dart` 第 82 行也构造了 `ScheduleViewItem`（视图预览用），
加可选参数不会破坏它。

## P2 今日页动作

**API 设计**（与 `TaskDetailPage` 同一套做法：**页面不认识路由**）：

```dart
TodayPage({
  required source, required day, toLocal,
  DateTime? nowUtc,                              // 判定"当前"块
  ValueChanged<ScheduleViewItem>? onStartFocus,  // 开始专注
  ValueChanged<ScheduleViewItem>? onComplete,    // 完成
  ValueChanged<ScheduleViewItem>? onOpenDetail,  // 查看详情
  ValueChanged<ScheduleViewItem>? onDefer,       // 延后
  ValueChanged<ScheduleViewItem>? onRequestAdjust, // 请求调整
  ValueChanged<ScheduleViewItem>? onToggleLock,  // 锁定
})
```

**先写的失败测试**（`test/features/today/today_page_test.dart`）：
1. 「当前」块（`range.start <= now < range.end`）上有 `today-start-focus-<id>` 与 `today-complete-<id>`
   两个按钮，**都在卡片上、不在菜单里**；
2. 点「开始专注」→ `onStartFocus` 被调用且**只调用一次**（这就是"不超过两次点击"的自动化部分：
   进入页面 → 点一次按钮 = 1 次点击）；
3. 点「完成」→ `onComplete` 被调用一次；
4. 非当前块**没有**这两个按钮，但有 `today-more-<id>` 菜单；菜单里含详情/延后/请求调整/锁定；
5. 保护时间与固定日程**不显示**「完成」（它们不是待办）与「锁定」（不是计划块）；
6. 回调为 `null` 时按钮**不渲染**（与 `TaskDetailPage` 的空端口约定一致：没装配就不显示入口）。

**实现要点**：
- 「当前」判定用一个私有方法，`nowUtc` 为空时取 `DateTime.now().toUtc()`；
- 已完成（`item.isCompleted`）的当前块不再给「完成」，避免重复完成；
- 动作放在卡片右侧，**菜单用 `PopupMenuButton`**（§8"动作密度用菜单控制"）。

## P3 路由装配

`router.dart` 的 `/today` 把回调接上：
- `onStartFocus` → `context.go('/focus/${item.taskId}')`（仅当 `taskId != null`）；
- `onComplete` → `taskService.changeStatus(taskId, TaskStatus.completed)`；
- `onOpenDetail` → `context.go('/tasks/${item.taskId}')`；
- `onDefer` → 复用既有的"延后"端口（`taskService.deferTask`）；
- `onRequestAdjust` → 落地为既有 `RequestedMove`（`moveController.proposeMove`）；
- 端口为空时对应回调传 `null`，页面不显示该入口。

**加一条路由级测试**（`test/app/today_route_test.dart`）：与 `task_editor_route_test.dart` 同样的理由——
裸挂页面证明不了"放进真实外壳后动作还在、点击真的通到服务"。

## P4 重排提示可关闭

**先写的失败测试**：
1. 有关闭按钮 `today-replan-dismiss`；
2. 关闭后提示消失，但**待确认方案仍在**（断言方案对象/state 未变）；
3. 关闭后同一会话内**不再出现**；
4. 之后**新的**方案会再次提醒（喂一个新 proposalId → 提示重新出现）。

**实现**：`State` 里存 `String? _dismissedProposalId`，只在它与当前 proposalId 相等时隐藏。
**用 proposalId 而不是 bool**：bool 会让"新方案也不提醒"，而那正是 §8 要避免的。

## P5 预览分组与时间字段

**先写的失败测试**（`test/features/planning/plan_preview_test.dart`）：
1. `PreviewChangeKind` 含 `unplanned` 与 `protectedTimeChanged`，五类各有中文标签
   （新增/移动/拆分/未安排/保护时间变化）；
2. `PreviewChange` 带 `fromLabel` / `toLabel`，界面同时显示**原时间与目标时间**与原因；
3. 取消预览后计划、锁定块、任务原始信息逐项不变。

**这一块会动 `plan_preview_page.dart`（265 行）与它的既有测试。**
若余量不足，**先交付 P1～P4 并如实标注 P5 未完成**，不留半成品。

## P6 完整验证

1. `flutter analyze --no-pub` 0 问题；`dart format` 0 改动；全量 `flutter test` 全绿；
2. 六条集成测试逐条通过，其中 `emergency_replan_flow_test.dart` 与"预览确认"两条路径都要跑；
3. Windows Release 构建成功（**内部验证构建，不发布**）；
4. 写 `docs/testing/m4-acceptance.md`（含未完成项如实标注）；
5. M4 章节写入 `docs/release/1.6.2-build37-user-guide.md`；更新路线图 §19。

## 不做

- 不改专注计时逻辑、不改排程引擎、不改数据库、不改版本号。
- **不发明"跳过"的持久化状态**（规格 §4.2 已说明：领域模型里没有它，需要另立规格）。
- 不做 M5 周时间轴、M6 课表、M7 统计、M8 引导。
