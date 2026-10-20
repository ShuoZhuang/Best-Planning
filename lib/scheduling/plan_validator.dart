import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

enum ConflictCode {
  insufficientCapacity,
  fixedEventOverlap,
  protectedTimeOverlap,
  lockedBlockMoved,
  blockOverlap,
  continuousBlockUnavailable,
  dailyLimitExceeded,
  scheduledDurationExceeded,
  minimumSleepConflict,
  staleProposal,
  invalidInput,

  /// **本次延后没有兑现**（用户第 72 轮）。
  ///
  /// **它只针对当前调整请求**，不是"方案里有任意未安排任务"：
  /// 部分计划本来就可能包含未安排任务（别的任务没排进去是常态）。
  /// 判定见 `evaluateAdjustmentFulfilment`。
  requestedAdjustmentUnsatisfied,

  /// **排程不变量被违反：有可用的合法时段，任务却最终排入 0 分钟**
  /// （1.8.0，「可见空闲却报容量不足」专项 §2.4 / §5 A13）。
  ///
  /// **为什么它必须是 blocker 而不是 warning**：容量不足是"事实如此"，用户可以腾时间后
  /// 带着缺口确认部分计划；而这一条是"排程器自己没排好"——把一份自己都解释不了的安排写进
  /// 用户的计划里，等于用一个错误覆盖已有的正确计划。因此：
  /// - `metrics.isFullyFeasible == false`；
  /// - 不允许自动应用，也不给"应用可安排部分"这个入口；
  /// - 预览不显示"可用时间不足"，只显示固定异常文案。
  ///
  /// **只能有一条用户可见问题**：引擎把它作为一条 blocker 放进 `conflicts`，
  /// 对应的 `UnscheduledTask` 主原因用 `unexplainedSchedulingFailure`，
  /// 预览层把两者**合成一条**呈现（见 `buildPreviewIssues`），不得 warning＋blocker 各显示一遍。
  schedulingInvariantViolation,
}

final class PlanningConflict {
  PlanningConflict({
    required this.code,
    this.taskId,
    this.shortageMinutes = 0,
    this.invalidInputReason,
    this.blockingInput,
    List<String> relatedEntityIds = const [],
    Map<String, Object?> details = const {},
  }) : relatedEntityIds = UnmodifiableListView(List.of(relatedEntityIds)),
       details = UnmodifiableMapView(Map.of(details));

  final ConflictCode code;
  final String? taskId;
  final int shortageMinutes;

  /// **结构化**的无效输入原因（1.8.0，2026-10-12 故障；冻结决策 §1.4）。
  ///
  /// **为什么要有它**：预览此前只能把 `invalidInput` 翻成一句"排程输入无效"，
  /// 用户看到之后不知道该改什么（截图里的第四件事）。数字继续放在 [details] 里，
  /// 这里只承载**分类**。
  ///
  /// 修复前所有片段长度问题共用一个 `details['reason'] = 'chunkLength'`，
  /// 于是"片段短于允许值"与"片段长于允许值"在界面上无从区分。
  final InvalidInputReason? invalidInputReason;

  /// **准入期**的阻断性输入原因：`ScheduleWindowAdmission.evidenceCode` 的稳定短码
  /// （1.8.0「可见空闲却报容量不足」专项 §1.7）。
  ///
  /// **为什么是 `String` 而不是一个枚举**：这个码由**应用层**的
  /// `classifyTaskForPlanningWindow` 产出，而本文件（排程层）**刻意不反过来依赖
  /// 应用层**——`scheduling/` 被 `application/` 依赖，反向依赖会形成环。
  /// 因此这里只承载"一个稳定的内部短码"，由装配层用
  /// `ScheduleWindowAdmission.evidenceCode` 填、由 `explanations.dart` 翻译。
  ///
  /// **它绝不显示给用户**：翻译链把每个已知短码换成一句可行动的文案，
  /// 未知短码回落到已有的"排程输入无效"。
  final String? blockingInput;

  final List<String> relatedEntityIds;
  final Map<String, Object?> details;
}

