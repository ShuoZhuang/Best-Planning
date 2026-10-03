import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/repositories/analytics_event_log.dart';

/// `AnalyticsEventLog` 的 drift 实现：写到既有的 `change_log` 表。
///
/// 复用变更日志而不是新开一张表：统计侧的读取端已经在读这张表，新开表只会让"两侧各写一份
/// 约定"的老问题重演一次。`entityType` 固定为 `analyticsEvent`，使这些行与计划生命周期事件
/// 可以被区分开。
final class DriftAnalyticsEventLog implements AnalyticsEventLog {
  const DriftAnalyticsEventLog(this._database, {required this.idGenerator});

  final db.AppDatabase _database;
  final IdGenerator idGenerator;

  @override
  Future<void> record({
    required AnalyticsEventKind kind,
    required String code,
    required DateTime observedAtUtc,
    String entityId = '',
  }) async {
    if (!observedAtUtc.isUtc) {
      throw ArgumentError.value(observedAtUtc, 'observedAtUtc', 'Must be UTC.');
    }
    // 读取端按第一个冒号切分并要求两侧非空：一个带冒号的 code 会被静默截断，
    // 于是统计里出现一个谁也不认识的词——宁可在写入处就拒绝。
    if (code.isEmpty || code.contains(':')) {
      throw ArgumentError.value(code, 'code', '不能为空，也不能含冒号');
    }
    await _database
        .into(_database.changeLog)
        .insert(
          db.ChangeLogCompanion.insert(
            id: idGenerator.next(),
            entityType: 'analyticsEvent',
            entityId: entityId,
            operation: '${kind.name}:$code',
            changedAtUtc: observedAtUtc.microsecondsSinceEpoch,
            revision: 1,
          ),
        );
  }
}
