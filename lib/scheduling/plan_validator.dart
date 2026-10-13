import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
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
      // ① 未知任务。
      final task = tasks[block.taskId];
      if (task == null) {
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
      // ④ 片段长度与网格：与候选生成共用同一个纯函数判据。
      if (task != null) {
        // **网格单独报一次**（原因不同、处置不同）：候选生成按粒度递进，产物必然对齐；
        // 这里挡的是外部构造的块（例如注入的非法提案）。
        if (block.durationMinutes % granularity != 0) {
          conflicts.add(
            _invalid(
              block: block,
              reason: InvalidInputReason.offGranularity,
              details: {
                'durationMinutes': block.durationMinutes,
                'granularityMinutes': granularity,
              },
            ),
          );
        }
        if (!isValidPlannedChunk(
          task: task,
          block: block,
          granularityMinutes: granularity,
        )) {
          // **已经因网格被拒时不再补一条长度原因**：同一个块报两条无效输入会让
          // 预览把同一件事说两遍（正是本批次要消灭的形态）。长度原因留给
          // "落在网格上、但超出允许区间"的那些块。
          if (block.durationMinutes % granularity == 0) {
            conflicts.add(
              _invalid(
                block: block,
                reason: block.durationMinutes < task.minChunkMinutes
                    ? InvalidInputReason.chunkBelowMinimum
                    : InvalidInputReason.chunkAboveMaximum,
                details: {
                  'durationMinutes': block.durationMinutes,
                  'minChunkMinutes': task.minChunkMinutes,
                  'maxChunkMinutes': task.maxChunkMinutes,
                  'requiredMinutes': task.requiredMinutes,
                },
              ),
            );
          }
        }
      }
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

    for (final task in problem.tasks) {
      final taskBlocks = blocks
          .where((block) => block.taskId == task.id)
          .toList();
      final total = taskBlocks.fold<int>(
        0,
        (sum, block) => sum + block.durationMinutes,
      );
      if (task.splitMode == TaskSplitMode.continuous && taskBlocks.length > 1) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.continuousBlockUnavailable,
            taskId: task.id,
            relatedEntityIds: taskBlocks.map((block) => block.id).toList(),
          ),
        );
      }
      if (total > task.requiredMinutes) {
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
      }
      // **片段长度 / 连续任务的判据已上移到逐块循环**（1.8.0，冻结决策 §1.4）：
      // 这里此前无条件套用 `minChunkMinutes` / `maxChunkMinutes`，于是
      //   ① 15 分钟的可拆分任务被判 invalid（而候选生成明确允许它），
      //   ② 连续任务被片段上下限误伤（R5）。
      // 两处判据现在**是同一个纯函数**（`isValidPlannedChunk`），
      // 且只对"这个块所属的任务"生效，因此不再在这里重复。
    }

    // 每日上限约束的是"可移动任务"时长：规则字段名为
    // dailyMovableTaskLimitMinutes，需求规格 8.4.1 也表述为"每日可移动任务上限，
    // 不含固定课程与会议"。已锁定块由用户固定、引擎不得移动，属于不可移动时长，
    // 因此不计入本上限。AvailabilityBuilder 同样先把锁定块从可用时间中扣除，
    // 再把当日预算花在剩余空闲上；若此处再把锁定块计入，同一段时长会被计算两次，
    // 产生虚假的 dailyLimitExceeded，并使 PlanApplicationService 把合法提案判为 invalid。
    final minutesByLocalDate = <String, int>{};
    for (final block in blocks) {
      if (block.locked) continue;
      final local = _zones.toLocal(block.startUtc, problem.timeZoneId);
      final key = '${local.year}-${local.month}-${local.day}';
      minutesByLocalDate.update(
        key,
        (value) => value + block.durationMinutes,
        ifAbsent: () => block.durationMinutes,
      );
    }
    for (final entry in minutesByLocalDate.entries) {
      if (entry.value > problem.rules.dailyMovableTaskLimitMinutes) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.dailyLimitExceeded,
            details: {
              'localDate': entry.key,
              'scheduledMinutes': entry.value,
              'limitMinutes': problem.rules.dailyMovableTaskLimitMinutes,
            },
          ),
        );
      }
    }

    return List.unmodifiable(conflicts);
  }

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
