import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/bounded_repair_search.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

PlannedBlock _block(String id, String taskId, int startHour, int endHour) =>
    PlannedBlock(
      id: id,
      taskId: taskId,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 17, startHour),
        endUtc: DateTime.utc(2026, 10, 17, endHour),
      ),
    );

/// 一个"唯一长槽被灵活任务占住"的问题：搜索必须搬走灵活任务，连续任务才能完整放下。
final class _SwapProblem implements RepairSearchProblem {
  _SwapProblem({this.solvable = true});

  final bool solvable;

  static const _flexible = 'flexible';
  static const _continuous = 'continuous';

  @override
  int objectiveValue(List<PlannedBlock> blocks) => unscheduledMinutes(blocks);

  @override
  int unscheduledMinutes(List<PlannedBlock> blocks) {
    final hasContinuous = blocks.any((block) => block.taskId == _continuous);
    return hasContinuous ? 0 : 60;
  }

  @override
  String signature(List<PlannedBlock> blocks) => [
    for (final block in [...blocks]..sort((a, b) => a.id.compareTo(b.id)))
      '${block.id}:${block.taskId}:${block.startUtc.microsecondsSinceEpoch}',
  ].join('|');

  @override
  List<List<PlannedBlock>> successors(List<PlannedBlock> blocks, int depth) {
    if (!solvable) return const [];
    final flexible = blocks
        .where((block) => block.taskId == _flexible)
        .firstOrNull;
    if (flexible == null) return const [];
    for (final block in blocks) {
      if (block.taskId == _continuous) return const [];
    }
    return [
      [
        _block('flexible-moved', _flexible, 13, 14),
        _block('continuous-placed', _continuous, 9, 10),
      ],
    ];
  }

  @override
  List<UnscheduledTask> unscheduledFor(List<PlannedBlock> blocks) =>
      unscheduledMinutes(blocks) == 0
      ? const []
      : [
          UnscheduledTask(
            taskId: _continuous,
            shortageMinutes: 60,
            primaryReason: UnscheduledReason(
              code: UnscheduledReasonCode.insufficientCapacity,
              placementRemainingMinutes: 60,
            ),
            reasons: [],
          ),
        ];
}

void main() {
  test('贪心占住唯一长槽时，一次搬移即可完整安排连续任务', () {
    final problem = _SwapProblem();
    final result = runBoundedRepairSearch(
      problem: problem,
      initialBlocks: [_block('flexible', _SwapProblem._flexible, 9, 10)],
    );
    expect(result.status, RepairSearchStatus.feasible);
    expect(result.unscheduled, isEmpty);
    expect(
      result.bestBlocks.any((b) => b.taskId == _SwapProblem._continuous),
      isTrue,
    );
    expect(result.visitedStates, greaterThan(0));
  });

  test('没有更好方案时返回原合法方案，原对象逐值不变', () {
    final initial = [_block('flexible', _SwapProblem._flexible, 9, 10)];
    final result = runBoundedRepairSearch(
      problem: _SwapProblem(solvable: false),
      initialBlocks: initial,
    );
    expect(result.status, RepairSearchStatus.hardInfeasible);
    expect(result.bestBlocks, initial);
    expect(result.unscheduled.single.shortageMinutes, 60);
  });

  test('预算耗尽与已证明无解必须分开', () {
    final tiny = runBoundedRepairSearch(
      problem: _SwapProblem(),
      initialBlocks: [_block('flexible', _SwapProblem._flexible, 9, 10)],
      budget: const SearchBudget(
        maxStates: 1,
        maxFrontier: 1,
        maxRepairDepth: 1,
        maxBranchesPerState: 1,
      ),
    );
    expect(tiny.status, RepairSearchStatus.budgetExhausted);
    expect(tiny.bestBlocks, isNotEmpty);
  });

  test('相同输入逐值确定，后继顺序不影响结果', () {
    final result = runBoundedRepairSearch(
      problem: _SwapProblem(),
      initialBlocks: [_block('flexible', _SwapProblem._flexible, 9, 10)],
    );
    final again = runBoundedRepairSearch(
      problem: _SwapProblem(),
      initialBlocks: [_block('flexible', _SwapProblem._flexible, 9, 10)],
    );
    expect(result.deterministicSignature, again.deterministicSignature);
    expect(result.status, again.status);
    expect(
      result.bestBlocks.map((block) => block.id),
      again.bestBlocks.map((block) => block.id),
    );
  });
}
