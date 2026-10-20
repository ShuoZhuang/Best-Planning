import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/scheduling/recurring_pace_curve.dart';

void main() {
  test('even 按容量比例推进', () {
    final decision = recurringPaceDecision(
      remainingMinutes: 180,
      visibleCapacityMinutes: 90,
      afterCapacityMinutes: 270,
      curve: RecurringPaceCurve.even,
    );
    expect(decision.capacityRatio, closeTo(0.25, 0.0001));
    expect(decision.curveMinutes, 45);
    expect(decision.requiredNowMinutes, 0);
    expect(decision.targetNowMinutes, 45);
  });

  test('early 早于 even，deadlineWeighted 晚于 even', () {
    final early = recurringPaceDecision(
      remainingMinutes: 180,
      visibleCapacityMinutes: 90,
      afterCapacityMinutes: 270,
      curve: RecurringPaceCurve.early,
    );
    final even = recurringPaceDecision(
      remainingMinutes: 180,
      visibleCapacityMinutes: 90,
      afterCapacityMinutes: 270,
      curve: RecurringPaceCurve.even,
    );
    final late = recurringPaceDecision(
      remainingMinutes: 180,
      visibleCapacityMinutes: 90,
      afterCapacityMinutes: 270,
      curve: RecurringPaceCurve.deadlineWeighted,
    );
    expect(early.targetNowMinutes, greaterThan(even.targetNowMinutes));
    expect(late.targetNowMinutes, lessThan(even.targetNowMinutes));
  });

  test('窗口后容量不足时 requiredNow 优先，保证周期可完成', () {
    final decision = recurringPaceDecision(
      remainingMinutes: 180,
      visibleCapacityMinutes: 120,
      afterCapacityMinutes: 30,
      curve: RecurringPaceCurve.deadlineWeighted,
    );
    expect(decision.requiredNowMinutes, 150);
    expect(decision.targetNowMinutes, 150);
  });

  test('无合法容量时单独诊断，不把剩余量硬塞进窗口', () {
    final decision = recurringPaceDecision(
      remainingMinutes: 120,
      visibleCapacityMinutes: 0,
      afterCapacityMinutes: 0,
      curve: RecurringPaceCurve.even,
    );
    expect(decision.noCapacity, isTrue);
    expect(decision.targetNowMinutes, 0);
    expect(decision.requiredNowMinutes, 120);
  });

  test('selectedWeekdays 使用 even 曲线，非法掩码被拒绝', () {
    final decision = recurringPaceDecisionForWeekdays(
      remainingMinutes: 120,
      visibleCapacityMinutes: 60,
      afterCapacityMinutes: 60,
      allowedWeekdaysMask: 0x1F,
    );
    expect(decision.targetNowMinutes, 60);
    expect(
      () => recurringPaceDecisionForWeekdays(
        remainingMinutes: 120,
        visibleCapacityMinutes: 60,
        afterCapacityMinutes: 60,
        allowedWeekdaysMask: 0,
      ),
      throwsArgumentError,
    );
  });

  test('达标后停止新增排程，额外投入保留为超额进度', () {
    expect(
      recurringTargetReached(targetMinutes: 120, effectiveCreditedMinutes: 120),
      isTrue,
    );
    expect(
      recurringTargetReached(targetMinutes: 120, effectiveCreditedMinutes: 119),
      isFalse,
    );
    expect(
      recurringOverachievedMinutes(
        targetMinutes: 120,
        effectiveCreditedMinutes: 150,
      ),
      30,
    );
    expect(
      recurringOverachievedMinutes(
        targetMinutes: 120,
        effectiveCreditedMinutes: 90,
      ),
      0,
    );
  });

  test('四个节奏映射到正确曲线', () {
    expect(curveForPace(RecurringPace.even), RecurringPaceCurve.even);
    expect(curveForPace(RecurringPace.early), RecurringPaceCurve.early);
    expect(
      curveForPace(RecurringPace.deadlineWeighted),
      RecurringPaceCurve.deadlineWeighted,
    );
    expect(
      curveForPace(RecurringPace.selectedWeekdays),
      RecurringPaceCurve.selectedWeekdays,
    );
  });
}
