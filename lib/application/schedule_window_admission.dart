import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 一件普通任务与**本次规划窗口**的关系。
///
/// 之所以要有这个枚举：修复前装配层把 `watchOpenTasks()` 返回的**全部**未完成任务
/// 一律转成 `SchedulableTask`，其中包含"要到窗口结束之后才能开始"的那些。它们进不了
/// 任何候选，却仍会被算出一个目标分钟，于是以「还缺 N 分钟 · 可用时间不足」的形态
/// 出现在预览里——而用户看到的日历明明还有空档。
///
/// 分类是**唯一的准入判据**：生产装配与测试夹具必须调用同一个函数，不得各自复制条件
/// （复制就会漂移，而漂移的表现恰恰是"预览里多出一条谁也解释不了的缺口"）。
enum ScheduleWindowAdmissionCode {
  /// 任务可用区间与规划窗口相交 ⇒ 正常进入排程。
  intersectsWindow,

  /// 任务最早开始时间不早于窗口终点 ⇒ **静默排除**。
  ///
  /// 这不是错误：它只是"还没轮到它"。它仍留在任务清单与数据库里，本次规划不安排它，
  /// 也**不得**为它生成缺口。
  futureOutsideWindow,

  /// 截止时间不晚于窗口起点 ⇒ 进入问题报告，原因写"截止已过/截止窗口为 0"。
  ///
  /// **它与 [futureOutsideWindow] 是两类完全不同的事实**：未来的任务从没轮到过，
  /// 已过截止的任务已经错过了。后者必须让用户看见，静默丢弃等于把一件逾期的事藏起来。
  deadlineElapsed,

  /// 输入本身非法（非 UTC 边界、窗口非正、最早开始不早于截止）⇒ 阻断性输入错误。
  ///
  /// 这一支**不尝试排程**：拿一件时间边界自相矛盾的任务去排，只会产出无法复现的结果。
  invalid,
}

/// [ScheduleWindowAdmissionCode.invalid] 的**结构化**原因。
///
/// 与 `InvalidInputReason` 同一纪律：用户文案交给解释层，这里只承载分类
/// （写自由文本会让"哪一类错误"无法被断言）。
///
/// **为什么它与 `plan_validator.InvalidInputReason` 并列而不是合并**：那一个是
/// **已排出的块**的问题（块越界、片段长度、网格），只有拿到块之后才能判定；
/// 这一个是**准入期**的问题（还没排，任务自己的时间边界就自相矛盾）。
/// 两者的判定时机、可用信息与处置都不同，合并会让两边都拿不到需要的输入。
enum ScheduleWindowInvalidReason {
  /// 边界不是 UTC 时刻。本仓库所有时间范围都是 UTC 半开区间，本地时刻必须在进入排程前
  /// 由 `TimeZoneDatabase` 转换。
  nonUtcBoundary,

  /// 规划窗口不是半开正区间。
  nonPositivePlanningWindow,

  /// `availableFromUtc >= dueAtUtc`：窗口被夹成空集。
  startNotBeforeDeadline,
}

/// [classifyTaskForPlanningWindow] 的结果。
final class ScheduleWindowAdmission {
  const ScheduleWindowAdmission({
    required this.code,
    this.effectiveRange,
    this.invalidReason,
  });

  final ScheduleWindowAdmissionCode code;

  /// 任务在**本次规划窗口内**的有效区间。
  ///
  /// 只有 [ScheduleWindowAdmissionCode.intersectsWindow] 时非空：
  /// 它是 `[max(window.start, availableFrom), min(window.end, dueAt))`。
  final TimeRange? effectiveRange;

  final ScheduleWindowInvalidReason? invalidReason;

  bool get entersSchedule =>
      code == ScheduleWindowAdmissionCode.intersectsWindow ||
      code == ScheduleWindowAdmissionCode.deadlineElapsed;