/// 一条[ConflictCode.invalidInput]的**唯一**原因（1.8.0，冻结决策 §1.4）。
///
/// 每个取值对应一句用户可据以行动的话（见 `explanations.planningConflictMessage`），
/// 因此**不得合并**："早于规划范围"要重算或改期，"片段短于允许值"要改最小片段设置。
enum InvalidInputReason {
  /// 块引用的任务不在这份输入的任务集合里（任务已被删除或不再参与排程）。
  unknownTask,

  /// 块的开始早于规划窗口起点，且它不是已锁定的进行中块。
  startsBeforePlanningWindow,

  /// 块的结束晚于规划窗口终点。
  endsAfterPlanningWindow,

  /// 片段短于允许值（可拆分任务的最小片段，或短余量宽免量的下限）。
  chunkBelowMinimum,

  /// 片段长于允许值（[SchedulableTask.maxChunkMinutes]）。
  chunkAboveMaximum,

  /// 片段没有落在 [PlanningRules.granularityMinutes] 的网格上。
  offGranularity,
}

/// **短余量的唯一合法时长**：`floor(requiredMinutes / granularity) * granularity`。
///
/// 返回 `0` 表示"凑不出任何合法片段"（剩余量不足一个粒度），调用方应如实报缺口。
///
/// **它为什么是一个独立函数**：短余量规则此前散在三处，各自实现、彼此不一致：
/// - `CandidateGenerator._candidateDurations` 用"钳到剩余量再向下取整"——**正确**；
/// - `PlanValidator` 无条件要求 `duration >= minChunkMinutes`——于是引擎能生成、
///   确认却必然失败（R4）；
/// - `ScheduleEngine` 的放置循环用 `leftover < minChunkMinutes` 直接拒绝——于是
///   "12 分钟排 10 分钟、缺 2 分钟"这种合法结果被拒成"整件事都排不下"。
///
/// 三处现在**都读这一个函数**（冻结决策 §1.4）。
int shortRemainderAllowance({
  required int requiredMinutes,
  required int granularityMinutes,
}) {
  assert(granularityMinutes > 0);
  if (requiredMinutes < granularityMinutes) return 0;
  return (requiredMinutes ~/ granularityMinutes) * granularityMinutes;
}

/// 一个计划片段是否**合法**（1.8.0，冻结决策 §1.4）。
///
/// **它必须与 `CandidateGenerator._candidateDurations` 成对阅读**：候选生成与最终校验
/// 是同一份规则的两个消费方，此前各自实现、彼此不一致，于是"引擎能生成、确认却必失败"。
/// 判定规则按 §1.4 逐条写在这里，**UI 与应用服务不得复制**（复制就会再次漂移）。
///
/// 规则：
/// - **连续任务**：只允许一个块，且总时长不超过 [SchedulableTask.requiredMinutes]；
///   **不套用**可拆分任务的 `minChunkMinutes` / `maxChunkMinutes`
///   （那正是 R5：合法的连续短任务被片段上下限误伤）。总时长本身仍必须落在粒度网格上。
/// - **可拆分任务**：
///   - `requiredMinutes < granularityMinutes` 时不伪造片段（候选生成已经返回空），
///     任何块都不合法；
///   - `requiredMinutes < minChunkMinutes` 时，唯一宽免时长是
///     [shortRemainderAllowance]（见那里的说明），且不得超过 `maxChunkMinutes`；
///   - 否则每个片段必须落在 `[minChunkMinutes, maxChunkMinutes]` 内；
///   - 任何情况下片段都不得超过 [SchedulableTask.requiredMinutes]（那是排多了）。
bool isValidPlannedChunk({
  required SchedulableTask task,
  required PlannedBlock block,
  required int granularityMinutes,
}) {
  assert(granularityMinutes > 0);
  final duration = block.durationMinutes;
  if (duration <= 0 || duration > task.requiredMinutes) return false;

  if (task.splitMode == TaskSplitMode.continuous) {
    // 连续任务：一次做完。片段上下限**不适用**（见上）。
    return true;
  }

  // 剩余量不足一个粒度：候选生成不会产出片段，因此任何片段都是伪造的。
  if (task.requiredMinutes < granularityMinutes) return false;

  if (task.requiredMinutes < task.minChunkMinutes) {
    // **短余量宽免**：只放宽到"粒度下的剩余量"，不是普遍放宽。
    final allowance = shortRemainderAllowance(
      requiredMinutes: task.requiredMinutes,
      granularityMinutes: granularityMinutes,
    );
    if (allowance <= 0) return false;
    // 宽免时长本身是"粒度下的剩余量"，因此它仍然必须落在粒度网格上。
    // **没有这一条，宽免会变成漏洞**：实测（1.8.0）一个 12 分钟任务的最小片段 30 时，
    // 局部改进会把 10 分钟的块换成 5 分钟的块——校验器接受了它，因为 5 <= 10。
    // 那不违反字面规则，但违反"宽免只针对凑不出最小片段的**最后一段**"这条本意：
    // 用户看到的是"还剩 12 分钟，计划里排了 5 分钟"。
    if (duration % granularityMinutes != 0) return false;
    return duration <= allowance;
  }

  return duration >= task.minChunkMinutes &&
      duration <= task.maxChunkMinutes &&
      duration % granularityMinutes == 0;
}

