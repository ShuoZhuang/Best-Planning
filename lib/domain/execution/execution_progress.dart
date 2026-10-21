import 'package:personal_planner/domain/execution/execution_models.dart';

/// 精确进度算式（规范 §10.2、§22.2）。
///
/// 所有活动量都是**非负整数微秒**：禁止浮点累计，也不允许先把每段取整再相加。
/// 取整只发生在"交给排程器"的边界上，并且固定向上。

/// 一条有效投入在进度检查点算法里的最小输入。
final class ExecutionProgressCredit {
  const ExecutionProgressCredit({
    required this.firstAcceptedSequence,
    required this.durationMicros,
    required this.targetKind,
    required this.targetId,
    this.effective = true,
  }) : assert(durationMicros > 0);

  /// 首次入账时由数据库写事务分配的序号。更正保留它（规范 §10.2）。
  final int firstAcceptedSequence;
  final int durationMicros;
  final ExecutionTargetKind targetKind;
  final String targetId;
  final bool effective;
}

/// 进度投影：人工剩余锚点 + 锚点之后的有效投入。
final class ExecutionProgressProjection {
  const ExecutionProgressProjection({
    required this.anchorRemainingMicros,
    required this.anchorSequence,
    required this.eligibleCreditedMicros,
    required this.remainingMicros,
    required this.schedulingMinutes,
  });

  final int anchorRemainingMicros;
  final int anchorSequence;
  final int eligibleCreditedMicros;
  final int remainingMicros;
  final int schedulingMinutes;

  /// 精确剩余（秒/微秒）用于展示；排程使用 [schedulingMinutes]。
  int get remainingSeconds => remainingMicros ~/ 1000000;
}

/// 计算当前精确剩余（规范 §10.2）。
///
/// ```text
/// eligibleCredits = 首次入账序号 > anchorSequence 的有效投入
/// remainingMicros = max(0, anchorRemainingMicros - sum(eligibleCredits))
/// ```
///
/// **只需要一个序号边界**：比"按时间差／总累计分钟差"更可靠。晚补记是否已包含在
/// 上次人工修正里，由界面明确询问并写入记录版本，不能靠发生时间猜测。
int executionRemainingMicros({
  required int anchorRemainingMicros,
  required int anchorSequence,
  required Iterable<ExecutionProgressCredit> credits,
}) {
  if (anchorRemainingMicros < 0) {
    throw ArgumentError.value(anchorRemainingMicros, 'anchorRemainingMicros');
  }
  var credited = 0;
  for (final credit in credits) {
    if (!credit.effective) continue;
    if (credit.firstAcceptedSequence > anchorSequence) {
      credited += credit.durationMicros;
    }
  }
  final remaining = anchorRemainingMicros - credited;
  return remaining < 0 ? 0 : remaining;
}

/// 排程使用**向上取整**后的分钟：还剩 30 秒也必须排 1 分钟（规范 §10.2、EXE-46）。
int executionSchedulingMinutes(int remainingMicros) {
  if (remainingMicros <= 0) return 0;
  const microsPerMinute = 60 * 1000000;
  return (remainingMicros + microsPerMinute - 1) ~/ microsPerMinute;
}

/// 精确剩余的展示分钟（向下），只用于"已投入/剩余"这类不需要保证排程的文案。
int executionDisplayMinutes(int micros) => micros ~/ (60 * 1000000);

/// 当前投影（含精确值、排程分钟和参与计算的投入和）。
ExecutionProgressProjection executionProjectProgress({
  required int anchorRemainingMicros,
  required int anchorSequence,
  required Iterable<ExecutionProgressCredit> credits,
}) {
  var credited = 0;
  for (final credit in credits) {
    if (!credit.effective) continue;
    if (credit.firstAcceptedSequence > anchorSequence) {
      credited += credit.durationMicros;
    }
  }
  final remaining = anchorRemainingMicros - credited;
  final clamped = remaining < 0 ? 0 : remaining;
  return ExecutionProgressProjection(
    anchorRemainingMicros: anchorRemainingMicros,
    anchorSequence: anchorSequence,
    eligibleCreditedMicros: credited,
    remainingMicros: clamped,
    schedulingMinutes: executionSchedulingMinutes(clamped),
  );
}

/// 把一段真实投入拆给同一任务的多个执行实例时，保证交叠微秒最多入账一次。
///
/// [segments] 是有效活动段（半开区间），[allocations] 是已入账量。返回溢出微秒；
/// 0 表示守恒。跨行不变量由同一写事务里的查询与验证完成，不假装 SQLite 的
/// 行级 CHECK 能覆盖它（规范 §19.2）。
int executionAllocationOverflowMicros({
  required Iterable<ExecutionActivitySegment> segments,
  required Iterable<ExecutionCreditAllocation> allocations,
}) {
  final durationBySegment = <String, int>{
    for (final segment in segments) segment.segmentId: segment.durationMicros,
  };
  final allocatedBySegment = <String, int>{};
  for (final allocation in allocations) {
    allocatedBySegment.update(
      allocation.segmentId,
      (value) => value + allocation.amountMicros,
      ifAbsent: () => allocation.amountMicros,
    );
  }
  var overflow = 0;
  for (final entry in allocatedBySegment.entries) {
    final duration = durationBySegment[entry.key];
    if (duration == null) {
      // 未知活动段的分配是孤立事实；按全部溢出处理，让事务拒绝提交。
      overflow += entry.value;
      continue;
    }
    final extra = entry.value - duration;
    if (extra > 0) overflow += extra;
  }
  return overflow;
}

