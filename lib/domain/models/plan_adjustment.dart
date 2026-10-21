import 'dart:collection';

import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 标题未知时的稳定展示文案（DFR-032）。
///
/// 全部失败路径都以它为兜底：**永远不显示裸 UUID**，也**不用占位文案覆盖已有标题**。
const String unnamedTaskTitle = '未命名任务';

/// 一次块级调整的种类。1.11.0 只有"延后本次"。
enum PlanAdjustmentKind { defer }

/// 调整操作的状态（计划 Task 2 Step 2）。
enum PlanAdjustmentStatus {
  active,
  generating,
  previewReady,
  applying,
  applied,
  cancelled,
  failed,
  stale,
  expired,
}

extension PlanAdjustmentStatusX on PlanAdjustmentStatus {
  /// 终态不可再次转换（`failed` 例外：它只能按原意重生，见 [allowedTransitions]）。
  bool get isTerminal => switch (this) {
    PlanAdjustmentStatus.applied ||
    PlanAdjustmentStatus.cancelled ||
    PlanAdjustmentStatus.stale ||
    PlanAdjustmentStatus.expired => true,
    _ => false,
  };

  /// 尚未进入应用阶段的"活"状态（可取消、可过期、可重新生成）。
  bool get isOpen => switch (this) {
    PlanAdjustmentStatus.active ||
    PlanAdjustmentStatus.generating ||
    PlanAdjustmentStatus.previewReady => true,
    _ => false,
  };
}

/// 调整失败的稳定原因码（计划 Task 2 Step 2）。
///
/// 这些码是**业务判断**：界面据此给出用户可理解的原因，日志只写码与数量区间。
/// 它们同时也是持久化用的稳定字符串（数据库 CHECK 约束逐项列举，见 schema 11）。
enum PlanAdjustmentFailureCode {
  targetMissing,
  targetChanged,
  targetIneligible,
  basePlanChanged,
  previewExpired,
  tokenMismatch,
  noLegalSlot,
  deadlineExceeded,
  disallowedWeekday,
  taskDailyLimitReached,
  globalDailyLimitReached,
  requiredBreakUnavailable,
  fixedOrProtectedConflict,
  searchBudgetExhausted,
  invariantViolation,
  fulfilmentMissing,
  fulfilmentDurationMismatch,
  concurrentModification,
}

/// 调整的并发身份：`adjustmentId + revision + basePlanVersionId`。
///
/// 所有 CAS 都要求这三个值逐项匹配；只带 `adjustmentId` 会让"旧 revision 的
/// 迟到请求"覆盖新状态。
final class PlanAdjustmentToken {
  const PlanAdjustmentToken({
    required this.adjustmentId,
    required this.revision,
    required this.basePlanVersionId,
  });

  final String adjustmentId;
  final int revision;
  final String basePlanVersionId;

  @override
  bool operator ==(Object other) =>
      other is PlanAdjustmentToken &&
      adjustmentId == other.adjustmentId &&
      revision == other.revision &&
      basePlanVersionId == other.basePlanVersionId;

  @override
  int get hashCode => Object.hash(adjustmentId, revision, basePlanVersionId);

  @override
  String toString() => 'PlanAdjustmentToken(revision: $revision)'; // 不打印实例 id（日志脱敏）
}