/// 一份计划里**同一任务的全部片段**违反的规则（计划 §2.2，冻结决策）。
///
/// **为什么需要集合校验**：`isValidPlannedChunk` 只看一个块，因此它无法回答
/// "这个低于最小片段的块是不是全任务唯一的最终短尾"（R4 的定义）。
/// 一个 12 分钟任务排 10 分钟合法，一个 100 分钟任务排 30+30+30+10 也合法；
/// 但 100 分钟任务排 30+30+20 时，那个 20 分钟块**不是**最终短尾——任务本来还排得下
/// 一个 30 分钟的常规片段，它是"过早"用了短尾宽免。只有看到同任务的完整块集合才能分辨。
enum ChunkSetViolation {
  none,

  /// 片段时长不为正。
  nonPositiveDuration,

  /// 片段没有落在 [PlanningRules.granularityMinutes] 的网格上。
  offGranularity,

  /// 可拆分片段长于 [SchedulableTask.maxChunkMinutes]。
  aboveMaximum,

  /// 短块出现得太早：去掉常规块后剩余量仍 >= `minChunkMinutes`，
  /// 说明任务还排得下一个常规片段，这一块不该用短尾宽免。
  belowMinimumBeforeTail,

  /// 同一任务出现了多于一个短块（宽免只针对唯一最终短尾）。
  multipleShortTails,

  /// 短块时长不等于唯一的合法短尾预算（[shortRemainderAllowance]）。
  shortTailMismatch,

  /// 同任务块的总时长超过了 `requiredMinutes`（排多了）。
  totalExceedsRequired,

  /// 连续任务被拆成了多个块。
  continuousTaskSplit,
}

/// [validatePlannedChunkSet] 的结果。
///
/// [blockId] 是**可归因**的那一块：逐块违规指向违规块本身，`multipleShortTails`
/// 指向时间上第二个短块，`continuousTaskSplit` 为 null（违规主体是整个任务）。
final class ChunkSetValidation {
  const ChunkSetValidation({required this.violation, this.blockId});

  final ChunkSetViolation violation;
  final String? blockId;
  bool get isValid => violation == ChunkSetViolation.none;
}

