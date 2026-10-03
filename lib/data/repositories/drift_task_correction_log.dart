import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/repositories/task_correction_log.dart';

/// 把剩余时长修正记录写进 `task_corrections`（FR-TASK-05）。
///
/// 修正记录是**统计口径的来源**，不是审计日志：§8 的预估偏差要看的是"用户每次修正
/// 多少、往哪个方向修正"，所以表里保留修正前后两个整数，而不是把差值编码进一个文本
/// 字段。记录一次写入不再修改，因此没有 `updatedAtUtc`。
///
/// id 由注入的 [IdGenerator] 生成，与任务本身一致地使用 UUID v4；时间取修正记录的
/// 携带值而不是再读一次时钟，避免写入时刻与 `RemainingMinutesCorrection` 记录的
/// 时刻不一致（任务行的 `updatedAtUtc` 与服务记录用的是同一个 `now`）。
final class DriftTaskCorrectionLog implements TaskCorrectionLog {
  DriftTaskCorrectionLog(this._database, {IdGenerator? ids})
    : _ids = ids ?? UuidIdGenerator();

  final db.AppDatabase _database;
  final IdGenerator _ids;

  @override
  Future<void> record(RemainingMinutesCorrection correction) => _database
      .into(_database.taskCorrections)
      .insert(
        db.TaskCorrectionsCompanion.insert(
          id: _ids.next(),
          taskId: correction.taskId,
          previousMinutes: correction.previousMinutes,
          correctedMinutes: correction.correctedMinutes,
          correctedAtUtc: correction.correctedAtUtc.microsecondsSinceEpoch,
        ),
      );
}