/// 不可变、可持久化的一次块级调整（计划 Task 2 Step 2）。
///
/// **为什么它必须是一个持久对象而不是内存字段**：修复前的「延后本次」只活在
/// `PendingMoveDrafts._adjustment` 里，生成路径的 `finally` 会把它清掉，于是
/// 生成结束之后再也无法确认、无法重生、无法取消，也无法在重启后恢复
/// （DFR-001/003/004/018）。身份、意图、基线、目标快照、过期时间都在这里。
///
/// 所有时间字段必须是 UTC；`sourceEndUtc > sourceStartUtc`、`notBeforeUtc > sourceStartUtc`
/// 是硬不变量——它们一旦被违反，"延后"就没有任何意义。
final class PlanAdjustment {
  PlanAdjustment({
    required String adjustmentId,
    required this.kind,
    required String targetBlockId,
    required String targetTaskId,
    required String targetTitleSnapshot,
    required String basePlanVersionId,
    required DateTime sourceStartUtc,
    required DateTime sourceEndUtc,
    required DateTime notBeforeUtc,
    required String timeZoneId,
    required int requestedAmount,
    required this.requestedUnit,
    required this.status,
    required DateTime createdAtUtc,
    required DateTime expiresAtUtc,
    required int revision,
    Iterable<String> targetSiblingBlockIds = const [],
    String? previewId,
    String? appliedPlanVersionId,
    this.failureCode,
  }) : adjustmentId = _requireText(adjustmentId, 'adjustmentId'),
       targetBlockId = _requireText(targetBlockId, 'targetBlockId'),
       targetTaskId = _requireText(targetTaskId, 'targetTaskId'),
       targetTitleSnapshot = _normalizeTitle(targetTitleSnapshot),
       basePlanVersionId = _requireText(basePlanVersionId, 'basePlanVersionId'),
       sourceStartUtc = _requireUtc(sourceStartUtc, 'sourceStartUtc'),
       sourceEndUtc = _requireUtc(sourceEndUtc, 'sourceEndUtc'),
       notBeforeUtc = _requireUtc(notBeforeUtc, 'notBeforeUtc'),
       createdAtUtc = _requireUtc(createdAtUtc, 'createdAtUtc'),
       expiresAtUtc = _requireUtc(expiresAtUtc, 'expiresAtUtc'),
       timeZoneId = _requireText(timeZoneId, 'timeZoneId'),
       requestedAmount = _requireAmount(requestedAmount),
       revision = _requireRevision(revision),
       targetSiblingBlockIds = UnmodifiableSetView(
         Set<String>.of(
           targetSiblingBlockIds.where((id) => id.trim().isNotEmpty),
         ),
       ),
       previewId = _optionalText(previewId, 'previewId'),
       appliedPlanVersionId = _optionalText(
         appliedPlanVersionId,
         'appliedPlanVersionId',
       ) {
    if (!sourceEndUtc.isAfter(sourceStartUtc)) {
      throw ArgumentError(
        'sourceEndUtc（${sourceEndUtc.toIso8601String()}）必须晚于 '
        'sourceStartUtc（${sourceStartUtc.toIso8601String()}）。',
      );
    }
    if (!notBeforeUtc.isAfter(sourceStartUtc)) {
      throw ArgumentError(
        '延后的下界必须晚于源块开始：notBeforeUtc=${notBeforeUtc.toIso8601String()}，'
        'sourceStartUtc=${sourceStartUtc.toIso8601String()}。',
      );
    }
    if (!expiresAtUtc.isAfter(createdAtUtc)) {
      throw ArgumentError('expiresAtUtc 必须晚于 createdAtUtc。');
    }
    if (requestedAmount <= 0) {
      throw ArgumentError.value(requestedAmount, 'requestedAmount', '延后量必须为正');
    }
    if (status == PlanAdjustmentStatus.previewReady && previewId == null) {
      throw ArgumentError('previewReady 状态必须带 previewId。');
    }
    if (status == PlanAdjustmentStatus.applied &&
        appliedPlanVersionId == null) {
      throw ArgumentError('applied 状态必须带 appliedPlanVersionId。');
    }
  }

  final String adjustmentId;
  final PlanAdjustmentKind kind;

  /// 被延后的**已确认计划块** id（`schedule_blocks.id`，不是任务 id）。
  final String targetBlockId;

  /// 目标块所属任务。**只用于读取任务事实**，延后本身绝不修改任务级字段
  /// （`availableFromUtc` / deadline / 完成状态），见 DFR-034。
  final String targetTaskId;

  /// 创建时保存的标题快照（DFR-032）：任务被删除或改名后，预览与错误仍显示用户
  /// 认识的那个标题，而不是裸 UUID 或"未命名任务"。
  final String targetTitleSnapshot;

  /// 创建调整时**当前确认计划**的版本 id。生成、确认、撤销都以它为基线。
  final String basePlanVersionId;

  /// 源块快照（创建时的确认计划事实，DFR-005：不信界面缓存）。
  final DateTime sourceStartUtc;
  final DateTime sourceEndUtc;

  /// 延后下界：新开始时间**不早于**这个时刻（是下界，不是精确点）。
  final DateTime notBeforeUtc;

  /// 事项自己的 IANA 时区。天数换算、DST 解析、逐日策略都按它。
  final String timeZoneId;

  final int requestedAmount;
  final DeferUnit requestedUnit;

