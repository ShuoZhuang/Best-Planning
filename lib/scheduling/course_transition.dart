// 课表课程结束后的过渡缓冲（用户 2026-10-08 需求）。
//
// 用户原话："课表课程后十分钟不安排计划，我上完课要离开教室，肯定不可能直接接续啊。"
//
// 两轮问答定下的范围：
//  · **全局规则**（一处设置，不必逐个日程去填）；
//  · 但**只对课表导入的课生效**，自己建的会议不受影响；
//  · **只加在结束后**，不加在开始前——用户说"课与课之间不需要考虑，因为课表本身就会留出时间"。
//    两侧都加会让相邻两节课之间的空隙叠加成 `2N`，而真实体感只有一次移动。
//
// **为什么是一个独立文件而不是塞进 `repository_schedule_problem_source.dart` 的循环里**：
// 这条规则直接决定"哪些时段可排"，边界不少（缓冲为 0、两节课紧挨、混合输入、其它字段保留）。
// 纯函数可以逐条钉住，而放在 `load()` 的循环里就只能靠集成测试去碰。
//
// **为什么不给 `CalendarEvent` 加一个"结束后需要 N 分钟"的字段**：那种做法要求用户逐个日程去填，
// 忘了填就没有缓冲；而"课表导入的课需要移动时间"是一个**普遍规律**，不是每条日程的属性。
// 区分二者的信息数据里本来就有（`sourceKind`），因此不需要新增字段。
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 把课表导入的课程**结束时间**往后推 [transitionMinutes] 分钟。
///
/// 被占用的时段因此变长，排程器就不会把计划块紧贴在课程结束的那一刻。
///
/// - [transitionMinutes] <= 0 时原样返回（等于关闭这条规则）。
/// - **只改结束时间**，开始时间与其它所有字段逐值保留。
/// - 非课表来源的事件（`CalendarEventSourceKind.manual`）原样保留。
/// - 输入顺序不变。
List<CalendarOccurrence> applyCourseTransition(
  List<CalendarOccurrence> occurrences, {
  required int transitionMinutes,
}) {
  if (transitionMinutes <= 0) return occurrences;
  final shift = Duration(minutes: transitionMinutes);
  return [
    for (final occurrence in occurrences)
      if (occurrence.sourceKind == CalendarEventSourceKind.timetableImport)
        CalendarOccurrence(
          eventId: occurrence.eventId,
          title: occurrence.title,
          range: TimeRange(
            startUtc: occurrence.range.startUtc,
            endUtc: occurrence.range.endUtc.add(shift),
          ),
          locked: occurrence.locked,
          areaId: occurrence.areaId,
          projectId: occurrence.projectId,
          location: occurrence.location,
          notes: occurrence.notes,
          sourceKind: occurrence.sourceKind,
          importBatchId: occurrence.importBatchId,
          logicalCourseId: occurrence.logicalCourseId,
        )
      else
        occurrence,
  ];
}
