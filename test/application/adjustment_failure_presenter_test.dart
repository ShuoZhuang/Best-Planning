// 1.11.0（计划 Task 12 Step 1）：错误归因必须与实际失败码一致，且日志脱敏。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/adjustment_failure_presenter.dart';
import 'package:personal_planner/domain/models/adjustment_failure_evidence.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';

void main() {
  const presenter = AdjustmentFailurePresenter();

  AdjustmentFailureEvidence evidence(
    PlanAdjustmentFailureCode code, {
    String title = '写周报',
    int requested = 60,
    int? placeable,
  }) => AdjustmentFailureEvidence(
    code: code,
    taskTitle: title,
    requestedMinutes: requested,
    placeableMinutes: placeable,
  );

  test('截止时间优先于容量：显示行动是改截止，而不是腾时间', () {
    final message = presenter.present(
      evidence(PlanAdjustmentFailureCode.deadlineExceeded),
    );

    expect(message.title, '会超过截止时间');
    expect(message.explanation, contains('写周报'));
    expect(message.explanation, isNot(contains('可用时间不足')));
    expect(message.retryable, isFalse);
  });

  test('禁止星期与固定冲突各自有独立原因，不复用同一句话', () {
    final weekday = presenter.present(
      evidence(PlanAdjustmentFailureCode.disallowedWeekday),
    );
    final fixed = presenter.present(
      evidence(PlanAdjustmentFailureCode.fixedOrProtectedConflict),
    );

    expect(weekday.title, '目标日期不允许安排');
    expect(fixed.title, '与固定安排冲突');
    expect(weekday.explanation, isNot(fixed.explanation));
  });

  test('任务单日上限与全局单日上限可区分', () {
    final task = presenter.present(
      evidence(PlanAdjustmentFailureCode.taskDailyLimitReached),
    );
    final global = presenter.present(
      evidence(PlanAdjustmentFailureCode.globalDailyLimitReached),
    );

    expect(task.title, '超过任务单日上限');
    expect(global.title, '超过全局单日上限');
  });

  test('搜索预算耗尽明确"不能断言没有合法位置"，并且可重试', () {
    final message = presenter.present(
      evidence(PlanAdjustmentFailureCode.searchBudgetExhausted),
    );

    expect(message.explanation, contains('不能断言'));
    expect(message.retryable, isTrue);
    expect(message.explanation, contains('重新生成'));
  });

  test('内部不变量异常不得伪装成"时间不足"', () {
    final message = presenter.present(
      evidence(PlanAdjustmentFailureCode.invariantViolation),
    );

    expect(message.title, '生成出现异常');
    expect(message.explanation, isNot(contains('时间不足')));
    expect(message.retryable, isFalse);
  });

  test('缺口分钟 = max(0, 要求 - 可放)；未知可放数不伪造 0', () {
    expect(
      evidence(
        PlanAdjustmentFailureCode.noLegalSlot,
        requested: 60,
        placeable: 15,
      ).shortageMinutes,
      45,
    );
    expect(
      evidence(
        PlanAdjustmentFailureCode.noLegalSlot,
        requested: 60,
        placeable: 90,
      ).shortageMinutes,
      0,
    );
    expect(
      evidence(
        PlanAdjustmentFailureCode.noLegalSlot,
        requested: 60,
      ).shortageMinutes,
      isNull,
    );
  });

  test('空标题显示「未命名任务」，绝不显示内部 ID', () {
    final message = presenter.present(
      evidence(PlanAdjustmentFailureCode.deadlineExceeded, title: '   '),
    );

    expect(message.explanation, contains(unnamedTaskTitle));
    expect(message.explanation, isNot(contains('adj-')));
  });

  test('日志投影只含稳定码与数量，不含标题/日期/路径', () {
    final projection = AdjustmentFailureEvidence(
      code: PlanAdjustmentFailureCode.globalDailyLimitReached,
      taskTitle: '机密标题',
      requestedMinutes: 90,
      placeableMinutes: 30,
      consideredLocalDates: [DateTime(2026, 10, 19)],
      blockingConstraintCodes: const ['globalDailyLimitReached'],
    ).toLogProjection();

    expect(projection['code'], 'globalDailyLimitReached');
    expect(projection['shortageMinutes'], 60);
    expect(projection['consideredDateCount'], 1);
    expect(projection.values.join(' '), isNot(contains('机密标题')));
    expect(projection.values.join(' '), isNot(contains('2026-10-19')));
    expect(projection.values.join(' '), isNot(contains('G:')));
  });
}
