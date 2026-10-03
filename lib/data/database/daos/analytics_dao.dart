import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/services/default_settings.dart';

final class AnalyticsDao implements AnalyticsDataSource {
  const AnalyticsDao(this.database);

  final AppDatabase database;

  @override
  Future<AnalyticsDataset> load(AnalyticsFilter filter) async {
    final tasks = await _tasks(filter);
    final planned = await _planned(filter);
    final actual = await _actual(filter);
    final events = await _events(filter);
    return AnalyticsDataset(
      weeklyLifeQuotaMinutes: await _weeklyLifeQuota(),
      tasks: tasks,
      plannedBlocks: planned,
      actualEntries: actual,
      events: events,
    );
  }

  Future<List<AnalyticsTaskFact>> _tasks(AnalyticsFilter filter) async {
    final query = database.select(database.tasks).join([
      leftOuterJoin(
        database.projects,
        database.projects.id.equalsExp(database.tasks.projectId),
      ),
      leftOuterJoin(
        database.areas,
        database.areas.id.equalsExp(database.projects.areaId),
      ),
    ]);
    if (filter.areaIds.isNotEmpty) {
      query.where(database.areas.id.isIn(filter.areaIds));
    }
    if (filter.projectIds.isNotEmpty) {
      query.where(database.tasks.projectId.isIn(filter.projectIds));
    }
    if (filter.statuses.isNotEmpty) {
      query.where(
        database.tasks.status.isIn(filter.statuses.map((item) => item.name)),
      );
    }
    final rows = await query.get();
    return [
      for (final row in rows)
        _taskFact(
          row.readTable(database.tasks),
          row.readTableOrNull(database.projects),
          row.readTableOrNull(database.areas),
        ),
    ];
  }

  AnalyticsTaskFact _taskFact(Task task, Project? project, Area? area) {
    final status = TaskStatus.values.byName(task.status);
    final completedAt = status == TaskStatus.completed
        ? _instant(task.updatedAtUtc)
        : null;
    final areaName = area?.name;
    return AnalyticsTaskFact(
      id: task.id,
      title: task.title,
      areaId: area?.id,
      areaName: areaName,
      projectId: project?.id,
      status: status,
      estimatedMinutes: task.estimatedMinutes,
      dueAtUtc: task.dueAtUtc == null ? null : _instant(task.dueAtUtc!),
      completedAtUtc: completedAt,
      // 读领域上的生活标记，而不是猜领域名：名字匹配既漏（"家庭""健身"不是生活）
      // 又错（"生活服务业项目"会被算成生活）。见 `LifeAreaLookup`。
      isLifeTask: area?.isLife ?? false,
    );
  }

  Future<List<AnalyticsPlannedFact>> _planned(AnalyticsFilter filter) async {
    final query =
        database.select(database.scheduleBlocks).join([
            innerJoin(
              database.planVersions,
              database.planVersions.id.equalsExp(
                database.scheduleBlocks.planVersionId,
              ),
            ),
          ])
          ..where(database.planVersions.status.equals('confirmed'))
          ..where(
            database.scheduleBlocks.startAtUtc.isSmallerThanValue(
                  filter.endUtc.microsecondsSinceEpoch,
                ) &
                database.scheduleBlocks.endAtUtc.isBiggerThanValue(
                  filter.startUtc.microsecondsSinceEpoch,
                ),
          );
    return [
      for (final row in await query.get())
        AnalyticsPlannedFact(
          taskId: row.readTable(database.scheduleBlocks).taskId,
          startUtc: _instant(row.readTable(database.scheduleBlocks).startAtUtc),
          endUtc: _instant(row.readTable(database.scheduleBlocks).endAtUtc),
        ),
    ];
  }

  Future<List<AnalyticsActualFact>> _actual(AnalyticsFilter filter) async {
    final query = database.select(database.timeEntries)
      ..where(
        (row) =>
            row.recoveryState.equals('confirmed') &
            row.endedAtUtc.isNotNull() &
            row.startedAtUtc.isSmallerThanValue(
              filter.endUtc.microsecondsSinceEpoch,
            ) &
            row.endedAtUtc.isBiggerThanValue(
              filter.startUtc.microsecondsSinceEpoch,
            ),
      );
    return [
      for (final row in await query.get())
        AnalyticsActualFact(
          taskId: row.taskId,
          startUtc: _instant(row.startedAtUtc),
          endUtc: _instant(row.endedAtUtc!),
          activeMinutes: _activeMinutes(row),
        ),
    ];
  }

  int _activeMinutes(TimeEntry row) {
    try {
      final metadata = jsonDecode(row.source) as Map<String, Object?>;
      final microseconds = metadata['activeMicroseconds'];
      if (microseconds is int) {
        return Duration(microseconds: microseconds).inMinutes;
      }
    } on FormatException {
      // Older manually recorded entries may keep a plain source label.
    }
    final elapsed = row.endedAtUtc! - row.startedAtUtc;
    return ((elapsed ~/ Duration.microsecondsPerMinute) - row.pausedMinutes)
        .clamp(0, 1 << 31);
  }

  Future<List<AnalyticsEventFact>> _events(AnalyticsFilter filter) async {
    final query = database.select(database.changeLog)
      ..where(
        (row) =>
            row.changedAtUtc.isBiggerOrEqualValue(
              filter.startUtc.microsecondsSinceEpoch,
            ) &
            row.changedAtUtc.isSmallerThanValue(
              filter.endUtc.microsecondsSinceEpoch,
            ),
      );
    final result = <AnalyticsEventFact>[];
    for (final row in await query.get()) {
      final separator = row.operation.indexOf(':');
      if (separator <= 0 || separator == row.operation.length - 1) continue;
      final prefix = row.operation.substring(0, separator);
      final code = row.operation.substring(separator + 1);
      final kind = switch (prefix) {
        'interruption' => AnalyticsEventKind.interruption,
        'replan' => AnalyticsEventKind.replan,
        'suggestion' => AnalyticsEventKind.suggestion,
        _ => null,
      };
      if (kind == null) continue;
      result.add(
        AnalyticsEventFact(
          kind: kind,
          code: code,
          observedAtUtc: _instant(row.changedAtUtc),
        ),
      );
    }
    return result;
  }

  Future<int> _weeklyLifeQuota() async {
    final query = database.select(database.settings)
      ..where((row) => row.key.equals('planning.userRules.v1'))
      ..limit(1);
    final setting = await query.getSingleOrNull();
    if (setting == null) return DefaultSettings.v1().weeklyLifeQuotaMinutes;
    try {
      final json = jsonDecode(setting.jsonValue) as Map<String, Object?>;
      final common = json['common'] as Map<String, Object?>?;
      return common?['weeklyLifeQuotaMinutes'] as int? ??
          DefaultSettings.v1().weeklyLifeQuotaMinutes;
    } on FormatException {
      return DefaultSettings.v1().weeklyLifeQuotaMinutes;
    }
  }

  static DateTime _instant(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);
}
