import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';

/// 执行命令的固定输入（规范 §19.3）。
///
/// **命令不是界面状态**：页面只构造命令、调用端口、读取稳定结果；它不能直接写执行表，
/// 也不能在客户端采信"现在几点"。开始、暂停、结束的时刻一律由服务在提交时采样。

/// 所有改变持久状态的命令共有的幂等键与摘要能力。
abstract interface class ExecutionCommand {
  String get operationId;

  String get dataEpoch;

  /// 稳定的命令类型名，写入 `execution_operations.command_type`。
  String get commandType;

  /// `task`、`occurrence`、`session`、`draft`、`plan` 之一。
  String get subjectKind;

  String? get subjectId;

  /// 确定字段顺序后的 SHA-256。不得包含界面文案、Map 迭代顺序或区域格式。
  String requestHash();
}

/// 递归规范化：Map 按 key 排序，DateTime 固定为 UTC 微秒，枚举使用稳定 name。
Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalValue(value[key])};
  }
  if (value is Iterable) {
    return [for (final item in value) _canonicalValue(item)];
  }
  if (value is DateTime) {
    return value.toUtc().microsecondsSinceEpoch;
  }
  if (value is Enum) return value.name;
  return value;
}

/// 计算稳定请求摘要。`operationId` 不是请求内容，不参与摘要。
String executionRequestHash(Map<String, Object?> fields) {
  final canonical = _canonicalValue(fields);
  final encoded = jsonEncode(canonical);
  return sha256.convert(utf8.encode(encoded)).toString();
}

/// 开始一段执行（规范 §19.3 的 `start`）。
final class StartExecutionCommand implements ExecutionCommand {
  StartExecutionCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.taskId,
    required this.mode,
    required this.taskInputHash,
    required this.runtimeRevision,
    this.occurrenceId,
    this.occurrenceRevision,
    this.targetDurationMicros,
  }) {
    if (mode == ExecutionMode.actualOnly && occurrenceId != null) {
      throw ArgumentError('actualOnly 记录不创建合法计划占用，不能绑定计划实例。');
    }
    if (targetDurationMicros != null && targetDurationMicros! <= 0) {
      throw ArgumentError.value(targetDurationMicros, 'targetDurationMicros');
    }
  }

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String taskId;
  final String? occurrenceId;
  final ExecutionMode mode;
  final int? targetDurationMicros;

  /// 任务排程相关字段的确定序列化哈希；不是数据库里并不存在的假 revision。
  final String taskInputHash;
  final int? occurrenceRevision;
  final int runtimeRevision;

  @override
  String get commandType => 'start';

  @override
  String get subjectKind => 'task';

  @override
  String? get subjectId => taskId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'taskId': taskId,
    'occurrenceId': occurrenceId,
    'mode': mode,
    'targetDurationMicros': targetDurationMicros,
    'taskInputHash': taskInputHash,
    'occurrenceRevision': occurrenceRevision,
    'runtimeRevision': runtimeRevision,
  });
}

/// 暂停（规范 §19.3 的 `pause`）。立即切断活动段；原因事后单独保存。
final class PauseExecutionCommand implements ExecutionCommand {
  const PauseExecutionCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.sessionId,
    required this.sessionRevision,
    required this.runtimeRevision,
    this.systemReason,
  });

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String sessionId;
  final int sessionRevision;
  final int runtimeRevision;
  final String? systemReason;

  @override
  String get commandType => 'pause';

  @override
  String get subjectKind => 'session';

  @override
  String? get subjectId => sessionId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'sessionId': sessionId,
    'sessionRevision': sessionRevision,
    'runtimeRevision': runtimeRevision,
    'systemReason': systemReason,
  });
}

