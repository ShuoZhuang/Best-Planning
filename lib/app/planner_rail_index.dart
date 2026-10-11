/// 侧栏归属的**纯映射**（1.8.0，设计规范 §7.2）。
///
/// **为什么要单独一个文件**：这个映射的返回值必须是**可空**的——`/new` 不高亮任何业务栏
/// （§7.1）。留在 `_PlannerShell._selectedIndex` 里的话，它只能返回 `int`，于是"不高亮"
/// 无从表达，只能回落到 `0`（今日）；而回落正是缺陷本身（§2.9）：
/// `/tasks/new`、`/tasks/new/task` 与周期目标子路由此前全部落进"今日"。
///
/// 抽成纯函数之后，"哪条路径高亮哪一栏"可以脱离整个 Shell 被逐条断言，
/// 包括 `/new` 与未知路径这两条最容易写错的。
library;

/// 侧栏里几个业务栏的下标，与 `_PlannerShell` 的 `NavigationRail.destinations` 顺序一一对应。
///
/// 用具名常量而不是裸数字：下面那张表里有 6 个分支，裸数字一旦和 destinations 的顺序
/// 漂开，症状是"点日历高亮今日"这种只能靠肉眼发现的问题。
abstract final class PlannerRailIndex {
  static const today = 0;
  static const tasks = 1;
  static const workspace = 2;
  static const calendar = 3;
  static const analytics = 4;
  static const settings = 5;
}

/// 这条位置应当高亮哪一栏；`null` 表示**不高亮任何业务栏**。
///
/// 规则（规范 §7.2，逐条有测试）：
/// - `startsWith('/tasks')` → 任务；
/// - `startsWith('/calendar')` → 日历；
/// - `startsWith('/settings')` → 设置；
/// - `/new` → `null`；
/// - 其余**已知**顶层页按它们自己的下标；未知路径同样是 `null`。
///
/// 用前缀而不是**逐条列举**是刻意的：`/tasks/new/task`、`/tasks/recurring/:id/edit`、
/// `/calendar/protected/new`、`/calendar/courses/:id` 这些子路由以后还会增加，逐条列举
/// 就是"新增一条路由、忘了加一条高亮"的温床——而那正是这次要修的那类缺陷。
///
/// 未知路径返回 `null` 而不是回落到"今日"：回落会让用户在一个不存在的页面里看到
/// "今日"被选中，那是一个谎。宁可不高亮。
int? plannerRailIndexForLocation(String location) {
  if (location == '/new') return null;
  if (location == '/today') return PlannerRailIndex.today;
  if (location == '/workspace') return PlannerRailIndex.workspace;
  if (location == '/analytics') return PlannerRailIndex.analytics;
  if (location.startsWith('/tasks')) return PlannerRailIndex.tasks;
  if (location.startsWith('/calendar')) return PlannerRailIndex.calendar;
  if (location.startsWith('/settings')) return PlannerRailIndex.settings;
  return null;
}
