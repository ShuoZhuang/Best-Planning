import 'dart:convert';

import 'package:personal_planner/domain/execution/execution_models.dart';

/// 命令的稳定结果（规范 §19.3）。
///
/// 页面、通知点击、测试驱动**只能**读取这个对象里的封闭枚举与安全参数；内部异常文本、
/// SQL 和个人内容不得穿过这一层。`reasonCode` 是给集中文案映射用的，不是给用户直接看的。
enum ExecutionResultStatus {
  applied,
  alreadyApplied,
  stale,
  notFound,

  /// 已有另一个实例占用唯一实时会话槽位（规范 §19.2、§19.3）。
  activeSessionConflict,
  blockedByHardBoundary,
  outsidePlanBoundary,

  /// 需要用户确认后才能继续（补记重叠、晚补记是否已包含等）。
  needsConfirmation,
  notificationsDisabled,
  invalid,

  /// 事务或磁盘写入失败。界面必须显示"未保存"，不能显示假成功。
  storageFailed,

  /// 恢复/应用时来源无法对应到当前已确认计划（规范 §19.5）。
  sourceMappingMissing,
}

/// 封闭原因码。新增值必须同时更新集中文案映射与门禁测试。
enum ExecutionReasonCode {
  none,
  operationIdReused,
  entityNotFound,
  revisionMismatch,
  illegalTransition,
  taskUnavailable,
  taskClosed,
  activeSessionConflict,
  hardBoundaryBlocked,
  outsidePlanBoundary,
  notificationsDisabled,
  sourceMappingMissing,
  overlapNeedsConfirmation,
  overlapRejected,
  invalidNote,
  invalidDuration,
  invalidElapsed,
  invalidSnoozeRange,
  confirmationRequired,
  confirmationTokenMismatch,
  draftNotFound,
  draftNotOpen,
  draftExpired,
  proposalStale,
  proposalInvalid,
  partialNotAuthorized,
  noRemainingWork,
  sameOccurrenceSession,
  otherOccurrenceSession,
  clockAnomaly,
  planApplyFailed,
  storageFailed,
  invalidOperation,
  unsupported,
}

/// 命令结果。JSON 形式会原样写入 `execution_operations.result_json`，因此字段顺序与
/// 枚举名必须保持稳定（规范 §11、§19.3）。
final class ExecutionCommandResult {
  ExecutionCommandResult({
    required this.status,
    required this.reasonCode,
    this.operationId,
    this.occurrenceId,
    this.sessionId,
    this.revision,
    this.confirmationToken,
    Map<String, Object?> parameters = const {},
  }) : parameters = Map.unmodifiable(Map.of(parameters));

  factory ExecutionCommandResult.applied({
    required String operationId,
    String? occurrenceId,
    String? sessionId,
    int? revision,
    Map<String, Object?> parameters = const {},
  }) => ExecutionCommandResult(
    status: ExecutionResultStatus.applied,
    reasonCode: ExecutionReasonCode.none,
    operationId: operationId,
    occurrenceId: occurrenceId,
    sessionId: sessionId,
    revision: revision,
    parameters: parameters,
  );

  factory ExecutionCommandResult.alreadyApplied({
    required String operationId,
    String? occurrenceId,
    String? sessionId,
    int? revision,
    Map<String, Object?> parameters = const {},
  }) => ExecutionCommandResult(
    status: ExecutionResultStatus.alreadyApplied,
    reasonCode: ExecutionReasonCode.none,
    operationId: operationId,
    occurrenceId: occurrenceId,
    sessionId: sessionId,
    revision: revision,
    parameters: parameters,
  );

  factory ExecutionCommandResult.failure(
    ExecutionResultStatus status,
    ExecutionReasonCode reasonCode, {
    String? operationId,
    String? occurrenceId,
    String? sessionId,
    int? revision,
    String? confirmationToken,
    Map<String, Object?> parameters = const {},
  }) => ExecutionCommandResult(
    status: status,
    reasonCode: reasonCode,
    operationId: operationId,
    occurrenceId: occurrenceId,
    sessionId: sessionId,
    revision: revision,
    confirmationToken: confirmationToken,
    parameters: parameters,
  );

  final ExecutionResultStatus status;
  final ExecutionReasonCode reasonCode;
  final String? operationId;
  final String? occurrenceId;
  final String? sessionId;
  final int? revision;

  /// `needsConfirmation` 时由服务签发；用户处理冲突后必须带它提交新命令（规范 §19.3）。
  final String? confirmationToken;

  /// 只允许放可安全展示的结构化参数：边界时刻、缺少分钟、受影响块 id 等。
  final Map<String, Object?> parameters;

  bool get isSuccess =>
      status == ExecutionResultStatus.applied ||
      status == ExecutionResultStatus.alreadyApplied;

  bool get needsConfirmation =>
      status == ExecutionResultStatus.needsConfirmation;

  /// 同一操作重放时的返回：业务事实已经提交，但这不是"本次又提交了一次"。
  ExecutionCommandResult asAlreadyApplied() => ExecutionCommandResult(
    status: ExecutionResultStatus.alreadyApplied,
    reasonCode: reasonCode,
    operationId: operationId,
    occurrenceId: occurrenceId,
    sessionId: sessionId,
    revision: revision,
    confirmationToken: confirmationToken,
    parameters: parameters,
  );

  Map<String, Object?> toJson() => {
    'status': status.name,
    'reasonCode': reasonCode.name,
    if (operationId != null) 'operationId': operationId,
    if (occurrenceId != null) 'occurrenceId': occurrenceId,
    if (sessionId != null) 'sessionId': sessionId,
    if (revision != null) 'revision': revision,
    if (confirmationToken != null) 'confirmationToken': confirmationToken,
    if (parameters.isNotEmpty) 'parameters': parameters,
  };

