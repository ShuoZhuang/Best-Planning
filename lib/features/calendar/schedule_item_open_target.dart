// 事项导航目标（路线图 §3.2、§11 Task 2）。
//
// **这个文件解决的是一个崩溃，而不是一个排版问题。** 今日页此前对任何事项都用
//
//     context.go('/tasks/${item.taskId!}')
//
// 而 `ScheduleViewItem.taskId` 只对**任务块**非空（见 `schedule_view_models.dart` 的字段
// 说明）：固定日程与保护时间的 `taskId` 是 `null`，点它们会当场抛
// `Null check operator used on a null value`。周视图那条路径写得比今日页细（它先判
// `taskId != null`，再退回日视图），于是同一个界面里"同一条固定日程"在两个视图里
// 表现不同——这正是把判断**抽成一处纯函数**的理由：两个视图共用同一个答案。
//
// **为什么是纯函数、不放页面里**：`analytics_page.dart` 与 `today_page.dart` 都已经很大，
// 而"这条事项该去哪儿"是一条**规则**，不是渲染细节。放进页面意味着它只能靠 Widget 测试
// 验证，且周视图与今日页会各自再写一遍（§5 的组件边界表就是这么要求的）。
//
// **为什么保护时间去规则页而不是日视图**：保护时间是**规划规则算出来的区间**
// （午休、睡眠），它的"详情"是那条规则本身；日视图只会把它再显示一遍，用户在那里
// 无事可做。§3.2 因此明确要求保护时间显示"查看保护规则"并进入 `/settings/rules`。
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

/// 一条事项**可以去的唯一去处**。
///
/// 三种目标各自对应一个真实路由；没有合法目标时解析器返回 `null`，调用方据此
/// **不显示入口**（§3.2："没有合法目标的事项不显示死入口"）。
sealed class ScheduleItemOpenTarget {
  const ScheduleItemOpenTarget();
}

/// 进入任务详情：`/tasks/<taskId>`。
final class TaskOpenTarget extends ScheduleItemOpenTarget {
  const TaskOpenTarget(this.taskId);

  final String taskId;
}

/// 进入该日期的日视图：`/calendar/day/<dayStartMicros>`。
///
/// [eventId] 是**领域事件 id**（不是视图条目 id），用于在日视图里定位这一条；
/// 取不到事件 id 时解析器**不会**给出这个目标，因为"进对日期但定不了位"与
/// "根本没进去"是两件事，前者配不上一个明确的入口文案。
final class DayOpenTarget extends ScheduleItemOpenTarget {
  const DayOpenTarget({required this.dayStartUtc, required this.eventId});

  /// 目标那一天的本地 `00:00` 对应的 UTC 瞬间（与 `/calendar/day/:dayStartMicros` 同口径）。
  final DateTime dayStartUtc;

  final String eventId;
}

/// 进入规划规则页：`/settings/rules`（保护时间的"详情"）。
final class PlanningRulesOpenTarget extends ScheduleItemOpenTarget {
  const PlanningRulesOpenTarget();
}

/// 解析一条事项该去哪里；没有合法去处时返回 `null`。
///
/// [dayStartUtc] 是调用方认定的"这一天"（今日页就是今天，周视图是那一列），
/// **必须是本地 `00:00` 对应的 UTC 瞬间**——路由用它拼
/// `/calendar/day/<microsecondsSinceEpoch>`，与本文件无关的换算由调用方完成
/// （页面不认识时区，这个分工与项目其它地方一致）。
///
/// 判定顺序与理由：
/// 1. **任务优先看 `taskId`**，而不是条目 id 前缀：`taskId` 是数据源从计划块直接带出来的
///    领域事实，条目 id 只是视图命名空间。
/// 2. **固定日程**用 [fixedEventId] 拆出领域 id；拆不出来就不给目标（宁可没有入口，
///    也不要一个点了跳错页面的入口）。
/// 3. **保护时间**去规划规则。
/// 4. **生活块**返回 `null`：它与任务块同源、当前由任务侧产生，没有独立详情页，
///    把它当任务送进 `/tasks/...` 会打开一个不存在的任务。
ScheduleItemOpenTarget? resolveScheduleItemOpenTarget(
  ScheduleViewItem item,
  DateTime dayStartUtc,
) {
  switch (item.kind) {
    case ScheduleItemKind.task:
      final taskId = item.taskId;
      if (taskId == null || taskId.isEmpty) return null;
      return TaskOpenTarget(taskId);
    case ScheduleItemKind.fixed:
      final eventId = fixedEventId(item);
      if (eventId == null) return null;
      return DayOpenTarget(dayStartUtc: dayStartUtc, eventId: eventId);
    case ScheduleItemKind.protectedTime:
      return const PlanningRulesOpenTarget();
    case ScheduleItemKind.life:
      return null;
  }
}

/// 菜单里那个入口的文案（§3.2 逐类规定）；没有入口时返回 `null`。
///
/// 与 [resolveScheduleItemOpenTarget] 放在一起是刻意的：文案说的就是"点了会发生什么"，
/// 两者不同步时用户看到的字就是假的（比如固定日程写"查看详情"却进了日视图）。
///
/// **为什么不传日期**：文案不依赖日期，只有"能不能开"依赖。因此这里按**同一套可用性判据**
/// 判断（任务看 `taskId`、固定日程看 [fixedEventId]、保护时间恒定可用、生活块没有详情页），
/// 与解析器逐条对应；真正决定去哪儿仍只由解析器负责。
String? scheduleItemOpenLabel(ScheduleViewItem item) => switch (item.kind) {
  ScheduleItemKind.task =>
    (item.taskId == null || item.taskId!.isEmpty) ? null : '查看详情',
  ScheduleItemKind.fixed => fixedEventId(item) == null ? null : '查看当天',
  ScheduleItemKind.protectedTime => '查看保护规则',
  ScheduleItemKind.life => null,
};
