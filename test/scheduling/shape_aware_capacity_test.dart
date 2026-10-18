import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/shape_aware_capacity.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';
final _date = DateTime(2026, 10, 17);

AvailabilitySlot _slot(int startMinute, int minutes) => AvailabilitySlot(
  localDate: _date,
  range: TimeRange(
    startUtc: DateTime.utc(2026, 10, 17, startMinute ~/ 60, startMinute % 60),
    endUtc: DateTime.utc(
      2026,
      10,
      17,
      startMinute ~/ 60,
      startMinute % 60,
    ).add(Duration(minutes: minutes)),
  ),
);

TaskDayCapacity _capacityFor({
  required SchedulableTask task,
  required List<AvailabilitySlot> slots,
  int dailyLimit = 480,
  List<PlannedBlock> blocks = const [],
}) {
  final rules = DefaultSettings.v1().copyWith(
    dailyMovableTaskLimitMinutes: dailyLimit,
  );
  final policy = DailySchedulingPolicy(
    localDate: _date,
    resolvedRules: rules,
    softReserveTargetMinutes: 0,
  );
  final problem = ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 17),
      endUtc: DateTime.utc(2026, 10, 18),
    ),
    timeZoneId: _zone,
    tasks: [task],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: blocks,
    rules: rules,
    dailyPolicies: {_date: policy},
    weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
    preferences: const PreferenceProfile(),
    inputHash: 'test',
  );
  final analysis = AvailabilityAnalysis(
    slots: slots,
    hardFreeSlots: slots,
    blockedSegments: const [],
    calendarGapMinutes: slots.fold(
      0,
      (sum, slot) => sum + slot.durationMinutes,
    ),
    hardFreeMinutes: slots.fold(0, (sum, slot) => sum + slot.durationMinutes),
  );
  final ledger = buildDayCapacityLedger(
    problem: problem,
    availability: analysis,
    baselineBlocks: blocks,
    zones: _zones,
  );
  return buildTaskDayCapacities(
    problem: problem,
    availability: analysis,
    ledger: ledger,
    allBlocks: blocks,
    zones: _zones,
  )[task.id]![_date]!;
}

void main() {
  test('总空闲足够但最长连续段不足：连续任务不可落地', () {
    final capacity = _capacityFor(
      task: const SchedulableTask(
        id: 'continuous',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.continuous,
        minChunkMinutes: 60,
        maxChunkMinutes: 60,
      ),
      slots: [_slot(9 * 60, 30), _slot(11 * 60, 30)],
    );
    expect(capacity.constraintEligibleMinutes, 60);
    expect(capacity.longestContiguousMinutes, 30);
    expect(capacity.placeableMinutes, 0);
    expect(
      capacity.rejectionCounts[CandidateRejectionCode.exceedsGapCapacity],
      1,
    );
  });

  test('可拆分任务按最小片段计数，短尾不被算成任意小空隙', () {
    final capacity = _capacityFor(
      task: const SchedulableTask(
        id: 'split',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
      slots: [_slot(9 * 60, 20), _slot(11 * 60, 90)],
    );
    expect(capacity.constraintEligibleMinutes, 110);
    expect(capacity.longestContiguousMinutes, 90);
    expect(capacity.placeableMinutes, 60);
    expect(capacity.slotCountByChunkSize[30], 1);
    expect(capacity.slotCountByChunkSize[60], 1);
  });

  test('20 分钟坏空档：有 15 分钟任务时可落地，全是 30 分钟片段时不可落地', () {
    final shortTask = _capacityFor(
      task: const SchedulableTask(
        id: 'short',
        requiredMinutes: 20,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 15,
        maxChunkMinutes: 30,
      ),
      slots: [_slot(9 * 60, 20)],
    );
    expect(shortTask.placeableMinutes, 15);

    final longTask = _capacityFor(
      task: const SchedulableTask(
        id: 'long',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
      slots: [_slot(9 * 60, 20)],
    );
    expect(longTask.placeableMinutes, 0);
    expect(
      longTask.rejectionCounts,
      contains(CandidateRejectionCode.exceedsGapCapacity),
    );
  });

  test('任务单日上限与全局上限分别归因，不混成一个数', () {
    final capacity = _capacityFor(
      task: const SchedulableTask(
        id: 'limited',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
        maxMinutesPerLocalDay: 0,
      ),
      slots: [_slot(9 * 60, 120)],
      dailyLimit: 1,
      blocks: [
        PlannedBlock(
          id: 'used',
          taskId: 'other',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 17, 9),
            endUtc: DateTime.utc(2026, 10, 17, 9, 1),
          ),
        ),
      ],
    );
    expect(capacity.remainingTaskDailyLimitMinutes, 0);
    expect(capacity.remainingGlobalDailyLimitMinutes, 0);
    expect(
      capacity.rejectionCounts,
      contains(CandidateRejectionCode.exceedsDailyTaskLimit),
    );
    expect(
      capacity.rejectionCounts,
      contains(CandidateRejectionCode.exceedsDailyMovableLimit),
    );
    expect(capacity.placeableMinutes, 0);
  });

  test('输入顺序不影响形状签名', () {
    TaskDayCapacity build(List<AvailabilitySlot> slots) => _capacityFor(
      task: const SchedulableTask(
        id: 'order',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
      slots: slots,
    );
    final a = build([_slot(9 * 60, 30), _slot(13 * 60, 60)]);
    final b = build([_slot(13 * 60, 60), _slot(9 * 60, 30)]);
    expect(a.shapeSignature, b.shapeSignature);
  });
}
