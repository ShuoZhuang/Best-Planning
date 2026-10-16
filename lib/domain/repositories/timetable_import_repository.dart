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

/// **导入记录页的一行**（计划 §2.6／Task 10 Step 1）。
///
/// **它是读模型而不是批次本身**：页面要回答的是"这次导入现在还剩什么、
/// 我能不能撤销它"，而那需要把批次、它的锚点与例外一起算过。
///
/// 字段里**没有图片哈希**：它既不该出现在界面上（规范全局不变量第 7 条），
/// 也不该出现在任何导出或日志里。批次 id 只供动作调用，**不直接显示**。
final class TimetableImportHistoryItem {
  const TimetableImportHistoryItem({
    required this.batchId,
    required this.sourceFileName,
    required this.termId,
    required this.termName,
    required this.createdAtUtc,
    required this.createdSeriesCount,
    required this.remainingSeriesCount,
    required this.protectedSeriesCount,
    required this.status,
    required this.canRollback,
    required this.requiresForceConfirmation,
  });

  final String batchId;

  /// 源文件名（**只有文件名，没有绝对路径**）：界面要显示"这是哪张课表"，
  /// 而用户的目录结构不是它该出现在界面的东西。
  final String sourceFileName;

  final String termId;

  /// 学期名称；查不到时为 `null`，界面退回显示"未命名学期"而不是一个 id。
  final String? termName;

  final DateTime createdAtUtc;

  /// 这次导入原创建了多少个系列。
  final int createdSeriesCount;

  /// 现在还剩多少个系列。
  final int remainingSeriesCount;

  /// 其中有多少个**受保护**（用户改过、或挂着他手工加的例外）。
  final int protectedSeriesCount;

  final TimetableImportBatchStatus status;

  /// **仓储事实算出来的**，页面不根据状态文案猜：
  ///
  /// - `committed`：可以撤销；
  /// - `partiallyDeleted`：还有剩余系列时可以撤销；一条都不剩时没有可撤销的东西；
  /// - `rolledBack`：不可再撤销（历史仍然可见）。
  final bool canRollback;

  /// 撤销它必须先让用户确认"会连带去掉被改过的课程"。
  final bool requiresForceConfirmation;
}

abstract interface class TimetableImportRepository {
  Future<TimetableImportBatch> commit(TimetableImportCommit request);

  Future<RollbackPreview> inspectRollback(String batchId);

  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  });

  /// **持久入口的读模型**（计划 §2.6／Task 10 Step 2）。
  ///
  /// 顺序固定为 `createdAtUtc` 降序，时间相同时按 batch id 保证确定性
  /// （否则同一份数据在不同查询顺序下会显示出两个不同的列表）。
  ///
  /// **禁止每个批次调用一次 `inspectRollback()` 形成 N+1**：实现方必须用固定次数的
  /// 批量查询（批次 ＋ 学期、锚点、例外）在内存里按 batch id 分组。
  Future<List<TimetableImportHistoryItem>> listHistory({
    String? termId,
    bool includeRolledBack = true,
  });
}
