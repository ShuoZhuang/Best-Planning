/// 一个**可独立完成**的可见周期/任务片段（1.12.0 设计 §3、§5.2）。///
/// occurrence 表示一次承诺谱系；fragment 表示当前计划里的一段可见块。重排可以给同一
/// occurrence 建立多个 fragment，但“完成本次”只作用于所选 fragment，不联动兄弟块。
enum ExecutionFragmentState {
  planned,
  started,
  completed,
  withdrawn,
  superseded,
}

final class ExecutionFragment {
  ExecutionFragment({
    required this.fragmentId,
    required this.dataEpoch,
    required this.occurrenceId,
    required this.cycleId,
    required this.rootFragmentId,
    required this.sourceFragmentId,
    required this.planVersionId,
    required this.blockId,
    required this.plannedStartUtc,
    required this.plannedEndUtc,
    required this.plannedMinutes,
    required this.allocatedMicros,
    required this.completedMicros,
    required this.state,
    required this.createdAtUtc,
    required this.completedAtUtc,
    required this.revision,
  }) {
    if (!plannedStartUtc.isUtc || !plannedEndUtc.isUtc) {
      throw ArgumentError('Fragment bounds must be UTC.');
    }
    if (!plannedEndUtc.isAfter(plannedStartUtc)) {
      throw ArgumentError('plannedEndUtc must be after plannedStartUtc.');
    }
    if (plannedMinutes <= 0) {
      throw ArgumentError.value(plannedMinutes, 'plannedMinutes');
    }
    if (allocatedMicros < 0 || completedMicros < 0) {
      throw ArgumentError('Fragment micros must not be negative.');
    }
    if (completedMicros > allocatedMicros) {
      throw ArgumentError('completedMicros cannot exceed allocatedMicros.');
    }
    if (completedAtUtc != null) {
      if (!completedAtUtc!.isUtc) {
        throw ArgumentError.value(completedAtUtc, 'completedAtUtc');
      }
    }
    if (!createdAtUtc.isUtc) {
      throw ArgumentError.value(createdAtUtc, 'createdAtUtc');
    }
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    if (fragmentId.trim().isEmpty || rootFragmentId.trim().isEmpty) {
      throw ArgumentError('fragmentId and rootFragmentId must not be empty.');
    }
  }

  final String fragmentId;
  final String dataEpoch;
  final String occurrenceId;
  final String? cycleId;
  final String rootFragmentId;
  final String? sourceFragmentId;
  final String planVersionId;
  final String blockId;
  final DateTime plannedStartUtc;
  final DateTime plannedEndUtc;
  final int plannedMinutes;
  final int allocatedMicros;
  final int completedMicros;
  final ExecutionFragmentState state;
  final DateTime createdAtUtc;
  final DateTime? completedAtUtc;
  final int revision;

  bool get isFrozen =>
      state == ExecutionFragmentState.started ||
      state == ExecutionFragmentState.completed;

  bool get isCompleted => state == ExecutionFragmentState.completed;

  int get remainingMicros => allocatedMicros - completedMicros;

  int get remainingMinutes =>
      remainingMicros <= 0 ? 0 : (remainingMicros + 59999999) ~/ 60000000;

  ExecutionFragment copyWith({
    int? completedMicros,
    ExecutionFragmentState? state,
    DateTime? completedAtUtc,
    int? revision,
    String? rootFragmentId,
    String? sourceFragmentId,
  }) => ExecutionFragment(
    fragmentId: fragmentId,
    dataEpoch: dataEpoch,
    occurrenceId: occurrenceId,
    cycleId: cycleId,
    rootFragmentId: rootFragmentId ?? this.rootFragmentId,
    sourceFragmentId: sourceFragmentId ?? this.sourceFragmentId,
    planVersionId: planVersionId,
    blockId: blockId,
    plannedStartUtc: plannedStartUtc,
    plannedEndUtc: plannedEndUtc,
    plannedMinutes: plannedMinutes,
    allocatedMicros: allocatedMicros,
    completedMicros: completedMicros ?? this.completedMicros,
    state: state ?? this.state,
    createdAtUtc: createdAtUtc,
    completedAtUtc: completedAtUtc ?? this.completedAtUtc,
    revision: revision ?? this.revision,
  );

  /// 本次“完成本次”可以补足的声明量。
  ///
  /// 真实活动已经覆盖的部分不再重复补；返回 0 表示只改变 fragment 状态，不新增 credit
  /// （设计 §2.2 第 6 条、Task 8）。
  int declarableRemainingMicros({required int realCreditedMicros}) {
    final already = realCreditedMicros + completedMicros;
    final remaining = allocatedMicros - already;
    return remaining > 0 ? remaining : 0;
  }
}

/// 片段对周实例的有效进度贡献：真实活动与声明完成合计不超过承诺量。
int fragmentEffectiveMicros({
  required int realCreditedMicros,
  required int declaredMicros,
  required int allocatedMicros,
}) {
  if (realCreditedMicros < 0 || declaredMicros < 0 || allocatedMicros < 0) {
    throw ArgumentError('Micros must not be negative.');
  }
  final total = realCreditedMicros + declaredMicros;
  return total > allocatedMicros ? allocatedMicros : total;
}

/// 执行片段所属周期的身份投影。
final class FragmentCycleLink {
  const FragmentCycleLink({
    required this.fragmentId,
    required this.occurrenceId,
    required this.cycleId,
    required this.planVersionId,
    required this.blockId,
  });

  final String fragmentId;
  final String occurrenceId;
  final String? cycleId;
  final String planVersionId;
  final String blockId;
}

/// 判断一个块是否可创建 fragment；已开始/已完成块冻结（设计 §4.1、§5.2）。
bool canCreateFragmentForBlock({required bool blockAlreadyStarted}) =>
    !blockAlreadyStarted;

/// 周期块完成状态只由 fragment 决定，不再读取内部载体任务状态。
ExecutionFragmentState fragmentStateAfterCompletion({
  required int completedMicros,
  required int allocatedMicros,
}) => completedMicros >= allocatedMicros
    ? ExecutionFragmentState.completed
    : ExecutionFragmentState.started;

/// 供测试与迁移复用的稳定根片段 id。
String rootFragmentIdFor(String occurrenceId) => 'root:$occurrenceId';
