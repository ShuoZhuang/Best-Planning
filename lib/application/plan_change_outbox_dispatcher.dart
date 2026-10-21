import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;

/// 提交后副作用的幂等消费者（计划 Task 10 Step 6、DFR-016）。
///
/// **它绝不改变计划事务的结果**：应用事务只负责入队；通知重排、托盘/日历刷新
/// 失败时只更新 outbox 的重试状态，界面仍然显示"计划已更新，提醒正在重试"。
final class PlanChangeOutboxDispatcher {
  PlanChangeOutboxDispatcher({
    required this.database,
    required this.clock,
    required this.onPlanChanged,
    this.maxAttempts = 5,
  });

  final db.AppDatabase database;
  final Clock clock;

  /// 真正的副作用（重新同步提醒、刷新托盘/日历）。失败时抛异常即可。
  final Future<void> Function(db.PlanChangeOutboxData entry) onPlanChanged;

  final int maxAttempts;

  /// 处理所有到期的待办；返回本次完成的条数。
  Future<int> dispatch() async {
    final now = clock.nowUtc();
    final nowMicros = now.microsecondsSinceEpoch;
    final pending =
        await (database.select(database.planChangeOutbox)..where(
              (row) =>
                  row.completedAtUtc.isNull() &
                  row.nextAttemptAtUtc.isSmallerOrEqualValue(nowMicros) &
                  row.attempts.isSmallerThanValue(maxAttempts),
            ))
            .get();
    var completed = 0;
    for (final entry in pending) {
      try {
        await onPlanChanged(entry);
        await (database.update(
          database.planChangeOutbox,
        )..where((row) => row.id.equals(entry.id))).write(
          db.PlanChangeOutboxCompanion(
            completedAtUtc: Value(nowMicros),
            lastErrorCode: const Value(null),
          ),
        );
        completed++;
      } catch (_) {
        final attempts = entry.attempts + 1;
        // 指数退避有上限：2^attempts 秒，最多 5 分钟。
        final backoffSeconds = math.min(math.pow(2, attempts).toInt(), 300);
        await (database.update(
          database.planChangeOutbox,
        )..where((row) => row.id.equals(entry.id))).write(
          db.PlanChangeOutboxCompanion(
            attempts: Value(attempts),
            nextAttemptAtUtc: Value(
              nowMicros + backoffSeconds * Duration.microsecondsPerSecond,
            ),
            // 只写稳定码：异常文本可能含路径或标题（隐私约束）。
            lastErrorCode: const Value('sideEffectFailed'),
          ),
        );
      }
    }
    return completed;
  }

  /// 当前仍待处理的条数（界面用它决定是否显示"提醒正在重试"）。
  Future<int> pendingCount() async {
    final row = await database
        .customSelect(
          'SELECT COUNT(*) AS c FROM plan_change_outbox '
          'WHERE completed_at_utc IS NULL',
        )
        .getSingle();
    return row.read<int>('c');
  }
}