/// 精确的实例份额：已入账 + 未完成 + 明确减少 = 原始分配（规范 §5.2、§22.2）。
bool executionShareIsConserved({
  required int allocatedMicros,
  required int creditedMicros,
  required int remainingAllocationMicros,
  required int explicitlyReducedMicros,
}) {
  return executionShareDeltaMicros(
        allocatedMicros: allocatedMicros,
        creditedMicros: creditedMicros,
        remainingAllocationMicros: remainingAllocationMicros,
        explicitlyReducedMicros: explicitlyReducedMicros,
      ) ==
      0;
}

/// 恢复目标：所选执行实例的未做份额，并受任务总剩余限制（规范 §9.3）。
///
/// 例如 90 分钟任务、两段各 45 分钟，本次已做 5 分钟：本次恢复份额最多 40 分钟，
/// 不能把整个任务的 85 分钟都塞进当前片段。
int executionRecoveryTargetMicros({
  required int occurrenceRemainingMicros,
  required int taskRemainingMicros,
  int? requestedMicros,
}) {
  if (occurrenceRemainingMicros < 0 || taskRemainingMicros < 0) {
    throw ArgumentError('Remaining amounts must not be negative.');
  }
  final limit = occurrenceRemainingMicros < taskRemainingMicros
      ? occurrenceRemainingMicros
      : taskRemainingMicros;
  if (requestedMicros == null) return limit;
  if (requestedMicros < 0) {
    throw ArgumentError.value(requestedMicros, 'requestedMicros');
  }
  return requestedMicros < limit ? requestedMicros : limit;
}

/// 已投入超过分配份额时，尚未执行片段需要缩减的微秒。
///
/// **不产生负剩余**：超额投入由界面展示局部调整或明确冲突，不能静默制造负数
/// （规范 §9.3、EXE-53）。
int executionOverdrawnMicros({
  required int allocatedMicros,
  required int creditedMicros,
}) {
  final overdrawn = creditedMicros - allocatedMicros;
  return overdrawn > 0 ? overdrawn : 0;
}

/// 一个真实的短会话：用户明确选择"就做这几分钟"。
///
/// 它不是引擎生成的计划块，因此不要求满足任务的最短连续长度（规范 §7.3 第 5 条、
/// §9.3、EXE-51）。低于一分钟的真实投入仍然保存。
int executionRealShortSessionMicros({
  required DateTime nowUtc,
  required DateTime hardBoundaryUtc,
  int? requestedMicros,
}) {
  if (!nowUtc.isUtc || !hardBoundaryUtc.isUtc) {
    throw ArgumentError('Both instants must be UTC.');
  }
  final available = hardBoundaryUtc.difference(nowUtc).inMicroseconds;
  final cap = available < 0 ? 0 : available;
  if (requestedMicros == null) return cap;
  if (requestedMicros < 0) {
    throw ArgumentError.value(requestedMicros, 'requestedMicros');
  }
  return requestedMicros < cap ? requestedMicros : cap;
}

/// 一段活动按**真实本地周**切分后的份额（规范 §10.3、§22.2）。
final class ExecutionWeekSlice {
  const ExecutionWeekSlice({
    required this.localWeekStart,
    required this.micros,
  });

  final DateTime localWeekStart;
  final int micros;
}

/// 把一段实际投入按本地周边界切分，先累计微秒、不跨周搬运余秒。
///
/// [localWeekStartOf] 把 UTC 瞬时映射成"所在本地周的周一（本地日期）"；
/// [localWeekStartUtc] 把本地周一 00:00 映射回 UTC。两个回调都由时区库实现，
/// 这样纯函数不复制时区规则。
List<ExecutionWeekSlice> splitActivityAcrossWeeks({
  required DateTime startUtc,
  required DateTime endUtc,
  required DateTime Function(DateTime instantUtc) localWeekStartOf,
  required DateTime Function(DateTime localWeekStart) localWeekStartUtc,
}) {
  if (!startUtc.isUtc || !endUtc.isUtc) {
    throw ArgumentError('Activity instants must be UTC.');
  }
  if (!endUtc.isAfter(startUtc)) {
    throw ArgumentError('endUtc must be after startUtc.');
  }
  final byWeek = <String, ExecutionWeekSlice>{};
  var cursor = startUtc;
  var guard = 0;
  while (cursor.isBefore(endUtc)) {
    guard++;
    if (guard > 400) {
      throw StateError('周切分未收敛：请检查时区回调是否单调');
    }
    final week = localWeekStartOf(cursor);
    final localWeek = DateTime(week.year, week.month, week.day);
    final nextLocalWeek = DateTime(
      localWeek.year,
      localWeek.month,
      localWeek.day + 7,
    );
    var boundary = localWeekStartUtc(nextLocalWeek);
    if (!boundary.isAfter(cursor)) {
      // 时区回调异常时不要在同一个点无限循环；把剩余全部归入当前周。
      boundary = endUtc;
    }
    final sliceEnd = boundary.isBefore(endUtc) ? boundary : endUtc;
    final micros = sliceEnd.difference(cursor).inMicroseconds;
    if (micros > 0) {
      final key = executionLocalDateKey(localWeek);
      final existing = byWeek[key];
      byWeek[key] = ExecutionWeekSlice(
        localWeekStart: localWeek,
        micros: (existing?.micros ?? 0) + micros,
      );
    }
    cursor = sliceEnd;
  }
  final slices = byWeek.values.toList()
    ..sort((a, b) => a.localWeekStart.compareTo(b.localWeekStart));
  return slices;
}
