import 'dart:collection';

/// 待确认预排状态（1.12.0 设计 §5.4、§11.4）。
///
/// `active` 表示当前可展示的持久预排；`accepted` / `rejected` 保留审计；
/// `superseded` 是被新预排替换的旧版本；`stale` 是基线、输入或算法已变化。
enum PendingPreviewStatus { active, superseded, accepted, rejected, stale }

enum PendingPreviewKind { recurringLookahead }

/// 一份持久化的待确认预排。它**不是正式计划**，不能占用正式通知或执行入口。
final class PendingPlanPreview {
  PendingPlanPreview({
    required this.previewId,
    required this.kind,
    required this.basePlanVersionId,
    required this.inputHash,
    required this.algorithmVersion,
    required this.windowStartUtc,
    required this.windowEndUtc,
    required this.timeZoneId,
    required this.status,
    required this.createdAtUtc,
    required this.expiresAtUtc,
    required this.summaryJson,
    required this.diagnosticsJson,
    required this.revision,
  }) {
    if (!windowStartUtc.isUtc || !windowEndUtc.isUtc) {
      throw ArgumentError('Preview window must be UTC.');
    }
    if (!windowEndUtc.isAfter(windowStartUtc)) {
      throw ArgumentError('windowEndUtc must be after windowStartUtc.');
    }
    if (!createdAtUtc.isUtc || !expiresAtUtc.isUtc) {
      throw ArgumentError('Preview instants must be UTC.');
    }
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    if (timeZoneId.trim().isEmpty) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId');
    }
  }

  final String previewId;
  final PendingPreviewKind kind;
  final String basePlanVersionId;
  final String inputHash;
  final String algorithmVersion;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;
  final String timeZoneId;
  final PendingPreviewStatus status;
  final DateTime createdAtUtc;
  final DateTime expiresAtUtc;
  final String summaryJson;
  final String diagnosticsJson;
  final int revision;

  bool get isActive => status == PendingPreviewStatus.active;

  PendingPlanPreview copyWith({
    PendingPreviewStatus? status,
    int? revision,
    DateTime? expiresAtUtc,
  }) => PendingPlanPreview(
    previewId: previewId,
    kind: kind,
    basePlanVersionId: basePlanVersionId,
    inputHash: inputHash,
    algorithmVersion: algorithmVersion,
    windowStartUtc: windowStartUtc,
    windowEndUtc: windowEndUtc,
    timeZoneId: timeZoneId,
    status: status ?? this.status,
    createdAtUtc: createdAtUtc,
    expiresAtUtc: expiresAtUtc ?? this.expiresAtUtc,
    summaryJson: summaryJson,
    diagnosticsJson: diagnosticsJson,
    revision: revision ?? this.revision,
  );
}

/// 预排中的一个可见块。标题是保存时的投影，后续模板改名不改写历史预排。
final class PendingPlanPreviewBlock {
  const PendingPlanPreviewBlock({
    required this.previewId,
    required this.blockId,
    required this.taskId,
    required this.cycleId,
    required this.title,
    required this.startUtc,
    required this.endUtc,
    required this.explanationCode,
    required this.minutes,
  });

  final String previewId;
  final String blockId;
  final String? taskId;
  final String? cycleId;
  final String title;
  final DateTime startUtc;
  final DateTime endUtc;
  final String explanationCode;
  final int minutes;
}

final class PendingPreviewBundle {
  PendingPreviewBundle({
    required this.preview,
    required List<PendingPlanPreviewBlock> blocks,
  }) : blocks = UnmodifiableListView(List.of(blocks));

  final PendingPlanPreview preview;
  final List<PendingPlanPreviewBlock> blocks;
}

/// 预排确认前必须逐项匹配的令牌（设计 §4.4、§11.4）。
final class PendingPreviewTokens {
  const PendingPreviewTokens({
    required this.basePlanVersionId,
    required this.inputHash,
    required this.algorithmVersion,
    required this.previewRevision,
  });

  final String basePlanVersionId;
  final String inputHash;
  final String algorithmVersion;
  final int previewRevision;
}

enum PreviewApplyStatus {
  applied,
  stale,
  invalid,
  notFound,
  partialConfirmationRequired,
}

final class PreviewApplyResult {
  const PreviewApplyResult({
    required this.status,
    this.planVersionId,
    this.reason,
  });

  final PreviewApplyStatus status;
  final String? planVersionId;
  final String? reason;

  bool get isApplied => status == PreviewApplyStatus.applied;
}
