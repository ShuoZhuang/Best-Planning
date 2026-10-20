import 'dart:collection';

/// 待确认预排状态（1.12.0 设计 §5.4、§11.4）。
///
/// `active` 表示当前可展示的持久预排；`accepted` / `rejected` 保留审计；
/// `superseded` 是被新预排替换的旧版本；`stale` 是基线、输入或算法已变化。
enum PendingPreviewStatus { active, superseded, accepted, rejected, stale }

/// 预览种类。
///
/// 1.11.0 起它承载两类操作：周期预排与**延后调整**（计划 Task 3 Step 3）。
/// 两类共用同一套表与仓储，用 [PendingPlanPreview.operationId] 区分操作身份。
enum PendingPreviewKind { recurringLookahead, deferAdjustment }

/// 周期预排的稳定 operationId（不是临时 id：跨重启保持一致）。
const String recurringLookaheadOperationId = 'recurring-lookahead';

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
    String operationId = recurringLookaheadOperationId,
    String proposalJson = '{}',
    String proposalSha256 = '',
    int formatVersion = 1,
  }) : operationId = _requireText(operationId, 'operationId'),
       proposalJson = proposalJson,
       proposalSha256 = proposalSha256,
       formatVersion = _requireFormatVersion(formatVersion) {
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
    if (kind == PendingPreviewKind.deferAdjustment && proposalJson == '{}') {
      throw ArgumentError(
        '延后调整的预览必须携带完整提案；只存块会让确认阶段丢掉未安排、冲突与要求。',
      );
    }
  }

  final String previewId;
  final PendingPreviewKind kind;

  /// 操作身份：周期预排固定 [recurringLookaheadOperationId]，延后调整用 adjustmentId。
  ///
  /// "每个(种类, 操作)只能有一条 active"保证两个独立调整不会互相覆盖（DFR-004）。
  final String operationId;

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

  /// 完整提案的 canonical JSON（见 `ScheduleProposalCodec`）。
  ///
  /// **为什么不能只存块**：确认阶段要复现 `unscheduled`、`conflicts`、
  /// `explanations`、`metrics`、`outcome`、`ruleOverride` 与调整要求；从块重建
  /// 提案会静默丢掉它们，并让 `PlanApplicationService` 的闸门以为"这次没有调整"。
  final String proposalJson;

  /// canonical 提案的 SHA-256（DFR-033：调整身份进入令牌）。
  final String proposalSha256;

  /// 提案编码格式版本；未知版本拒绝解码，不丢字段重建残缺提案。
  final int formatVersion;

  bool get isActive => status == PendingPreviewStatus.active;

  PendingPlanPreview copyWith({
    PendingPreviewStatus? status,
    int? revision,
    DateTime? expiresAtUtc,
    String? proposalJson,
    String? proposalSha256,
  }) => PendingPlanPreview(
    previewId: previewId,
    kind: kind,
    operationId: operationId,
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
    proposalJson: proposalJson ?? this.proposalJson,
    proposalSha256: proposalSha256 ?? this.proposalSha256,
    formatVersion: formatVersion,
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

String _requireText(String value, String name) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw ArgumentError.value(value, name, '不能为空');
  return trimmed;
}

int _requireFormatVersion(int value) {
  if (value < 1) {
    throw ArgumentError.value(value, 'formatVersion', '必须 ≥ 1');
  }
  return value;
}
