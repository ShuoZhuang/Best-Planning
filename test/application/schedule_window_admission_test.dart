// 规划窗口准入的边界用例（实施计划 §1.7 与 Task 2 Step 1）。
//
// ## 这一层为什么必须存在
//
// 修复前 `RepositoryScheduleProblemSource.load()` 把 `watchOpenTasks()` 返回的**全部**
// 未完成任务一律转成排程输入。于是"下周才轮到"的任务（`availableFromUtc` 落在规划窗口
// 终点或之后）也进了问题，却一个候选都生成不出来——它带着 210 分钟的目标出现在预览里，
// 被解释成"可用时间不足"。用户看到的却是日历上还有大片空档。
//
// 正确的处置是**在准入处分类**：未来任务静默排除（不是错误），已过截止的任务进入问题
// 报告（不得静默消失）。两者不能合并成一种。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/schedule_window_admission.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 一个**绕过领域模型校验**的替身：`PlannerTask` 是 `final class` 且构造函数即拒绝
/// 非 UTC 边界，因此"上游漏了 `toUtc()`"这种情况**在 Dart 里已经无法构造**。
///
/// 准入函数里的非 UTC 分支因此是**第二道防线**（不可达但保留），这一点在下面用注释
/// 登记，而不是写一条永远为假的断言——那只会让后来者以为它被测过。
void main() {
  final created = DateTime.utc(2026, 10, 1);
  // 同一个规划窗口贯穿全部用例：2026-10-08T04:00Z 起七天（东八区周四 12:00 → 下周四 00:00）。
  final windowStart = DateTime.utc(2026, 10, 8, 4);
  final windowEnd = DateTime.utc(2026, 10, 15, 4);
  final window = TimeRange(startUtc: windowStart, endUtc: windowEnd);

  PlannerTask task({DateTime? availableFromUtc, DateTime? dueAtUtc}) =>
      PlannerTask(
        id: 'ordinary-a',
        title: 'ordinary-a',
        priority: TaskPriority.high,
        estimatedMinutes: 60,
        remainingMinutes: 60,
        dueAtUtc: dueAtUtc,
        availableFromUtc: availableFromUtc,
        energyLevel: TaskEnergyLevel.high,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
        status: TaskStatus.open,
        createdAtUtc: created,
        updatedAtUtc: created,
      );

  ScheduleWindowAdmission classify({
    DateTime? availableFromUtc,
    DateTime? dueAtUtc,
    TimeRange? planningWindow,
  }) => classifyTaskForPlanningWindow(
    task: task(availableFromUtc: availableFromUtc, dueAtUtc: dueAtUtc),
    planningWindow: planningWindow ?? window,
  );

  test('A01 无开始、无截止 ⇒ 进入当前窗口', () {
    final admission = classify();
    expect(admission.code, ScheduleWindowAdmissionCode.intersectsWindow);
    expect(admission.effectiveRange, window);
  });

  test('最早开始恰好是窗口起点 ⇒ 进入', () {
    final admission = classify(availableFromUtc: windowStart);
    expect(admission.code, ScheduleWindowAdmissionCode.intersectsWindow);
    expect(admission.effectiveRange!.startUtc, windowStart);
  });

  test('A02 最早开始恰好是窗口终点 ⇒ futureOutsideWindow（半开区间）', () {
    final admission = classify(availableFromUtc: windowEnd);
    expect(
      admission.code,
      ScheduleWindowAdmissionCode.futureOutsideWindow,
      reason: '窗口终点那一瞬间不属于本次规划，因此"恰好在终点才能开始"仍是还没轮到',
    );
    expect(admission.effectiveRange, isNull);
  });

  test('最早开始晚于窗口终点 ⇒ futureOutsideWindow', () {
    expect(
      classify(availableFromUtc: windowEnd.add(const Duration(minutes: 1)))
          .code,
      ScheduleWindowAdmissionCode.futureOutsideWindow,
    );
  });

  test('A03 截止恰好是窗口起点 ⇒ deadlineElapsed（不是 future，也不静默消失）', () {
    final admission = classify(dueAtUtc: windowStart);
    expect(admission.code, ScheduleWindowAdmissionCode.deadlineElapsed);
  });

  test('截止早于窗口起点 ⇒ deadlineElapsed', () {
    expect(
      classify(dueAtUtc: windowStart.subtract(const Duration(days: 2))).code,
      ScheduleWindowAdmissionCode.deadlineElapsed,
    );
  });

  test('截止恰好是窗口终点 ⇒ 有效结束为窗口终点', () {
    final admission = classify(dueAtUtc: windowEnd);
    expect(admission.code, ScheduleWindowAdmissionCode.intersectsWindow);
    expect(admission.effectiveRange!.endUtc, windowEnd);
  });

  test('开始与截止把窗口夹成很短的一段 ⇒ 仍然进入', () {
    final start = windowStart.add(const Duration(hours: 1));
    final end = start.add(const Duration(minutes: 5)); // 恰好一个 5 分钟粒度
    final admission = classify(availableFromUtc: start, dueAtUtc: end);
    expect(admission.code, ScheduleWindowAdmissionCode.intersectsWindow);
    expect(admission.effectiveRange!.startUtc, start);
    expect(admission.effectiveRange!.endUtc, end);
  });

  test('非 UTC 边界被领域模型本身挡住（函数里的那一支是不可达的第二道防线）', () {
    expect(
      () => task(availableFromUtc: DateTime(2026, 10, 9, 8)),
      throwsArgumentError,
      reason:
          '`PlannerTask` 的构造函数已经拒绝非 UTC 边界，且它是 `final class`——'
          '因此"上游传进非 UTC 任务"在 Dart 里构造不出来。'
          '准入函数仍保留 nonUtcBoundary 分支：它是唯一闸门，不该假设上游永远正确；'
          '但它**没有**可执行的用例，这里如实登记而不是写一条永远为真的断言。',
    );
  });

  test('availableFrom >= due ⇒ invalid（startNotBeforeDeadline）', () {
    final instant = windowStart.add(const Duration(hours: 2));
    final admission = classify(availableFromUtc: instant, dueAtUtc: instant);
    expect(admission.code, ScheduleWindowAdmissionCode.invalid);
    expect(
      admission.invalidReason,
      ScheduleWindowInvalidReason.startNotBeforeDeadline,
    );
  });

  test('断言证据码稳定且不含自由文本', () {
    expect(classify().evidenceCode, 'intersectsWindow');
    expect(
      classify(availableFromUtc: windowEnd).evidenceCode,
      'futureOutsideWindow',
    );
    expect(classify(dueAtUtc: windowStart).evidenceCode, 'deadlineElapsed');
  });

  test('entersSchedule 只对相交与截止已过为真', () {
    expect(classify().entersSchedule, isTrue);
    expect(classify(dueAtUtc: windowStart).entersSchedule, isTrue);
    expect(classify(availableFromUtc: windowEnd).entersSchedule, isFalse);
  });
}
