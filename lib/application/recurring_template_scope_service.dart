import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/recurring_cycle_snapshot.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

/// 编辑范围：与设计 §9.1 的三种范围一一对应。
enum RecurringTemplateScope { thisCycle, fromNextWeek, entireSeries }

/// 模板/周实例的可编辑字段。`null` 表示“本次不改”。
final class RecurringTemplateChanges {
  const RecurringTemplateChanges({
    this.title,
    this.notes,
    this.targetMinutes,
    this.priority,
    this.energyLevel,
    this.splitMode,
    this.minChunkMinutes,
    this.maxChunkMinutes,
    this.preferredStartMinute,
    this.preferredEndMinute,
    this.pace,
    this.allowedWeekdaysMask,
  });

  final String? title;
  final String? notes;
  final int? targetMinutes;
  final TaskPriority? priority;
  final TaskEnergyLevel? energyLevel;
  final TaskSplitMode? splitMode;
  final int? minChunkMinutes;
  final int? maxChunkMinutes;
  final int? preferredStartMinute;
  final int? preferredEndMinute;
  final RecurringPace? pace;
  final int? allowedWeekdaysMask;

  bool get isEmpty =>
      title == null &&
      notes == null &&
      targetMinutes == null &&
      priority == null &&
      energyLevel == null &&
      splitMode == null &&
      minChunkMinutes == null &&
      maxChunkMinutes == null &&
      preferredStartMinute == null &&
      preferredEndMinute == null &&
      pace == null &&
      allowedWeekdaysMask == null;
}

/// 1.11.0 周期模板作用域与生命周期（原 1.12 设计 §9、Task 3/4）。
///
/// 历史周快照永不改写；“本周”命中当前开放周，“下周起”命中未来周，“整个系列”还包含
/// 当前周。每种范围同时更新模板与对应快照，不能只改其中一个。
final class RecurringTemplateScopeService {
  RecurringTemplateScopeService({
    required this.templates,
    required this.snapshots,
    required this.cycles,
    required this.tasks,
    required this.zones,
    required this.timeZoneId,
    required this.clock,
  });

  final RecurringTaskRepository templates;
  final DriftRecurringExecutionRepository snapshots;
  final RecurringTaskRepository cycles;
  final TaskRepository tasks;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final Clock clock;

  Future<List<RecurringCycleSnapshot>> updateScope({
    required String templateId,
    required RecurringTemplateChanges changes,
    required RecurringTemplateScope scope,
  }) async {
    if (changes.isEmpty) return const [];
    final template = await templates.findTemplate(templateId);
    if (template == null) return const [];
    final now = clock.nowUtc();
    final current = WeeklyPeriod.forInstant(now, timeZoneId, zones);
    final updated = <RecurringCycleSnapshot>[];
    final all = await snapshots.cycleSnapshotsIntersecting(
      current.startUtc,
      current.endUtc.add(const Duration(days: 365)),
    );
    for (final snapshot in all) {
      final isCurrent =
          !snapshot.periodStartUtc.isBefore(current.startUtc) &&
          snapshot.periodStartUtc.isBefore(current.endUtc);
      final isFuture = !snapshot.periodStartUtc.isBefore(current.endUtc);
      final applies = switch (scope) {
        RecurringTemplateScope.thisCycle => isCurrent && snapshot.isOpen,
        RecurringTemplateScope.fromNextWeek => isFuture,
        RecurringTemplateScope.entireSeries =>
          isFuture || (isCurrent && snapshot.isOpen),
      };
      if (!applies) continue;
      updated.add(await _updateSnapshot(snapshot, changes, now));
    }
    if (scope == RecurringTemplateScope.fromNextWeek ||
        scope == RecurringTemplateScope.entireSeries) {
      await templates.saveTemplate(_patchTemplate(template, changes, now));
    }
    return updated;
  }