/// 继续（规范 §19.3 的 `resume`）。不创建第二段会话，先重验硬边界与全局槽位。
final class ResumeExecutionCommand implements ExecutionCommand {
  const ResumeExecutionCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.sessionId,
    required this.mode,
    required this.sessionRevision,
    required this.runtimeRevision,
    required this.hardBoundaryInputHash,
  });

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String sessionId;
  final ExecutionMode mode;
  final int sessionRevision;
  final int runtimeRevision;
  final String hardBoundaryInputHash;

  @override
  String get commandType => 'resume';

  @override
  String get subjectKind => 'session';

  @override
  String? get subjectId => sessionId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'sessionId': sessionId,
    'mode': mode,
    'sessionRevision': sessionRevision,
    'runtimeRevision': runtimeRevision,
    'hardBoundaryInputHash': hardBoundaryInputHash,
  });
}

/// 结束本次会话（规范 §19.3 的 `finish`）。
///
/// **只结束会话**：只要实例仍有未完成份额，生命周期保持 `started`。"放弃本实例剩余"
/// 才使实例进入 `finished`，并且保存原因事件。
final class FinishExecutionCommand implements ExecutionCommand {
  FinishExecutionCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.sessionId,
    required this.sessionRevision,
    required this.runtimeRevision,
    this.abandonOccurrenceRemaining = false,
    this.barrierReason,
    this.note = '',
  });

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String sessionId;
  final int sessionRevision;
  final int runtimeRevision;
  final bool abandonOccurrenceRemaining;
  final ExecutionBarrierReason? barrierReason;
  final String note;

  @override
  String get commandType => 'finish';

  @override
  String get subjectKind => 'session';

  @override
  String? get subjectId => sessionId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'sessionId': sessionId,
    'sessionRevision': sessionRevision,
    'runtimeRevision': runtimeRevision,
    'abandonOccurrenceRemaining': abandonOccurrenceRemaining,
    'barrierReason': barrierReason,
    'note': note,
  });
}

/// 补记一段已经发生的投入（规范 §12.1、§19.3 的 `recordManual`）。
final class RecordManualExecutionCommand implements ExecutionCommand {
  RecordManualExecutionCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.taskId,
    required this.segmentStartUtc,
    required this.segmentEndUtc,
    required this.taskInputHash,
    required this.progressAnchorRevision,
    this.occurrenceId,
    this.occurrenceRevision,
    this.note = '',
    this.includedInAnchor,
    this.overlapResolution,
    this.confirmationToken,
  }) {
    if (!segmentStartUtc.isUtc || !segmentEndUtc.isUtc) {
      throw ArgumentError('补记区间必须是 UTC。');
    }
    if (!segmentEndUtc.isAfter(segmentStartUtc)) {
      throw ArgumentError('补记结束必须晚于开始。');
    }
  }

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String taskId;
  final String? occurrenceId;
  final DateTime segmentStartUtc;
  final DateTime segmentEndUtc;
  final String note;

  /// 晚补记早于人工剩余检查点时，用户明确选择是否已包含在上次修正中。
  /// `null` 表示尚未选择，服务返回 `needsConfirmation`（规范 §10.2、EXE-45）。
  final bool? includedInAnchor;

  /// 与既有记录重叠时的处理方式；为空时服务返回 `needsConfirmation`。
  final ExecutionOverlapResolution? overlapResolution;
  final String taskInputHash;
  final int? occurrenceRevision;
  final int progressAnchorRevision;
  final String? confirmationToken;

  @override
  String get commandType => 'recordManual';

  @override
  String get subjectKind => 'task';

  @override
  String? get subjectId => taskId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'taskId': taskId,
    'occurrenceId': occurrenceId,
    'segmentStartUtc': segmentStartUtc,
    'segmentEndUtc': segmentEndUtc,
    'note': note,
    'includedInAnchor': includedInAnchor,
    'overlapResolution': overlapResolution,
    'taskInputHash': taskInputHash,
    'occurrenceRevision': occurrenceRevision,
    'progressAnchorRevision': progressAnchorRevision,
    'confirmationToken': confirmationToken,
  });
}

