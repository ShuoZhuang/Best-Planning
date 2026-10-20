import 'dart:math' as math;

import 'package:personal_planner/domain/models/plan_adjustment.dart';

/// 一次调整失败的**结构化证据**（计划 Task 12 Step 2）。
///
/// **为什么不是一句自由文本**：失败原因决定用户下一步做什么（改截止、换日期、腾时间、
/// 重新生成，还是报缺陷）。把它们压成"可用时间不足"会让用户白做无用功，也无法测试
/// （DFR-024/032 的成因）。
///
/// [placeableMinutes] 为 `null` 表示"未知"：**未知不能伪造成 0**，否则
/// `shortageMinutes` 会凭空放大。
final class AdjustmentFailureEvidence {
  const AdjustmentFailureEvidence({
    required this.code,
    required this.taskTitle,
    required this.requestedMinutes,
    this.placeableMinutes,
    this.consideredLocalDates = const [],
    this.blockingConstraintCodes = const [],
  });

  final PlanAdjustmentFailureCode code;

  /// 创建调整时保存的标题快照；未知时由调用方传「未命名任务」。
  final String taskTitle;

  /// 目标块要安排的分钟数（源块时长）。
  final int requestedMinutes;

  /// 在硬约束下**可放**的分钟数；未知为 null（不伪造 0）。
  final int? placeableMinutes;

  /// 搜索实际考虑过的本地日期（只含年月日）。
  final List<DateTime> consideredLocalDates;

  /// 阻挡放置的硬约束码（`HardConstraintCode.name` 或稳定短码）。
  final List<String> blockingConstraintCodes;

  int? get shortageMinutes => placeableMinutes == null
      ? null
      : math.max(0, requestedMinutes - placeableMinutes!);

  /// 日志投影：只保留稳定码与数量区间，**不含标题、UUID、路径或完整时刻表**。
  Map<String, Object?> toLogProjection() => {
    'code': code.name,
    'requestedMinutes': requestedMinutes,
    'placeableMinutes': placeableMinutes,
    'shortageMinutes': shortageMinutes,
    'consideredDateCount': consideredLocalDates.length,
    'blockingConstraintCodes': blockingConstraintCodes,
  };

  @override
  String toString() => 'AdjustmentFailureEvidence(${code.name})';
}