/// 校验**同一任务的全部片段**是否构成一份合法计划（计划 §2.2）。
///
/// 判定顺序固定（`blocks` 先按 `startUtc` 排序，同刻按 `id` 排序以保证确定性）：
///
/// 可拆分任务：
/// 1. 逐块：时长为正、落在粒度网格、不超过 `maxChunkMinutes`；
/// 2. 总时长不超过 `requiredMinutes`；
/// 3. `duration >= minChunkMinutes` 的块是**常规块**；
/// 4. 短块（低于 `minChunkMinutes`）最多一个，多于一个即 `multipleShortTails`；
/// 5. 没有短块 ⇒ 合法；
/// 6. 有短块时令 `regularTotal` 为全部常规块之和、`remaining = required - regularTotal`：
///    - `remaining >= minChunkMinutes` ⇒ `belowMinimumBeforeTail`（短尾用得太早）；
///    - 否则短块时长必须**严格等于**
///      `shortRemainderAllowance(remaining, granularity)`，否则 `shortTailMismatch`。
///
/// 第 7 条（任务总量不足一个粒度的余数）由上面两条自然覆盖：`remaining` 小于一个粒度时
/// 宽免量为 0，任何块都无法严格等于它 ⇒ 如实保留真实缺口，不伪造块。
///
/// **连续任务**不套用 `minChunkMinutes` / `maxChunkMinutes`（既有冻结决定，见
/// [isValidPlannedChunk]）：只检查时长为正、落在网格、不超过一个块、总量不超
/// `requiredMinutes`。
ChunkSetValidation validatePlannedChunkSet({
  required SchedulableTask task,
  required Iterable<PlannedBlock> blocks,
  required int granularityMinutes,
}) {
  assert(granularityMinutes > 0);
  final ordered = [...blocks]
    ..sort((a, b) {
      final startOrder = a.startUtc.compareTo(b.startUtc);
      if (startOrder != 0) return startOrder;
      return a.id.compareTo(b.id);
    });

  // **总量先于逐块形状判定**：这两条是**独立**的事实（"排多了"与"某一块形状非法"），
  // 计划 §2.2 也把"总时长不超过 requiredMinutes"单独列为第 2 条。若把总量检查放在
  // 逐块早退之后，一个"又超上限又排多了"的块集合就只会报形状问题，而"排多了"这件事
  // 会静默消失（既有回归用例 `报告每日上限和任务片段总量超出` 正是钉这一条的）。
  final total = ordered.fold<int>(
    0,
    (sum, block) => sum + block.durationMinutes,
  );
  if (total > task.requiredMinutes) {
    return const ChunkSetValidation(
      violation: ChunkSetViolation.totalExceedsRequired,
    );
  }

  for (final block in ordered) {
    final duration = block.durationMinutes;
    if (duration <= 0) {
      return ChunkSetValidation(
        violation: ChunkSetViolation.nonPositiveDuration,
        blockId: block.id,
      );
    }
    if (duration % granularityMinutes != 0) {
      return ChunkSetValidation(
        violation: ChunkSetViolation.offGranularity,
        blockId: block.id,
      );
    }
    // 连续任务**不检查** min/max：那是可拆分任务的片段上下限，
    // 套到"一次做完"的任务上会把合法的连续短任务误伤（R5）。
    if (task.splitMode == TaskSplitMode.splittable &&
        duration > task.maxChunkMinutes) {
      return ChunkSetValidation(
        violation: ChunkSetViolation.aboveMaximum,
        blockId: block.id,
      );
    }
  }

  if (task.splitMode == TaskSplitMode.continuous) {
    if (ordered.length > 1) {
      return const ChunkSetValidation(
        violation: ChunkSetViolation.continuousTaskSplit,
      );
    }
    return const ChunkSetValidation(violation: ChunkSetViolation.none);
  }

  final shortBlocks = [
    for (final block in ordered)
      if (block.durationMinutes < task.minChunkMinutes) block,
  ];
  if (shortBlocks.length > 1) {
    // 归因给**时间上第二个**短块：第一个短块本身可能仍然合法（它可能是正确的最终短尾），
    // 多出来的那一个是真正的违规者。
    return ChunkSetValidation(
      violation: ChunkSetViolation.multipleShortTails,
      blockId: shortBlocks[1].id,
    );
  }
  if (shortBlocks.isEmpty) {
    return const ChunkSetValidation(violation: ChunkSetViolation.none);
  }

  final regularTotal = ordered
      .where((block) => block.durationMinutes >= task.minChunkMinutes)
      .fold<int>(0, (sum, block) => sum + block.durationMinutes);
  final remaining = task.requiredMinutes - regularTotal;
  if (remaining >= task.minChunkMinutes) {
    return ChunkSetValidation(
      violation: ChunkSetViolation.belowMinimumBeforeTail,
      blockId: shortBlocks.single.id,
    );
  }
  final tailBudget = shortRemainderAllowance(
    requiredMinutes: remaining,
    granularityMinutes: granularityMinutes,
  );
  if (shortBlocks.single.durationMinutes != tailBudget) {
    return ChunkSetValidation(
      violation: ChunkSetViolation.shortTailMismatch,
      blockId: shortBlocks.single.id,
    );
  }
  return const ChunkSetValidation(violation: ChunkSetViolation.none);
}

