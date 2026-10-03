import 'package:personal_planner/domain/models/analytics.dart';

/// 行为事件的写入端口（FR-STAT 的打断／重排／建议三类）。
///
/// `change_log` 此前只有 `drift_plan_repository` 在写计划生命周期事件（`undo:`／`confirm`／
/// `create`），而统计侧 `AnalyticsDao._events` 读的是 `interruption:`／`replan:`／
/// `suggestion:` 三类**行为**事件——两侧没有一处对得上，因此"常见打断""重排原因""建议采纳
/// 行为"三项统计**结构上永远为空**（W5）。这个端口就是那三类事件的写入方。
abstract interface class AnalyticsEventLog {
  /// 记录一条行为事件，最终以 `<kind>:<code>` 存入 `change_log.operation`。
  ///
  /// 约定与读取端一致：读取端按**第一个冒号**切分 `operation`，并要求两侧都非空，
  /// 因此实现必须拒绝空 [code] 与含冒号的 [code]（否则 code 会被截断成半个词）。
  Future<void> record({
    required AnalyticsEventKind kind,
    required String code,
    required DateTime observedAtUtc,
    String entityId = '',
  });
}