/// 更正一条投入记录（规范 §5.3、§19.3 的 `correctRecord`）。
final class CorrectExecutionRecordCommand implements ExecutionCommand {
  CorrectExecutionRecordCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.recordId,
    required this.segmentStartUtc,
    required this.segmentEndUtc,
    required this.recordRevision,
    required this.newTargetKind,
    required this.newTargetId,
    required this.newTargetProgressAnchorRevision,
    this.oldTargetProgressAnchorRevision,
    this.note = '',
    this.confirmationToken,
  }) {
    if (!segmentStartUtc.isUtc || !segmentEndUtc.isUtc) {
      throw ArgumentError('更正区间必须是 UTC。');
    }
    if (!segmentEndUtc.isAfter(segmentStartUtc)) {
      throw ArgumentError('更正结束必须晚于开始。');
    }
  }

  @override
  final String operationId;
  @override
  final String dataEpoch;

  /// `time_entries.id` / 活动记录标识。
  final String recordId;
  final DateTime segmentStartUtc;
  final DateTime segmentEndUtc;
  final String note;
  final int recordRevision;
  final ExecutionTargetKind newTargetKind;
  final String newTargetId;
  final int? oldTargetProgressAnchorRevision;
  final int newTargetProgressAnchorRevision;
  final String? confirmationToken;

  @override
  String get commandType => 'correctRecord';

  @override
  String get subjectKind => 'occurrence';

  @override
  String? get subjectId => recordId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'recordId': recordId,
    'segmentStartUtc': segmentStartUtc,
    'segmentEndUtc': segmentEndUtc,
    'note': note,
    'recordRevision': recordRevision,
    'newTargetKind': newTargetKind,
    'newTargetId': newTargetId,
    'oldTargetProgressAnchorRevision': oldTargetProgressAnchorRevision,
    'newTargetProgressAnchorRevision': newTargetProgressAnchorRevision,
    'confirmationToken': confirmationToken,
  });
}

/// 稍后提醒（规范 §8、§19.3 的 `setSnooze`）。第一轮 UI 固定 10 分钟。
final class SetExecutionSnoozeCommand implements ExecutionCommand {
  SetExecutionSnoozeCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.occurrenceId,
    required this.elapsedMinutes,
    required this.occurrenceRevision,
    required this.reminderRevision,
    required this.notificationSettingsHash,
  }) {
    if (elapsedMinutes < 1 || elapsedMinutes > 1440) {
      throw ArgumentError.value(elapsedMinutes, 'elapsedMinutes');
    }
  }

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String occurrenceId;

  /// 从点击时刻起算的**经过时长**，不是原计划时刻。
  final int elapsedMinutes;
  final int occurrenceRevision;
  final int reminderRevision;
  final String notificationSettingsHash;

  @override
  String get commandType => 'setSnooze';

  @override
  String get subjectKind => 'occurrence';

  @override
  String? get subjectId => occurrenceId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'occurrenceId': occurrenceId,
    'elapsedMinutes': elapsedMinutes,
    'occurrenceRevision': occurrenceRevision,
    'reminderRevision': reminderRevision,
    'notificationSettingsHash': notificationSettingsHash,
  });
}

/// 请求一次局部恢复预览（规范 §9、§19.3 的 `requestRecovery`）。
///
/// **不写计划、不写 dayHold**：只建立当前进程代次里的一次性草案。
final class RequestExecutionRecoveryCommand implements ExecutionCommand {
  RequestExecutionRecoveryCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.occurrenceId,
    required this.notBeforeUtc,
    required this.occurrenceRevision,
    required this.planVersionId,
    required this.taskInputHash,
    required this.progressAnchorRevision,
    required this.processEpoch,
    this.targetShareMicros,
    this.holdToday = false,
  }) {
    if (!notBeforeUtc.isUtc) {
      throw ArgumentError.value(notBeforeUtc, 'notBeforeUtc');
    }
    if (targetShareMicros != null && targetShareMicros! <= 0) {
      throw ArgumentError.value(targetShareMicros, 'targetShareMicros');
    }
  }

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String occurrenceId;
  final DateTime notBeforeUtc;
  final int? targetShareMicros;

  /// "今天不再安排该任务"：只在草案里暂存，应用成功时才提交（规范 §8、§19.3）。
  final bool holdToday;
  final int occurrenceRevision;
  final String planVersionId;
  final String taskInputHash;
  final int progressAnchorRevision;
  final String processEpoch;

  @override
  String get commandType => 'requestRecovery';

  @override
  String get subjectKind => 'occurrence';

  @override
  String? get subjectId => occurrenceId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'occurrenceId': occurrenceId,
    'notBeforeUtc': notBeforeUtc,
    'targetShareMicros': targetShareMicros,
    'holdToday': holdToday,
    'occurrenceRevision': occurrenceRevision,
    'planVersionId': planVersionId,
    'taskInputHash': taskInputHash,
    'progressAnchorRevision': progressAnchorRevision,
    'processEpoch': processEpoch,
  });
}