  Future<void> pauseUntil(String templateId, DateTime localDate) async {
    final template = await templates.findTemplate(templateId);
    if (template == null) return;
    final until = localDateOnly(localDate);
    await templates.saveTemplate(
      template.copyWith(
        pausedUntilLocalDate: until,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    final now = clock.nowUtc();
    final pauseEnd = zones.localMidnightToUtc(
      shiftLocalDate(until, 1),
      timeZoneId,
    );
    for (final snapshot in await snapshots.cycleSnapshotsIntersecting(
      now,
      pauseEnd,
    )) {
      for (final fragment in await snapshots.fragmentsForCycle(
        snapshot.cycleId,
      )) {
        if (fragment.state != ExecutionFragmentState.planned ||
            fragment.plannedStartUtc.isBefore(now) ||
            fragment.plannedStartUtc.isAfter(pauseEnd)) {
          continue;
        }
        await snapshots.updateFragment(
          fragment.copyWith(
            state: ExecutionFragmentState.withdrawn,
            revision: fragment.revision + 1,
          ),
        );
      }
    }
  }

  Future<void> resume(String templateId) async {
    final template = await templates.findTemplate(templateId);
    if (template == null) return;
    await templates.saveTemplate(
      template.copyWith(
        pausedUntilLocalDate: null,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  Future<void> archive(String templateId) async {
    final template = await templates.findTemplate(templateId);
    if (template == null) return;
    await templates.saveTemplate(
      template.copyWith(
        status: RecurringTemplateStatus.archived,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  /// 跳过本周是显式结算事实，不伪装成 0 分钟达标。
  Future<RecurringCycleSnapshot?> skipCurrentCycle(String templateId) async {
    final template = await templates.findTemplate(templateId);
    if (template == null) return null;
    final now = clock.nowUtc();
    final current = WeeklyPeriod.forInstant(now, timeZoneId, zones);
    final key = formatLocalDate(current.startLocalDate);
    final snapshot = await snapshots.findCycleSnapshotForPeriod(
      templateId,
      key,
    );
    if (snapshot == null || snapshot.isSettled) return snapshot;
    final skipped = snapshot.copyWith(
      state: RecurringCycleStatus.skipped,
      revision: snapshot.revision + 1,
      updatedAtUtc: now,
      settledAtUtc: now,
    );
    await snapshots.upsertCycleSnapshot(skipped);
    final cycle = await cycles.findCycle(templateId, current.startLocalDate);
    if (cycle != null) {
      await cycles.saveCycle(
        cycle.copyWith(status: RecurringCycleStatus.skipped, updatedAtUtc: now),
      );
    }
    return skipped;
  }

  Future<RecurringCycleSnapshot> _updateSnapshot(
    RecurringCycleSnapshot snapshot,
    RecurringTemplateChanges changes,
    DateTime now,
  ) async {
    final targetChanged =
        changes.targetMinutes != null &&
        changes.targetMinutes != snapshot.targetMinutes;
    final updated = snapshot.copyWith(
      title: changes.title,
      notes: changes.notes,
      targetMinutes: changes.targetMinutes,
      priority: changes.priority,
      energyLevel: changes.energyLevel,
      splitMode: changes.splitMode,
      minChunkMinutes: changes.minChunkMinutes,
      maxChunkMinutes: changes.maxChunkMinutes,
      preferredStartMinute: changes.preferredStartMinute,
      preferredEndMinute: changes.preferredEndMinute,
      pace: changes.pace,
      allowedWeekdaysMask: changes.allowedWeekdaysMask,
      revision: snapshot.revision + 1,
      updatedAtUtc: now,
    );
    await snapshots.upsertCycleSnapshot(updated);
    if (targetChanged) {
      final cycle = await cycles.findCycle(
        snapshot.templateId,
        snapshot.periodStartLocalDate,
      );
      if (cycle != null) {
        await cycles.saveCycle(
          cycle.copyWith(
            baseTargetMinutes: updated.targetMinutes,
            updatedAtUtc: now,
          ),
        );
        final task = await tasks.getById(snapshot.transportTaskId);
        if (task != null) {
          final delta = updated.targetMinutes - snapshot.targetMinutes;
          final remaining = (task.remainingMinutes + delta).clamp(0, 1 << 30);
          await tasks.save(
            task.copyWith(
              estimatedMinutes: updated.targetMinutes,
              remainingMinutes: remaining,
              updatedAtUtc: now,
            ),
          );
        }
      }
    }
    return updated;
  }

  RecurringTaskTemplate _patchTemplate(
    RecurringTaskTemplate template,
    RecurringTemplateChanges changes,
    DateTime now,
  ) => template.copyWith(
    title: changes.title,
    notes: changes.notes,
    targetMinutes: changes.targetMinutes,
    priority: changes.priority,
    energyLevel: changes.energyLevel,
    splitMode: changes.splitMode,
    minChunkMinutes: changes.minChunkMinutes,
    maxChunkMinutes: changes.maxChunkMinutes,
    preferredStartMinute: changes.preferredStartMinute,
    preferredEndMinute: changes.preferredEndMinute,
    pace: changes.pace,
    allowedWeekdaysMask: changes.allowedWeekdaysMask,
    updatedAtUtc: now,
  );
}