  /// 失败信息与诊断导出的稳定短码（**不给用户看**）。
  String get evidenceCode => switch (code) {
    ScheduleWindowAdmissionCode.intersectsWindow => 'intersectsWindow',
    ScheduleWindowAdmissionCode.futureOutsideWindow => 'futureOutsideWindow',
    ScheduleWindowAdmissionCode.deadlineElapsed => 'deadlineElapsed',
    ScheduleWindowAdmissionCode.invalid =>
      'invalid:${invalidReason?.name ?? 'unknown'}',
  };
}

/// 把一件普通任务按**本次规划窗口**分类（纯函数）。
///
/// 契约：
/// - 不查数据库、不读系统时钟、不依赖 UI；
/// - 端点为**半开区间** `[start, end)`；
/// - 不修改任务；
/// - [ScheduleWindowAdmissionCode.futureOutsideWindow] 不是错误；
/// - [ScheduleWindowAdmissionCode.deadlineElapsed] 不是 [ScheduleWindowAdmissionCode.futureOutsideWindow]。
///
/// 判定顺序是定死的，且**两个边界条件都不含糊**：
/// 1. 非 UTC 或窗口非正 ⇒ `invalid`；
/// 2. `availableFrom >= window.end` ⇒ `futureOutsideWindow`
///    （恰好在窗口终点开始也算"还没轮到"，因为窗口是半开区间，终点那一瞬间不属于本次）；
/// 3. `due <= window.start` ⇒ `deadlineElapsed`；
/// 4. 夹出来的区间为空 ⇒ `invalid`（`startNotBeforeDeadline`）；
/// 5. 否则 `intersectsWindow`（区间可以短到只装得下一个粒度，那仍然算相交）。
ScheduleWindowAdmission classifyTaskForPlanningWindow({
  required PlannerTask task,
  required TimeRange planningWindow,
}) {
  final availableFrom = task.availableFromUtc;
  final dueAt = task.dueAtUtc;
  if (availableFrom != null && !availableFrom.isUtc) {
    return const ScheduleWindowAdmission(
      code: ScheduleWindowAdmissionCode.invalid,
      invalidReason: ScheduleWindowInvalidReason.nonUtcBoundary,
    );
  }
  if (dueAt != null && !dueAt.isUtc) {
    return const ScheduleWindowAdmission(
      code: ScheduleWindowAdmissionCode.invalid,
      invalidReason: ScheduleWindowInvalidReason.nonUtcBoundary,
    );
  }
  if (!planningWindow.startUtc.isUtc ||
      !planningWindow.endUtc.isUtc ||
      !planningWindow.endUtc.isAfter(planningWindow.startUtc)) {
    return const ScheduleWindowAdmission(
      code: ScheduleWindowAdmissionCode.invalid,
      invalidReason: ScheduleWindowInvalidReason.nonPositivePlanningWindow,
    );
  }

  if (availableFrom != null && !availableFrom.isBefore(planningWindow.endUtc)) {
    return const ScheduleWindowAdmission(
      code: ScheduleWindowAdmissionCode.futureOutsideWindow,
    );
  }
  if (dueAt != null && !dueAt.isAfter(planningWindow.startUtc)) {
    return const ScheduleWindowAdmission(
      code: ScheduleWindowAdmissionCode.deadlineElapsed,
    );
  }

  final effectiveStart =
      availableFrom == null || availableFrom.isBefore(planningWindow.startUtc)
      ? planningWindow.startUtc
      : availableFrom;
  final effectiveEnd = dueAt == null || dueAt.isAfter(planningWindow.endUtc)
      ? planningWindow.endUtc
      : dueAt;
  if (!effectiveEnd.isAfter(effectiveStart)) {
    return const ScheduleWindowAdmission(
      code: ScheduleWindowAdmissionCode.invalid,
      invalidReason: ScheduleWindowInvalidReason.startNotBeforeDeadline,
    );
  }
  return ScheduleWindowAdmission(
    code: ScheduleWindowAdmissionCode.intersectsWindow,
    effectiveRange: TimeRange(startUtc: effectiveStart, endUtc: effectiveEnd),
  );
}