/// 应用恢复草案（规范 §19.3 的 `applyRecovery`）。
///
/// `completeOnly` 是默认且所有自动路径的唯一值；只有页面已展示每项未安排分钟并取得
/// 本次明确确认，才允许 `allowPartial`。
final class ApplyExecutionRecoveryCommand implements ExecutionCommand {
  const ApplyExecutionRecoveryCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.draftId,
    required this.proposalId,
    required this.inputHash,
    required this.processEpoch,
    required this.occurrenceRevision,
    required this.planVersionId,
    required this.taskInputHash,
    required this.progressAnchorRevision,
    this.authorizationMode = PlanApplyMode.completeOnly,
  });

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String draftId;
  final String proposalId;
  final String inputHash;
  final String processEpoch;
  final int occurrenceRevision;
  final String planVersionId;
  final String taskInputHash;
  final int progressAnchorRevision;
  final PlanApplyMode authorizationMode;

  @override
  String get commandType => 'applyRecovery';

  @override
  String get subjectKind => 'draft';

  @override
  String? get subjectId => draftId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'draftId': draftId,
    'proposalId': proposalId,
    'inputHash': inputHash,
    'processEpoch': processEpoch,
    'occurrenceRevision': occurrenceRevision,
    'planVersionId': planVersionId,
    'taskInputHash': taskInputHash,
    'progressAnchorRevision': progressAnchorRevision,
    'authorizationMode': authorizationMode,
  });
}

/// 取消恢复/跳过草案（规范 §19.3 的 `cancelRecovery`）。重复取消无副作用。
final class CancelExecutionRecoveryCommand implements ExecutionCommand {
  const CancelExecutionRecoveryCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.draftId,
    required this.draftRevision,
    required this.processEpoch,
  });

  @override
  final String operationId;
  @override
  final String dataEpoch;
  final String draftId;
  final int draftRevision;
  final String processEpoch;

  @override
  String get commandType => 'cancelRecovery';

  @override
  String get subjectKind => 'draft';

  @override
  String? get subjectId => draftId;

  @override
  String requestHash() => executionRequestHash({
    'command': commandType,
    'dataEpoch': dataEpoch,
    'draftId': draftId,
    'draftRevision': draftRevision,
    'processEpoch': processEpoch,
  });
}

/// 生产端口（规范 §19.3）。页面、通知点击、原专注页和测试驱动只能调用它。
abstract interface class ExecutionService {
  Future<ExecutionCommandResult> start(StartExecutionCommand command);

  Future<ExecutionCommandResult> pause(PauseExecutionCommand command);

  Future<ExecutionCommandResult> resume(ResumeExecutionCommand command);

  Future<ExecutionCommandResult> finish(FinishExecutionCommand command);

  Future<ExecutionCommandResult> recordManual(
    RecordManualExecutionCommand command,
  );

  Future<ExecutionCommandResult> correctRecord(
    CorrectExecutionRecordCommand command,
  );

  Future<ExecutionCommandResult> setSnooze(SetExecutionSnoozeCommand command);
}

/// 恢复端口（规范 §19.3）。
abstract interface class ExecutionRecoveryService {
  /// 当前进程代次；草案与命令必须携带同一个值。
  String get processEpoch;

  Future<ExecutionRecoveryDraftResult> requestRecovery(
    RequestExecutionRecoveryCommand command,
  );

  Future<ExecutionCommandResult> applyRecovery(
    ApplyExecutionRecoveryCommand command,
  );

  Future<ExecutionCommandResult> cancelRecovery(
    CancelExecutionRecoveryCommand command,
  );
}
