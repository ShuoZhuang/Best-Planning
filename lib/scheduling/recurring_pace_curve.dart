import 'dart:math' as math;

import 'package:personal_planner/domain/models/recurring_task.dart';

/// 周期推进曲线与“本窗口必须完成量”（1.12.0 设计 §7.2、Task 10）。
///
/// 纯函数：输入周期剩余量、窗口内合法容量、窗口后容量与节奏；输出给排程器的
/// `targetNow`。容量不足时 `requiredNow` 优先，保证周期仍可完成。
enum RecurringPaceCurve { even, early, deadlineWeighted, selectedWeekdays }

RecurringPaceCurve curveForPace(RecurringPace pace) => switch (pace) {
  RecurringPace.even => RecurringPaceCurve.even,
  RecurringPace.early => RecurringPaceCurve.early,
  RecurringPace.deadlineWeighted => RecurringPaceCurve.deadlineWeighted,
  RecurringPace.selectedWeekdays => RecurringPaceCurve.selectedWeekdays,
};

/// `r` 是“窗口内可见容量 / 全周期剩余容量”的比例，必须在 `[0,1]`。
double recurringPaceCurve(RecurringPaceCurve curve, double ratio) {
  final r = ratio.clamp(0.0, 1.0);
  return switch (curve) {
    RecurringPaceCurve.even => r,
    RecurringPaceCurve.selectedWeekdays => r,
    // 尽早：前半段就完成大部分。
    RecurringPaceCurve.early => 1 - math.pow(1 - r, 2).toDouble(),
    // 临近截止：把量压到后段。
    RecurringPaceCurve.deadlineWeighted => math.pow(r, 2).toDouble(),
  };
}

/// 一次推进计算结果。
final class RecurringPaceDecision {
  const RecurringPaceDecision({
    required this.targetNowMinutes,
    required this.requiredNowMinutes,
    required this.curveMinutes,
    required this.capacityRatio,
    required this.noCapacity,
  });

  final int targetNowMinutes;
  final int requiredNowMinutes;
  final int curveMinutes;
  final double capacityRatio;
  final bool noCapacity;
}

/// 计算当前窗口应承诺的周期分钟数。
///
/// ```text
/// R = 周期剩余有效进度
/// r = C_visible / (C_visible + C_after)
/// requiredNow = max(0, R - C_after)
/// curveMinutes = ceil(R * curve(r))
/// targetNow = clamp(max(requiredNow, curveMinutes), 0, R)
/// ```
RecurringPaceDecision recurringPaceDecision({
  required int remainingMinutes,
  required int visibleCapacityMinutes,
  required int afterCapacityMinutes,
  required RecurringPaceCurve curve,
}) {
  if (remainingMinutes < 0 ||
      visibleCapacityMinutes < 0 ||
      afterCapacityMinutes < 0) {
    throw ArgumentError('Capacity and remaining minutes must not be negative.');
  }
  final totalCapacity = visibleCapacityMinutes + afterCapacityMinutes;
  if (remainingMinutes == 0) {
    return const RecurringPaceDecision(
      targetNowMinutes: 0,
      requiredNowMinutes: 0,
      curveMinutes: 0,
      capacityRatio: 0,
      noCapacity: false,
    );
  }
  if (totalCapacity <= 0) {
    return RecurringPaceDecision(
      targetNowMinutes: 0,
      requiredNowMinutes: remainingMinutes,
      curveMinutes: 0,
      capacityRatio: 0,
      noCapacity: true,
    );
  }
  final ratio = visibleCapacityMinutes / totalCapacity;
  final requiredNow = math.max(0, remainingMinutes - afterCapacityMinutes);
  final curveMinutes = (remainingMinutes * recurringPaceCurve(curve, ratio))
      .ceil();
  final targetNow = math.min(
    remainingMinutes,
    math.max(requiredNow, curveMinutes),
  );
  return RecurringPaceDecision(
    targetNowMinutes: targetNow,
    requiredNowMinutes: requiredNow,
    curveMinutes: curveMinutes,
    capacityRatio: ratio,
    noCapacity: false,
  );
}

/// 按允许星期过滤后的可见容量比例（只使用合法候选容量）。
RecurringPaceDecision recurringPaceDecisionForWeekdays({
  required int remainingMinutes,
  required int visibleCapacityMinutes,
  required int afterCapacityMinutes,
  required int allowedWeekdaysMask,
}) {
  if (allowedWeekdaysMask <= 0 || allowedWeekdaysMask & ~0x7F != 0) {
    throw ArgumentError.value(
      allowedWeekdaysMask,
      'allowedWeekdaysMask',
      'Must be a non-empty 7-bit weekday mask.',
    );
  }
  return recurringPaceDecision(
    remainingMinutes: remainingMinutes,
    visibleCapacityMinutes: visibleCapacityMinutes,
    afterCapacityMinutes: afterCapacityMinutes,
    curve: RecurringPaceCurve.selectedWeekdays,
  );
}

/// 本窗口是否已经达到目标、应停止新增排程。
bool recurringTargetReached({
  required int targetMinutes,
  required int effectiveCreditedMinutes,
}) => targetMinutes > 0 && effectiveCreditedMinutes >= targetMinutes;

/// 额外的真实投入保留为超额进度，不产生负剩余。
int recurringOverachievedMinutes({
  required int targetMinutes,
  required int effectiveCreditedMinutes,
}) {
  final extra = effectiveCreditedMinutes - targetMinutes;
  return extra > 0 ? extra : 0;
}