  String encode() => jsonEncode(toJson());

  static ExecutionCommandResult fromJson(Map<String, Object?> json) {
    final statusName = json['status'];
    final reasonName = json['reasonCode'];
    final status = ExecutionResultStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    final reason = ExecutionReasonCode.values
        .where((value) => value.name == reasonName)
        .firstOrNull;
    if (status == null || reason == null) {
      // 损坏的元数据必须被隔离，而不是让整个页面或统计崩溃（EXE-68）。
      return ExecutionCommandResult(
        status: ExecutionResultStatus.invalid,
        reasonCode: ExecutionReasonCode.unsupported,
        parameters: const {'corruptedResult': true},
      );
    }
    return ExecutionCommandResult(
      status: status,
      reasonCode: reason,
      operationId: json['operationId'] as String?,
      occurrenceId: json['occurrenceId'] as String?,
      sessionId: json['sessionId'] as String?,
      revision: (json['revision'] as num?)?.toInt(),
      confirmationToken: json['confirmationToken'] as String?,
      parameters:
          (json['parameters'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  static ExecutionCommandResult decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return fromJson(decoded);
      }
      if (decoded is Map) return fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      // 落到下面的隔离结果。
    }
    return ExecutionCommandResult(
      status: ExecutionResultStatus.invalid,
      reasonCode: ExecutionReasonCode.unsupported,
      parameters: const {'corruptedResult': true},
    );
  }
}

/// 恢复预览中的一块安排（规范 §9.1：列出每个受影响块）。
final class ExecutionRecoveryPreviewBlock {
  ExecutionRecoveryPreviewBlock({
    required this.taskId,
    required this.startUtc,
    required this.endUtc,
    required this.isOccurrenceTask,
  }) {
    if (!startUtc.isUtc || !endUtc.isUtc) {
      throw ArgumentError('Preview block instants must be UTC.');
    }
  }

  final String taskId;
  final DateTime startUtc;
  final DateTime endUtc;
  final bool isOccurrenceTask;
}

/// 预览中无法安排的缺口：必须显示分钟数，不能只说"装不下"。
final class ExecutionRecoveryShortage {
  const ExecutionRecoveryShortage({
    required this.taskId,
    required this.minutes,
  });

  final String taskId;
  final int minutes;
}

final class ExecutionRecoveryPreview {
  ExecutionRecoveryPreview({
    required List<ExecutionRecoveryPreviewBlock> blocks,
    required List<ExecutionRecoveryShortage> shortages,
  }) : blocks = List.unmodifiable(blocks),
       shortages = List.unmodifiable(shortages);

  final List<ExecutionRecoveryPreviewBlock> blocks;
  final List<ExecutionRecoveryShortage> shortages;

  int get unassignedMinutes =>
      shortages.fold(0, (sum, item) => sum + item.minutes);
}

/// 只存在于当前进程代次的一次性恢复草案（规范 §19.3、§19.6）。
final class ExecutionRecoveryDraft {
  ExecutionRecoveryDraft({
    required this.draftId,
    required this.proposalId,
    required this.occurrenceId,
    required this.processEpoch,
    required this.state,
    required this.revision,
    required this.createdAtUtc,
    required this.notBeforeUtc,
    required this.targetShareMicros,
    required this.holdToday,
    required this.inputHash,
    required this.planVersionId,
    required this.unassignedMinutes,
    required this.preview,
  }) {
    if (!createdAtUtc.isUtc) {
      throw ArgumentError.value(createdAtUtc, 'createdAtUtc');
    }
    if (!notBeforeUtc.isUtc) {
      throw ArgumentError.value(notBeforeUtc, 'notBeforeUtc');
    }
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    if (targetShareMicros < 0) {
      throw ArgumentError.value(targetShareMicros, 'targetShareMicros');
    }
    if (unassignedMinutes < 0) {
      throw ArgumentError.value(unassignedMinutes, 'unassignedMinutes');
    }
  }

  final String draftId;
  final String proposalId;
  final String occurrenceId;
  final String processEpoch;
  final ExecutionDraftState state;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime notBeforeUtc;
  final int targetShareMicros;
  final bool holdToday;
  final String inputHash;
  final String planVersionId;

  /// 预览中明确展示的未安排分钟；`applyRecovery(allowPartial)` 前必须让用户看到。
  final int unassignedMinutes;

  /// 每个受影响块与缺口的结构化预览。
  final ExecutionRecoveryPreview preview;

  bool get isOpen => state == ExecutionDraftState.open;

  ExecutionRecoveryDraft copyWith({
    ExecutionDraftState? state,
    int? revision,
    int? unassignedMinutes,
  }) => ExecutionRecoveryDraft(
    draftId: draftId,
    proposalId: proposalId,
    occurrenceId: occurrenceId,
    processEpoch: processEpoch,
    state: state ?? this.state,
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    notBeforeUtc: notBeforeUtc,
    targetShareMicros: targetShareMicros,
    holdToday: holdToday,
    inputHash: inputHash,
    planVersionId: planVersionId,
    unassignedMinutes: unassignedMinutes ?? this.unassignedMinutes,
    preview: preview,
  );
}

final class ExecutionRecoveryDraftResult {
  const ExecutionRecoveryDraftResult({required this.result, this.draft});

  final ExecutionCommandResult result;
  final ExecutionRecoveryDraft? draft;

  bool get isSuccess => result.isSuccess && draft != null;
}