  final PlanAdjustmentStatus status;

  final DateTime createdAtUtc;
  final DateTime expiresAtUtc;

  /// 调整自己的修订号。重生、重新读取快照都会 +1；旧 revision 的迟到请求被 CAS 拒绝。
  final int revision;

  /// 目标块所属任务的其他已确认块 id。
  ///
  /// 记录它们是为了让"只移动目标 lineage、不牵连同任务兄弟块"（DFR-034）成为
  /// 可校验的显式事实，而不是靠装配层临场推断。集合不可变（DFR-030）。
  final Set<String> targetSiblingBlockIds;

  final String? previewId;
  final String? appliedPlanVersionId;
  final PlanAdjustmentFailureCode? failureCode;

  TimeRange get sourceRange =>
      TimeRange(startUtc: sourceStartUtc, endUtc: sourceEndUtc);

  int get sourceDurationMinutes =>
      sourceEndUtc.difference(sourceStartUtc).inMinutes;

  /// 可以被自动应用的前提：仍处于可应用的活状态。
  bool get isActionable => status == PlanAdjustmentStatus.previewReady;

  PlanAdjustmentToken get token => PlanAdjustmentToken(
    adjustmentId: adjustmentId,
    revision: revision,
    basePlanVersionId: basePlanVersionId,
  );

  bool isExpiredAt(DateTime nowUtc) => !nowUtc.isBefore(expiresAtUtc);

  /// 唯一允许的状态转换表（计划 Task 2 Step 3）。
  static const Map<PlanAdjustmentStatus, Set<PlanAdjustmentStatus>>
  allowedTransitions = {
    PlanAdjustmentStatus.active: {
      PlanAdjustmentStatus.generating,
      PlanAdjustmentStatus.cancelled,
      PlanAdjustmentStatus.stale,
      PlanAdjustmentStatus.expired,
      PlanAdjustmentStatus.failed,
    },
    PlanAdjustmentStatus.generating: {
      PlanAdjustmentStatus.previewReady,
      PlanAdjustmentStatus.cancelled,
      PlanAdjustmentStatus.stale,
      PlanAdjustmentStatus.expired,
      PlanAdjustmentStatus.failed,
    },
    PlanAdjustmentStatus.previewReady: {
      PlanAdjustmentStatus.generating,
      PlanAdjustmentStatus.applying,
      PlanAdjustmentStatus.cancelled,
      PlanAdjustmentStatus.stale,
      PlanAdjustmentStatus.expired,
      PlanAdjustmentStatus.failed,
    },
    PlanAdjustmentStatus.applying: {
      PlanAdjustmentStatus.applied,
      PlanAdjustmentStatus.failed,
      PlanAdjustmentStatus.stale,
    },
    PlanAdjustmentStatus.applied: {},
    PlanAdjustmentStatus.cancelled: {},
    // 失败**只能**重生（`failed -> generating`，计划 Task 2 Step 3），不能直接
    // 进入应用或其它终态；否则一次"预算耗尽"会被误当成可确认的预览。
    PlanAdjustmentStatus.failed: {PlanAdjustmentStatus.generating},
    PlanAdjustmentStatus.stale: {},
    PlanAdjustmentStatus.expired: {},
  };

  bool canTransitionTo(PlanAdjustmentStatus to) =>
      allowedTransitions[status]?.contains(to) ?? false;

  /// 返回转换后的新对象；非法转换抛 [StateError]。
  ///
  /// 模型层只做状态机与字段一致性，**不写数据库**：事件序列、preview supersede
  /// 和事务边界都属于仓储/服务（Task 3、5、10）。
  PlanAdjustment transitionTo({
    required PlanAdjustmentStatus to,
    required DateTime occurredAtUtc,
    String? previewId,
    String? appliedPlanVersionId,
    PlanAdjustmentFailureCode? failureCode,
    bool incrementRevision = false,
  }) {
    if (!canTransitionTo(to)) {
      throw StateError('非法的调整状态转换：${status.name} -> ${to.name}');
    }
    if (!occurredAtUtc.isUtc) {
      throw ArgumentError.value(occurredAtUtc, 'occurredAtUtc', 'Must be UTC.');
    }
    if (to == PlanAdjustmentStatus.previewReady && previewId == null) {
      throw ArgumentError('进入 previewReady 必须给出 previewId。');
    }
    if (to == PlanAdjustmentStatus.applied && appliedPlanVersionId == null) {
      throw ArgumentError('进入 applied 必须给出 appliedPlanVersionId。');
    }
    if (to == PlanAdjustmentStatus.failed && failureCode == null) {
      throw ArgumentError('进入 failed 必须给出 failureCode。');
    }
    return copyWith(
      status: to,
      revision: incrementRevision ? revision + 1 : revision,
      // 重生时旧的 preview 已经 supersede：从这里开始不再指向它。
      previewId: previewId,
      clearPreview: to == PlanAdjustmentStatus.generating && previewId == null,
      appliedPlanVersionId: appliedPlanVersionId,
      failureCode: to == PlanAdjustmentStatus.failed ? failureCode : null,
      clearFailure: to != PlanAdjustmentStatus.failed,
    );
  }

