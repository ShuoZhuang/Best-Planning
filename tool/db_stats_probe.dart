// 只读探针：为了**挑选统计复盘要做什么**，先看清库里各维度的真实分布。
//
// 与 `db_fingerprint.dart` 同一约定：只读打开，不动正在使用的库。行数只说明"有数据"，
// 分布才说明"这个统计画出来会不会是空的"。
//
// 用法：dart run tool/db_stats_probe.dart <sqlite 路径>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/db_stats_probe.dart <sqlite 路径>');
    exit(2);
  }
  final path = args.first;
  if (!File(path).existsSync()) {
    stderr.writeln('找不到数据库：$path');
    exit(2);
  }

  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    void dump(String title, String sql) {
      stdout.writeln('--- $title');
      for (final row in db.select(sql)) {
        stdout.writeln('    ${row.values.join('  |  ')}');
      }
    }

    dump(
      'change_log 按行为类型（operation 的前缀）',
      "SELECT substr(operation, 1, instr(operation, ':') - 1) AS kind, "
          "substr(operation, instr(operation, ':') + 1) AS code, COUNT(*) AS n "
          "FROM change_log WHERE instr(operation, ':') > 0 "
          "GROUP BY kind, code ORDER BY kind, n DESC",
    );
    dump(
      '任务状态分布',
      'SELECT status, COUNT(*) AS n, SUM(estimated_minutes) AS est_min FROM tasks GROUP BY status ORDER BY n DESC',
    );
    dump(
      '任务优先级 / 精力 / 拆分方式',
      'SELECT priority, energy_level, split_mode, COUNT(*) AS n FROM tasks GROUP BY 1, 2, 3 ORDER BY n DESC',
    );
    dump(
      '实际投入（time_entries）按状态',
      'SELECT recovery_state, COUNT(*) AS n, SUM(paused_minutes) AS paused FROM time_entries GROUP BY 1',
    );
    dump(
      '计划块的解释码与时长',
      "SELECT b.explanation_code, COUNT(*) AS n, "
          "SUM((b.end_at_utc - b.start_at_utc) / 60000000) AS minutes "
          "FROM schedule_blocks b JOIN plan_versions p ON p.id = b.plan_version_id "
          "WHERE p.status = 'confirmed' GROUP BY 1 ORDER BY minutes DESC",
    );
    dump(
      '固定日程（calendar_events）按领域',
      'SELECT COALESCE(a.name, "（无领域）") AS area, COUNT(*) AS n FROM calendar_events e '
          'LEFT JOIN areas a ON a.id = e.area_id GROUP BY 1 ORDER BY n DESC',
    );
    dump(
      '重复规则覆盖（每条的星期掩码与时长）',
      'SELECT weekdays_mask, duration_minutes, interval_weeks, COUNT(*) AS n FROM recurrence_rules GROUP BY 1, 2, 3 ORDER BY n DESC LIMIT 12',
    );
    dump(
      '领域与其生活标记',
      'SELECT name, is_life, color FROM areas ORDER BY sort_order',
    );
    dump(
      '剩余时长修正记录',
      'SELECT previous_minutes, corrected_minutes, (corrected_minutes - previous_minutes) AS delta, corrected_at_utc FROM task_corrections',
    );
    dump(
      '计划版本',
      'SELECT status, algorithm_version, created_at_utc FROM plan_versions ORDER BY created_at_utc',
    );
    // 2026-10-07 排查"已完成待办重复"用：把所有版本的计划块按**任务 + 时间**摊开。
    // 若同一任务的两条来自不同版本且时间**重叠**，那就是重复的来源（重排会把块挪动几分钟）。
    dump(
      '计划块明细（所有版本，按任务与开始时刻）',
      'SELECT b.task_id, p.status AS version_status, b.start_at_utc, b.end_at_utc, '
          'b.id AS block_id, p.id AS version_id '
          'FROM schedule_blocks b JOIN plan_versions p ON p.id = b.plan_version_id '
          'ORDER BY b.task_id, b.start_at_utc, p.created_at_utc DESC',
    );
    dump(
      '同一任务在同一时刻出现多次的情况（重复候选）',
      'SELECT b.task_id, b.start_at_utc, COUNT(*) AS n, '
          'GROUP_CONCAT(p.status) AS versions '
          'FROM schedule_blocks b JOIN plan_versions p ON p.id = b.plan_version_id '
          'GROUP BY b.task_id, b.start_at_utc HAVING n > 1 ORDER BY n DESC LIMIT 20',
    );
    dump(
      '任务与其状态（最近 20 条）',
      'SELECT id, title, status, remaining_minutes FROM tasks '
          'ORDER BY updated_at_utc DESC LIMIT 20',
    );
    dump(
      '学期',
      'SELECT name, first_week_monday_local_date, total_weeks, time_zone_id FROM academic_terms',
    );
    dump('设置键', 'SELECT key FROM settings ORDER BY key');
  } finally {
    db.close();
  }
}
