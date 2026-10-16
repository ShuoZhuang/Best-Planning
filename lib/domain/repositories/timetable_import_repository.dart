import 'package:personal_planner/domain/models/calendar_event.dart';

/// 导入批次的**存储状态**（计划 §2.2）。
///
/// 语义必须逐值分得清，因为它们决定"能不能再次导入同一张图片"：
///
/// - [committed]：批次提交完成，且**没有**通过"删除整个课程"这条路径移除过内容；
/// - [partiallyDeleted]：该批次**至少有一门逻辑课程**被课程管理功能删除。
///   **即使已经删到 0 条也保留这个状态与审计记录**——"这门课的来源已被用户删掉"
///   正是用户下一步"用原图恢复"必须知道的事实；
/// - [rolledBack]：用户执行了批次回滚；
/// - [draft]：保留的兼容值，**不是**删除标记。
enum TimetableImportBatchStatus {
  draft('draft'),
  committed('committed'),
  partiallyDeleted('partiallyDeleted'),
  rolledBack('rolledBack');

  const TimetableImportBatchStatus(this.storageValue);
  final String storageValue;

  /// 从存储值解析。
  ///
  /// **未知值必须抛错，不能静默回落成 [committed]**（计划 Task 5 Step 2）：
  /// 回落会把一条读不懂的批次当成"完整导入"，于是同一张图片被永久拦住——
  /// 而用户看到的只是"这张课表已经导入过"，没有任何线索指向真正的原因。
  static TimetableImportBatchStatus fromStorage(String value) {
    for (final status in TimetableImportBatchStatus.values) {
      if (status.storageValue == value) return status;
    }
    throw UnknownTimetableImportBatchStatusException(value);
  }
}

/// 数据库里出现了枚举不认识的批次状态。
///
/// **它是受控的数据错误**：调用方（历史页、重导入判定）应当把它显示成
/// "这条导入记录的存储状态无法识别，请备份数据库后重试"，
/// 而不是把它当成 `committed` 或 `draft` 继续跑。
final class UnknownTimetableImportBatchStatusException implements Exception {
  const UnknownTimetableImportBatchStatusException(this.storageValue);

  final String storageValue;

  @override
  String toString() =>
      'UnknownTimetableImportBatchStatusException($storageValue)';
}

final class TimetableImportBatch {
  const TimetableImportBatch({
    required this.id,
    required this.termId,
    required this.sourceImageHash,
    required this.sourceFileName,
    required this.status,
    required this.createdEventCount,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String termId;
  final String sourceImageHash;
  final String sourceFileName;
  final TimetableImportBatchStatus status;
  final int createdEventCount;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

final class TimetableImportSeriesWrite {
  const TimetableImportSeriesWrite({
    required this.event,
    required this.rule,
    this.exclusions = const [],
  });

  final CalendarEvent event;
  final RecurrenceRule rule;
  final List<TimetableImportExclusion> exclusions;

  TimetableImportSeriesWrite copyWith({
    CalendarEvent? event,
    RecurrenceRule? rule,
    List<TimetableImportExclusion>? exclusions,
  }) => TimetableImportSeriesWrite(
    event: event ?? this.event,
    rule: rule ?? this.rule,
    exclusions: exclusions ?? this.exclusions,
  );
}

final class TimetableImportExclusion {
  const TimetableImportExclusion({
    required this.id,
    required this.occurrenceStartUtc,
  });

  final String id;
  final DateTime occurrenceStartUtc;
}

final class TimetableImportCommit {
  TimetableImportCommit({
    required this.batchId,
    required this.termId,
    required this.sourceImageHash,
    required this.sourceFileName,
    required this.createdAtUtc,
    required List<TimetableImportSeriesWrite> series,
  }) : series = List.unmodifiable(series) {
    if (!createdAtUtc.isUtc) {
      throw ArgumentError.value(createdAtUtc, 'createdAtUtc', 'Must be UTC.');
    }
  }

  final String batchId;
  final String termId;
  final String sourceImageHash;
  final String sourceFileName;
  final DateTime createdAtUtc;
  final List<TimetableImportSeriesWrite> series;

  TimetableImportBatch get batch => TimetableImportBatch(
    id: batchId,
    termId: termId,
    sourceImageHash: sourceImageHash,
    sourceFileName: sourceFileName,
    status: TimetableImportBatchStatus.committed,
    createdEventCount: series.length,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: createdAtUtc,
  );
}

final class RollbackPreview {
  const RollbackPreview({
    required this.batchId,
    required this.eventIds,
    required this.protectedEventIds,
  });

  final String batchId;
  final Set<String> eventIds;
  final Set<String> protectedEventIds;
}

final class RollbackResult {
  const RollbackResult({
    required this.batchId,
    required this.deletedEventCount,
  });

  final String batchId;
  final int deletedEventCount;
}

final class DuplicateTimetableImportException implements Exception {
  const DuplicateTimetableImportException(this.existingBatchId);
  final String existingBatchId;
}

final class ProtectedTimetableEventsException implements Exception {
  const ProtectedTimetableEventsException(this.eventIds);
  final Set<String> eventIds;
}

abstract interface class TimetableImportRepository {
  Future<TimetableImportBatch> commit(TimetableImportCommit request);

  Future<RollbackPreview> inspectRollback(String batchId);

  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  });
}