  PlanAdjustment copyWith({
    PlanAdjustmentStatus? status,
    int? revision,
    DateTime? expiresAtUtc,
    String? previewId,
    String? appliedPlanVersionId,
    PlanAdjustmentFailureCode? failureCode,
    bool clearPreview = false,
    bool clearFailure = false,
    bool clearAppliedPlan = false,
  }) => PlanAdjustment(
    adjustmentId: adjustmentId,
    kind: kind,
    targetBlockId: targetBlockId,
    targetTaskId: targetTaskId,
    targetTitleSnapshot: targetTitleSnapshot,
    basePlanVersionId: basePlanVersionId,
    sourceStartUtc: sourceStartUtc,
    sourceEndUtc: sourceEndUtc,
    notBeforeUtc: notBeforeUtc,
    timeZoneId: timeZoneId,
    requestedAmount: requestedAmount,
    requestedUnit: requestedUnit,
    status: status ?? this.status,
    createdAtUtc: createdAtUtc,
    expiresAtUtc: expiresAtUtc ?? this.expiresAtUtc,
    revision: revision ?? this.revision,
    targetSiblingBlockIds: targetSiblingBlockIds,
    previewId: clearPreview ? null : (previewId ?? this.previewId),
    appliedPlanVersionId: clearAppliedPlan
        ? null
        : (appliedPlanVersionId ?? this.appliedPlanVersionId),
    failureCode: clearFailure ? null : (failureCode ?? this.failureCode),
  );

  @override
  String toString() =>
      // 有意不打印标题、taskId、blockId、previewId：诊断日志只写稳定码与修订号。
      'PlanAdjustment(kind: ${kind.name}, status: ${status.name}, '
      'revision: $revision, unit: ${requestedUnit.name}, '
      'amount: $requestedAmount)';
}

/// 一次状态转换的审计事件（计划 Task 3 Step 2 的 `PlanAdjustmentEvents`）。
final class PlanAdjustmentEvent {
  const PlanAdjustmentEvent({
    required this.adjustmentId,
    required this.sequence,
    required this.fromStatus,
    required this.toStatus,
    required this.revision,
    required this.occurredAtUtc,
    this.reasonCode,
  });

  final String adjustmentId;
  final int sequence;
  final PlanAdjustmentStatus fromStatus;
  final PlanAdjustmentStatus toStatus;
  final int revision;
  final DateTime occurredAtUtc;
  final PlanAdjustmentFailureCode? reasonCode;

  @override
  String toString() =>
      'PlanAdjustmentEvent(#$sequence ${fromStatus.name}->${toStatus.name}, '
      'revision: $revision)';
}

String _requireText(String value, String name) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw ArgumentError.value(value, name, '不能为空');
  return trimmed;
}

String _normalizeTitle(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? unnamedTaskTitle : trimmed;
}

String? _optionalText(String? value, String name) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw ArgumentError.value(value, name, '为空时应传 null');
  return trimmed;
}

DateTime _requireUtc(DateTime value, String name) {
  if (!value.isUtc) {
    throw ArgumentError.value(value, name, 'Must be UTC.');
  }
  return value;
}

int _requireRevision(int revision) {
  if (revision < 1) throw ArgumentError.value(revision, 'revision', '必须 ≥ 1');
  return revision;
}

int _requireAmount(int amount) {
  if (amount <= 0) throw ArgumentError.value(amount, 'requestedAmount', '必须为正');
  return amount;
}
