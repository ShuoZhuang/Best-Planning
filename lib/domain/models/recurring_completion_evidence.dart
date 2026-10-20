/// 周期进度证据（1.12.0 设计 §5.3、Task 7/8）。
///
/// **原证据不可改写**：撤销通过一条反向证据完成；有效进度 = 正向金额 − 反向金额。
/// 声明式完成（`fragmentCompletion`）不产生 `time_entries` 或伪造活动段。
enum RecurringEvidenceKind {
  activity,
  fragmentCompletion,
  manualAdjustment,
  correction,
}

final class RecurringCompletionEvidence {
  RecurringCompletionEvidence({
    required this.evidenceId,
    required this.dataEpoch,
    required this.operationId,
    required this.cycleId,
    required this.fragmentId,
    required this.amountMicros,
    required this.kind,
    required this.reversesEvidenceId,
    required this.recordedAtUtc,
    required this.effectiveAtUtc,
    required this.sequence,
    required this.reason,
    required this.idempotencyKey,
    required this.revision,
  }) {
    if (evidenceId.trim().isEmpty) {
      throw ArgumentError.value(evidenceId, 'evidenceId');
    }
    if (idempotencyKey.trim().isEmpty) {
      throw ArgumentError.value(idempotencyKey, 'idempotencyKey');
    }
    if (amountMicros <= 0) {
      throw ArgumentError.value(amountMicros, 'amountMicros');
    }
    if (!recordedAtUtc.isUtc || !effectiveAtUtc.isUtc) {
      throw ArgumentError('Evidence instants must be UTC.');
    }
    if (sequence < 1) throw ArgumentError.value(sequence, 'sequence');
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    if (kind == RecurringEvidenceKind.correction &&
        reversesEvidenceId == null) {
      throw ArgumentError(
        'Correction evidence must reference reversed evidence.',
      );
    }
  }

  final String evidenceId;
  final String dataEpoch;
  final String operationId;
  final String cycleId;
  final String? fragmentId;
  final int amountMicros;
  final RecurringEvidenceKind kind;
  final String? reversesEvidenceId;
  final DateTime recordedAtUtc;
  final DateTime effectiveAtUtc;
  final int sequence;
  final String? reason;
  final String idempotencyKey;
  final int revision;

  bool get isReversal =>
      kind == RecurringEvidenceKind.correction || reversesEvidenceId != null;

  /// 有符号金额：反向证据计入负数。
  int get signedMicros => isReversal ? -amountMicros : amountMicros;
}

/// 有效证据余额必须非负；用于迁移/事务校验。
int effectiveEvidenceMicros(Iterable<RecurringCompletionEvidence> evidence) {
  var total = 0;
  for (final item in evidence) {
    total += item.signedMicros;
  }
  if (total < 0) {
    throw StateError('周期证据余额为负：$total');
  }
  return total;
}

/// 一个片段的有效声明完成量（不含真实活动）。
int declaredMicrosForFragment(
  Iterable<RecurringCompletionEvidence> evidence,
  String fragmentId,
) {
  var total = 0;
  for (final item in evidence) {
    if (item.fragmentId != fragmentId) continue;
    if (item.kind != RecurringEvidenceKind.fragmentCompletion &&
        item.kind != RecurringEvidenceKind.correction) {
      continue;
    }
    total += item.signedMicros;
  }
  return total < 0 ? 0 : total;
}

/// 同一片段声明量不能超过承诺量；返回溢出微秒。
int fragmentDeclarationOverflow({
  required int allocatedMicros,
  required int realCreditedMicros,
  required int declaredMicros,
}) {
  final available = allocatedMicros - realCreditedMicros;
  final overflow = declaredMicros - available;
  return overflow > 0 ? overflow : 0;
}
