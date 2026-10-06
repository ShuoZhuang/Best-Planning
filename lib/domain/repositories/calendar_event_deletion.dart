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
/// **写入型**日程改动的端口：删除（整条／某一次）与**改写某一次**。
///
/// 文件名是历史遗留（最初只有删除），这里保留它而不是重命名——重命名要牵动实现、服务与组合根，
/// 对行为没有影响。端口本身很小，因此不值得为名字发动一次改名。
abstract interface class CalendarEventDeletion {
  /// 删除一条固定日程。
  ///
  /// 实现方对"不存在"的处理应当是**幂等**（删不掉等于已经删掉），因为调用方拿到的 id
  /// 可能来自一次已过期的视图；把"记录不在"当异常会让界面在一次无关的竞态后报错。
  Future<void> deleteEvent(String eventId);

  /// 只删除重复日程里的**某一次**（FR-CAL-02 的"修改单次实例"的删除一半）。
  ///
  /// 实现方据此写一行**起止相同的零长度例外**（约定见 `DriftCalendarRepository` 的读取端与
  /// §13.0 的 R4 行）：`calendar_events` 没有能表达"删除"的列，而零长度日程本身没有意义。
  ///
  /// **判定"是不是重复日程"由实现方负责**（要读规则行，只有仓储摸得到表），而且例外的
  /// `timeZoneId` 必须取**规则自己的时区**，否则本地日期换算会错位一天。锚点不带规则时，
  /// 实现方应退化为删除该行本身——否则会留下一条既不在单次查询里、也不会被展开的孤儿例外，
  /// 等于把这条日程悄悄藏起来一半。
  ///
  /// **幂等**：同一次出现再删一次不该报错，也不该让例外行不断堆积。
  ///
  /// 放在这个端口而不是 `RecurringCalendarRepository`：后者有 2 个测试替身，而这里**一个都没有**
  /// （与 `deleteEvent` 当初的选择一致——为了一处功能去改若干测试替身并不划算）。
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  });

  /// **改写**重复日程里的某一次（FR-CAL-02 的"修改单次实例"的修改一半）。
  ///
  /// 与 [deleteOccurrence] 相对：那条写的是"起止相同的零长度行＝这一次被删除"，这条写的是一条
  /// **正常长度**的替换行，展开器据此把这一次显示成新时间。
  ///
  /// 实现方同样要判断"是不是重复日程"：**单次日程**就直接改它自己那一行（"只改这一次"与
  /// "改整条"在单次日程上是同一件事）；**重复日程**则写一条例外，且例外的 `timeZoneId` 取
  /// **规则自己的时区**。
  ///
  /// **同一天已有例外时必须复用它那一行的 id**：写第二条会让展开器按遍历顺序二选一，结果
  /// 不确定——那是一种"有时生效有时不生效"的缺陷。
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  });

  /// **改写整个系列**（FR-CAL-02 的"整个系列"编辑一半）：所有各次一起换到新时间。
  ///
  /// 与 [replaceOccurrence] 的区别是**改的是锚点行与规则本身**，而不是写一条例外。因此：
  /// **规则里那两个本地时刻字段必须一起更新**（`localStartMinute` 与 `durationMinutes`），
  /// 否则锚点换了时间、展开器仍按旧钟点生成各次——那会得到"第一次是新的、后面还是旧的"这种
  /// 半成品。
  ///
  /// 锚点不带规则时**退化为改那一行**：单次日程没有"系列"可言。
  Future<void> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required DateTime updatedAtUtc,
  });

  /// Replaces the selected occurrence and every later occurrence by splitting
  /// the rule at the selected local date. The selected occurrence belongs only
  /// to the newly-created series.
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
  });

  /// Deletes the selected occurrence and everything after it by truncating the
  /// old rule to the previous local calendar day.
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  });
}
