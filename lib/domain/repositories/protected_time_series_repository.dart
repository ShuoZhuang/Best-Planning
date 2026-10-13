import 'package:personal_planner/domain/models/protected_time_series.dart';

/// 读取**自定义保护时间的系列清单**（课程与保护时间管理修复计划 Task 6 Step 3）。
///
/// ## 为什么是独立的小端口
///
/// 保护时间与固定日程共用 `calendar_events`，但**读法完全不同**：
/// 日程需要"某个时间窗内的发生次数"（那是 `CalendarRepository.occurrencesBetween`），
/// 而管理页需要"**我一共建了哪几条规则**"——一个**没有时间窗**的问题。
///
/// 把 `listProtectedSeries()` 加到 `CalendarRepository` 上会**一次牵动 5 个测试替身**
/// （见 `calendar_event_deletion.dart` 里记的那条教训），而它们多数只关心时间窗查询。
/// 因此单独一个端口：愿意支持的实现多实现一个接口，代价只落在需要它的那一处。
///
/// **顺带一个语义好处**：这个端口**读不到规则来源的保护时间**（睡眠／早餐／午餐／
/// 晚餐／固定休息）。它们不是 `CalendarEvent`，因此"管理页只列用户自己建的那些"
/// 这件事由类型保证，而不是靠调用方自觉过滤。
abstract interface class ProtectedTimeSeriesReader {
  /// 用户自建的保护时间系列（**一条锚点一行**）。
  ///
  /// **不按学期过滤**：保护时间不属于任何学期（它是日程的一部分，不是课）。
  Future<List<ProtectedTimeSeries>> listProtectedSeries();

  /// 按锚点 id 读一条；不存在返回 `null`。
  ///
  /// 编辑页用它把草稿填上。**单独一个方法而不是 `list().firstWhere`**：
  /// 编辑页只关心一条，而列出全部再筛在真实库上是白读一遍全部锚点行。
  Future<ProtectedTimeSeries?> findProtectedSeries(String anchorId);
}
