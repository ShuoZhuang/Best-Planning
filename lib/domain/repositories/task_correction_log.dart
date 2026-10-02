import 'package:personal_planner/core/ids.dart';

/// 一次"手动修正剩余时长"的记录。
///
/// 需求 FR-TASK-05：支持手动修正剩余时长，**且保留修正记录供统计分析**。
/// 任务表只保存当前值，历史必须另有出处，因此单独定义这条记录。
///
/// 记录同时保留修正前后两个值：统计要看的正是"用户每次修正多少、往哪个方向修正"
/// （§8 的预估偏差口径依赖预计时长与实际投入的对照，而不是最终剩余值）。
final class RemainingMinutesCorrection {
  const RemainingMinutesCorrection({
    required this.taskId,
    required this.previousMinutes,
    required this.correctedMinutes,
    required this.correctedAtUtc,
  });

  final EntityId taskId;
  final int previousMinutes;
  final int correctedMinutes;
  final DateTime correctedAtUtc;

  /// 修正的方向与幅度：正数表示剩余时长被调大（原先低估了工作量）。
  int get deltaMinutes => correctedMinutes - previousMinutes;
}

/// 剩余时长修正记录的写入端口。
///
/// 之所以做成端口而不是直接写数据库：领域与业务层不依赖存储实现，且测试可以
/// 用内存实现验证修正语义。
abstract interface class TaskCorrectionLog {
  Future<void> record(RemainingMinutesCorrection correction);
}
