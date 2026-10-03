/// 删除固定日程（FR-CAL-01 的"删除"）。
///
/// **为什么是单独的端口，而不是往 `CalendarRepository` 加一个方法**：后者有 **5 个测试替身**
/// 实现它（`test/app/calendar_event_route_test.dart`、`test/app/special_day_route_test.dart`、
/// `test/application/notification_kinds_test.dart`、
/// `test/application/repository_schedule_problem_source_test.dart`、
/// `test/features/calendar/event_editor_test.dart`），加一个成员就会**一次牵动 5 个文件**。
/// 让愿意支持删除的实现多实现一个接口，代价只落在真正需要它的那一处。
///
/// 与 `CalendarRepository` 分开还有一层语义上的好处：**读日程**的调用方（周视图、日视图、
/// 统计）与**改日程**的调用方本身是两类，端口分开后前者的替身不必为后者提供空实现。
abstract interface class CalendarEventDeletion {
  /// 删除一条固定日程。
  ///
  /// 实现方对"不存在"的处理应当是**幂等**（删不掉等于已经删掉），因为调用方拿到的 id
  /// 可能来自一次已过期的视图；把"记录不在"当异常会让界面在一次无关的竞态后报错。
  Future<void> deleteEvent(String eventId);
}
