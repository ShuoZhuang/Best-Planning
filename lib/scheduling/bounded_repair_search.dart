import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 有界修复搜索的确定性预算（规范 §5.6 / ALG20-034）。
///
/// **所有判断只依赖已访问状态数**，不读墙钟：否则同一输入会因机器负载不同得到
/// 不同提案。
final class SearchBudget {
  const SearchBudget({
    required this.maxStates,
    required this.maxFrontier,
    required this.maxRepairDepth,
    required this.maxBranchesPerState,
  });

  /// 生产默认预算。数值经性能夹具冻结；改动必须附基准记录。
  static const SearchBudget production = SearchBudget(
    maxStates: 512,
    maxFrontier: 64,
    maxRepairDepth: 3,
    maxBranchesPerState: 12,
  );

  final int maxStates;
  final int maxFrontier;
  final int maxRepairDepth;
  final int maxBranchesPerState;

  SearchBudget validate() {
    if (maxStates <= 0 ||
        maxFrontier <= 0 ||
        maxRepairDepth <= 0 ||
        maxBranchesPerState <= 0) {
      throw ArgumentError('搜索预算的每一项都必须为正');
    }
    return this;
  }
}

/// 搜索结论的三种**必须分开**的状态（规范 §5.6 / ALG20-032）。
enum RepairSearchStatus { feasible, hardInfeasible, budgetExhausted }

final class RepairSearchResult {
  RepairSearchResult({
    required this.status,
    required List<PlannedBlock> bestBlocks,
    required List<UnscheduledTask> unscheduled,
    required this.visitedStates,
    required this.deterministicSignature,
  }) : bestBlocks = List.unmodifiable(
         [...bestBlocks]..sort((a, b) => a.id.compareTo(b.id)),
       ),
       unscheduled = List.unmodifiable(
         [...unscheduled]..sort((a, b) => a.taskId.compareTo(b.taskId)),
       );

  final RepairSearchStatus status;
  final List<PlannedBlock> bestBlocks;
  final List<UnscheduledTask> unscheduled;
  final int visitedStates;
  final String deterministicSignature;
}

/// 一个有界搜索问题：目标值、后继、签名与未安排分钟都由调用方提供。
///
/// 把它抽成接口而不是让搜索器认识引擎，是因为"哪个状态更优"与"还有多少分钟没排"
/// 必须来自**同一份**方案目标与容量账本；搜索器只负责确定性枚举与去重。
abstract interface class RepairSearchProblem {
  /// 越小越好；生产实现按字典序向量编码。
  int objectiveValue(List<PlannedBlock> blocks);

  /// 未安排分钟总数；`0` 即搜索成功。
  int unscheduledMinutes(List<PlannedBlock> blocks);

  /// 稳定签名：排序后的块、剩余量与调整状态。**不得**使用对象 hashCode。
  String signature(List<PlannedBlock> blocks);

  /// 按固定顺序返回后继；搜索器会再按签名排序并截断。
  List<List<PlannedBlock>> successors(List<PlannedBlock> blocks, int depth);

  /// 把最终块集合换算成结构化的未安排项。
  List<UnscheduledTask> unscheduledFor(List<PlannedBlock> blocks);
}

/// 确定性最佳优先搜索：只保留每个签名下字典序最优的状态。
RepairSearchResult runBoundedRepairSearch({
  required RepairSearchProblem problem,
  required List<PlannedBlock> initialBlocks,
  SearchBudget budget = SearchBudget.production,
}) {
  budget.validate();
  final initial = _canonical(initialBlocks);
  var bestBlocks = initial;
  var bestObjective = problem.objectiveValue(initial);
  var bestUnscheduled = problem.unscheduledMinutes(initial);
  var visited = 0;

  final frontier = <_State>[
    _State(
      blocks: initial,
      depth: 0,
      objective: bestObjective,
      unscheduled: bestUnscheduled,
      signature: problem.signature(initial),
    ),
  ];
  final seen = <String>{frontier.first.signature};

  while (frontier.isNotEmpty && visited < budget.maxStates) {
    frontier.sort(_compareStates);
    if (frontier.length > budget.maxFrontier) {
      frontier.removeRange(budget.maxFrontier, frontier.length);
    }
    final state = frontier.removeAt(0);
    visited++;

    if (state.unscheduled < bestUnscheduled ||
        (state.unscheduled == bestUnscheduled &&
            state.objective < bestObjective)) {
      bestBlocks = state.blocks;
      bestObjective = state.objective;
      bestUnscheduled = state.unscheduled;
    }
    if (bestUnscheduled == 0) {
      return _result(
        problem: problem,
        status: RepairSearchStatus.feasible,
        blocks: bestBlocks,
        visited: visited,
      );
    }
    if (state.depth >= budget.maxRepairDepth) continue;

    final successors = problem.successors(state.blocks, state.depth);
    final canonical = <List<PlannedBlock>>[];
    final localSignatures = <String>{};
    for (final next in successors) {
      final blocks = _canonical(next);
      final signature = problem.signature(blocks);
      if (!localSignatures.add(signature)) continue;
      canonical.add(blocks);
    }
    canonical.sort(
      (a, b) => problem.signature(a).compareTo(problem.signature(b)),
    );
    for (final blocks in canonical.take(budget.maxBranchesPerState)) {
      final signature = problem.signature(blocks);
      if (!seen.add(signature)) continue;
      frontier.add(
        _State(
          blocks: blocks,
          depth: state.depth + 1,
          objective: problem.objectiveValue(blocks),
          unscheduled: problem.unscheduledMinutes(blocks),
          signature: signature,
        ),
      );
    }
  }

  final exhausted = frontier.isNotEmpty || visited >= budget.maxStates;
  return _result(
    problem: problem,
    status: exhausted && bestUnscheduled > 0
        ? RepairSearchStatus.budgetExhausted
        : (bestUnscheduled == 0
              ? RepairSearchStatus.feasible
              : RepairSearchStatus.hardInfeasible),
    blocks: bestBlocks,
    visited: visited,
  );
}

RepairSearchResult _result({
  required RepairSearchProblem problem,
  required RepairSearchStatus status,
  required List<PlannedBlock> blocks,
  required int visited,
}) => RepairSearchResult(
  status: status,
  bestBlocks: blocks,
  unscheduled: problem.unscheduledFor(blocks),
  visitedStates: visited,
  deterministicSignature: problem.signature(blocks),
);

int _compareStates(_State a, _State b) {
  final unscheduled = a.unscheduled.compareTo(b.unscheduled);
  if (unscheduled != 0) return unscheduled;
  final objective = a.objective.compareTo(b.objective);
  if (objective != 0) return objective;
  final depth = a.depth.compareTo(b.depth);
  if (depth != 0) return depth;
  return a.signature.compareTo(b.signature);
}

List<PlannedBlock> _canonical(List<PlannedBlock> blocks) =>
    [...blocks]..sort((a, b) => a.id.compareTo(b.id));

final class _State {
  const _State({
    required this.blocks,
    required this.depth,
    required this.objective,
    required this.unscheduled,
    required this.signature,
  });

  final List<PlannedBlock> blocks;
  final int depth;
  final int objective;
  final int unscheduled;
  final String signature;
}