final class PlanValidator {
  const PlanValidator(this._zones);

  final TimeZoneDatabase _zones;

  List<PlanningConflict> validate(
    ScheduleProblem problem,
    List<PlannedBlock> blocks,
  ) {
    final conflicts = <PlanningConflict>[];
    final tasks = {for (final task in problem.tasks) task.id: task};
    final granularity = problem.rules.granularityMinutes;
    // **进行中块的唯一例外表**（冻结决策 §1.4 的窗口边界条款）：
    // 只有"与 `problem.lockedBlocks` 中同 ID、同 task、同 range 的块完全一致、
    // 且 `start < window.start < end`"的那一块，才允许开始早于窗口。
    // 用同 ID + 同 range 的**完全一致**作判据，因此伪造的同 ID 块（换了位置）不成立。
    final ongoingLockedIds = <String>{
      for (final locked in problem.lockedBlocks)
        if (locked.startUtc.isBefore(problem.planningWindow.startUtc) &&
            locked.endUtc.isAfter(problem.planningWindow.startUtc))
          locked.id,
    };

    for (final block in blocks) {
      // ① 未知任务（片段长度由下面的集合校验判定，需要先知道任务是谁）。
      if (!tasks.containsKey(block.taskId)) {
        conflicts.add(
          _invalid(block: block, reason: InvalidInputReason.unknownTask),
        );
      }
      // ② 窗口起点。默认所有新块完全位于窗口内；唯一例外是"原位保留的进行中锁定块"。
      final isOngoingException =
          ongoingLockedIds.contains(block.id) &&
          problem.lockedBlocks.any(
            (locked) =>
                locked.id == block.id &&
                locked.taskId == block.taskId &&
                locked.range == block.range,
          );
      if (!problem.planningWindow.contains(block.startUtc)) {
        if (!(isOngoingException &&
            block.startUtc.isBefore(problem.planningWindow.startUtc))) {
          conflicts.add(
            _invalid(
              block: block,
              reason: InvalidInputReason.startsBeforePlanningWindow,
            ),
          );
        }
      }
      // ③ 窗口终点：**始终阻断**，进行中块也不例外。
      if (block.endUtc.isAfter(problem.planningWindow.endUtc)) {
        conflicts.add(
          _invalid(
            block: block,
            reason: InvalidInputReason.endsAfterPlanningWindow,
          ),
        );
      }
      // ④ 片段长度与网格改由**同任务块集合**统一判定（见下面 `validatePlannedChunkSet`）。
      // 逐块循环里只保留窗口、重叠与未知任务这几条与"集合"无关的事实。
      for (final fixed in problem.fixedIntervals) {
        if (block.range.overlaps(fixed.range)) {
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.fixedEventOverlap,
              taskId: block.taskId,
              relatedEntityIds: [block.id, fixed.id],
            ),
          );
        }
      }
      for (final protected in problem.protectedIntervals) {
        if (block.range.overlaps(protected.range)) {
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.protectedTimeOverlap,
              taskId: block.taskId,
              relatedEntityIds: [block.id, protected.id],
            ),
          );
        }
      }
    }

    final ordered = [...blocks]
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    for (var index = 1; index < ordered.length; index++) {
      if (ordered[index - 1].range.overlaps(ordered[index].range)) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.blockOverlap,
            relatedEntityIds: [ordered[index - 1].id, ordered[index].id],
          ),
        );
      }
    }

    final proposedById = {for (final block in blocks) block.id: block};
    for (final locked in problem.lockedBlocks) {
      final proposed = proposedById[locked.id];
      if (proposed == null ||
          proposed.taskId != locked.taskId ||
          proposed.range != locked.range) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.lockedBlockMoved,
            taskId: locked.taskId,
            relatedEntityIds: [locked.id],
          ),
        );
      }
    }

    // ── ⑤ 同任务片段集合（计划 §2.2，冻结决策）────────────────────────────────
    //
    // 逐块判据（`isValidPlannedChunk`）**不能**证明某个低于 min 的块是不是全任务唯一的
    // 最终短尾——那要看完整的块集合（R4）。因此这里按 `block.taskId` 分组，对每个真的
    // 有块的 task 调用一次 [validatePlannedChunkSet]，并把 violation 翻成**现有的结构化
    // code**。violation 枚举名绝不显示给用户：界面读的是
    // [PlanningConflict.code] / [PlanningConflict.invalidInputReason] / `details`。
    final blocksByTask = <String, List<PlannedBlock>>{};
    for (final block in blocks) {
      (blocksByTask[block.taskId] ??= []).add(block);
    }
    for (final task in problem.tasks) {
      final taskBlocks = blocksByTask[task.id];
      if (taskBlocks == null || taskBlocks.isEmpty) continue;
      final result = validatePlannedChunkSet(
        task: task,
        blocks: taskBlocks,
        granularityMinutes: granularity,
      );
      switch (result.violation) {
        case ChunkSetViolation.none:
          break;
        case ChunkSetViolation.nonPositiveDuration:
        case ChunkSetViolation.belowMinimumBeforeTail:
        case ChunkSetViolation.multipleShortTails:
        case ChunkSetViolation.shortTailMismatch:
          // 这四种的**处置是同一件事**："这一块短于允许值，且它不是唯一合法的最终短尾"
          // ⇒ 用户要改最小片段设置或改任务时长。因此共用 `chunkBelowMinimum`，
          // 与旧实现的键名保持一致（`_invalid` 会自己补 `details['reason']`）。
          conflicts.add(
            _invalid(
              block: _blockById(blocks, result.blockId),
              reason: InvalidInputReason.chunkBelowMinimum,
              details: {
                'durationMinutes': _durationOf(blocks, result.blockId),
                'minChunkMinutes': task.minChunkMinutes,
                'maxChunkMinutes': task.maxChunkMinutes,
                'requiredMinutes': task.requiredMinutes,
              },
            ),
          );
        case ChunkSetViolation.offGranularity:
          conflicts.add(
            _invalid(
              block: _blockById(blocks, result.blockId),
              reason: InvalidInputReason.offGranularity,
              details: {
                'durationMinutes': _durationOf(blocks, result.blockId),
                'granularityMinutes': granularity,
              },
            ),
          );
        case ChunkSetViolation.aboveMaximum:
          conflicts.add(
            _invalid(
              block: _blockById(blocks, result.blockId),
              reason: InvalidInputReason.chunkAboveMaximum,
              details: {
                'durationMinutes': _durationOf(blocks, result.blockId),
                'minChunkMinutes': task.minChunkMinutes,
                'maxChunkMinutes': task.maxChunkMinutes,
                'requiredMinutes': task.requiredMinutes,
              },
            ),
          );
        case ChunkSetViolation.totalExceedsRequired:
          final total = taskBlocks.fold<int>(
            0,
            (sum, block) => sum + block.durationMinutes,
          );
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.scheduledDurationExceeded,
              taskId: task.id,
              details: {
                'scheduledMinutes': total,
                'requiredMinutes': task.requiredMinutes,
              },
            ),
          );
        case ChunkSetViolation.continuousTaskSplit:
          final sorted = [...taskBlocks]
            ..sort((a, b) {
              final startOrder = a.startUtc.compareTo(b.startUtc);
              if (startOrder != 0) return startOrder;
              return a.id.compareTo(b.id);
            });
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.continuousBlockUnavailable,
              taskId: task.id,
              relatedEntityIds: [for (final block in sorted) block.id],
            ),
          );
      }
    }

    // 每日上限约束的是"可移动任务"时长：规则字段名为
    // dailyMovableTaskLimitMinutes，需求规格 8.4.1 也表述为"每日可移动任务上限，
    // 不含固定课程与会议"。已锁定块由用户固定、引擎不得移动，属于不可移动时长，
    // 因此不计入本上限。AvailabilityBuilder 同样先把锁定块从可用时间中扣除，
    // 再把当日预算花在剩余空闲上；若此处再把锁定块计入，同一段时长会被计算两次，
    // 产生虚假的 dailyLimitExceeded，并使 PlanApplicationService 把合法提案判为 invalid。
    // **逐日上限必须按块所在本地日查当天的策略**（DFR-027/031）：用窗口首日的
    // `problem.rules` 检查所有日期，会让"周末上限更高"被周一的上限判成超限，也会让
    // "周末上限更低"被放过。缺某天策略是装配不变量破坏，直接报输入错误，不偷偷套默认值。
    final minutesByLocalDate = <DateTime, int>{};
    for (final block in blocks) {
      if (block.locked) continue;
      final localDate = normalizeLocalDate(
        _zones.toLocal(block.startUtc, problem.timeZoneId),
      );
      minutesByLocalDate.update(
        localDate,
        (value) => value + block.durationMinutes,
        ifAbsent: () => block.durationMinutes,
      );
    }
    for (final entry in minutesByLocalDate.entries) {
      final policy = problem.dailyPolicies[entry.key];
      if (policy == null) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.invalidInput,
            blockingInput: 'missingDailyPolicy',
            details: {
              'localDate':
                  '${entry.key.year}-${entry.key.month}-${entry.key.day}',
            },
          ),
        );
        continue;
      }
      final limit = policy.resolvedRules.dailyMovableTaskLimitMinutes;
      if (entry.value > limit) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.dailyLimitExceeded,
            details: {
              'localDate':
                  '${entry.key.year}-${entry.key.month}-${entry.key.day}',
              'scheduledMinutes': entry.value,
              'limitMinutes': limit,
            },
          ),
        );
      }
    }
    return List.unmodifiable(conflicts);
  }

  /// 按 id 取回那个被归因的块。
  ///
  /// [validatePlannedChunkSet] 的逐块违规**一定**带上 `blockId`，因此查不到就是
  /// "校验器与调用方看的不同一份块集合"这种程序错误，用一个 `assert` 与一处兜底表达，
  /// 而不是静默换一块去归因（那会把原因指到无辜的块上）。
  static PlannedBlock _blockById(List<PlannedBlock> blocks, String? blockId) {
    final found = blocks.where((block) => block.id == blockId).firstOrNull;
    assert(found != null, '片段集合校验报告的 blockId=$blockId 不在块集合里');
    return found ?? blocks.first;
  }

  static int _durationOf(List<PlannedBlock> blocks, String? blockId) =>
      _blockById(blocks, blockId).durationMinutes;

  /// 构造一条**带结构化原因**的 `invalidInput`。
  ///
  /// 数字放 [PlanningConflict.details]，分类放
  /// [PlanningConflict.invalidInputReason] —— 因为界面要按分类说不同的话。
  static PlanningConflict _invalid({
    required PlannedBlock block,
    required InvalidInputReason reason,
    Map<String, Object?> details = const {},
  }) => PlanningConflict(
    code: ConflictCode.invalidInput,
    taskId: block.taskId,
    invalidInputReason: reason,
    relatedEntityIds: [block.id],
    // `reason` 同时留一份在 details 里：既有调用方按 `details['reason']` 取值
    // （例如调整兑现校验与失败摘要），去掉它会静默变成 null。
    // 它的值是**枚举名**，不是自由文本。
    details: {'reason': reason.name, ...details},
  );
}
