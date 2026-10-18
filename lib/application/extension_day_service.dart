import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/preference_evidence_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

/// 从排程诊断生成临时延长日候选（规范 §8.2；实施计划 Task 11）。
///
/// **前置条件**：只有正常放置、跨日分配与修复搜索仍留下**硬缺口**时才提出。
/// `budgetExhausted` 与 `invariantViolation` 都不提出——前者还没证明无解，后者是
/// 排程器自身异常；两者都不该让用户"用晚睡来换容量"。
final class ExtensionDayService {
  ExtensionDayService({
    required this.settings,
    required this.dayExceptions,
    required this.zones,
    required this.clock,
    this.rejectionStore,
    this.evidence,
    this.policy = const ExtensionDayPolicy(),
  });

  final SettingsService settings;
  final DayExceptionService dayExceptions;
  final TimeZoneDatabase zones;
  final Clock clock;
  final ExtensionRejectionStore? rejectionStore;

  /// 建议拒绝/接受证据（算法 20，§9.2）。为空时不写证据。
  final PreferenceEvidenceService? evidence;
  final ExtensionDayPolicy policy;

  /// 为 [proposal] 生成最多 3 个稳定排序候选。
  ///
  /// 没有硬缺口、只是预算耗尽、或用户已在同一输入下拒绝过同一候选时返回空列表。
  Future<List<ExtensionDayCandidate>> propose({
    required ScheduleProblem problem,
    required ScheduleProposal proposal,
  }) async {
    if (proposal.outcome != SearchOutcomeKind.hardInfeasible) {
      return const [];
    }
    if (proposal.unscheduled.isEmpty) return const [];

    final taskById = {for (final task in problem.tasks) task.id: task};
    final triggering =
        [
          for (final item in proposal.unscheduled)
            if (taskById[item.taskId] != null) taskById[item.taskId]!,
        ]..sort((a, b) {
          final shortageA = proposal.unscheduled
              .firstWhere((item) => item.taskId == a.id)
              .shortageMinutes;
          final shortageB = proposal.unscheduled
              .firstWhere((item) => item.taskId == b.id)
              .shortageMinutes;
          final order = shortageB.compareTo(shortageA);
          return order != 0 ? order : a.id.compareTo(b.id);
        });

    final minimumSleep = await settings.loadAbsoluteMinimumSleepMinutes();
    final candidates = await _allowedCandidates(problem);
    final built = policy.buildCandidates(
      problem: problem,
      triggeringTasks: triggering,
      allowedDates: candidates,
      absoluteMinimumSleepMinutes: minimumSleep,
      zones: zones,
      nowUtc: clock.nowUtc(),
    );

    final store = rejectionStore;
    if (store == null) return built;
    final visible = <ExtensionDayCandidate>[];
    for (final candidate in built) {
      final key = rejectionKey(
        inputHash: problem.inputHash,
        candidate: candidate,
      );
      if (await store.isRejected(key)) continue;
      visible.add(candidate);
    }
    return List.unmodifiable(visible);
  }

  /// 用户拒绝整组建议后记住它们；同一输入哈希下不再弹出（ALG20-049）。
  Future<void> reject({
    required String inputHash,
    required List<ExtensionDayCandidate> candidates,
  }) async {
    final store = rejectionStore;
    if (store == null) return;
    for (final candidate in candidates) {
      await store.rememberRejected(
        rejectionKey(inputHash: inputHash, candidate: candidate),
      );
      await evidence?.recordSuggestionAction(
        suggestionId: extensionSuggestionId(candidate),
        action: 'rejected',
        suggestionKind: 'temporaryExtensionDay',
      );
    }
  }

  /// 同一个输入下候选参数的稳定键；任务或规则变化会改变 `inputHash`。
  static String rejectionKey({
    required String inputHash,
    required ExtensionDayCandidate candidate,
  }) => '$inputHash|${candidate.stableKey}';

  Future<Set<DateTime>> _allowedCandidates(ScheduleProblem problem) async {
    final allowed = <DateTime>{};
    for (final date in problem.dailyPolicies.keys) {
      if (await dayExceptions.canProposeExtension(date)) allowed.add(date);
    }
    return allowed;
  }

  /// 把用户自选的日期与结束时间转成候选；硬边界不满足时抛出带字段的错误。
  Future<ExtensionDayCandidate> customCandidate({
    required ScheduleProblem problem,
    required DateTime localDate,
    required int temporarySleepStartOffsetMinutes,
    required List<String> triggeringTaskIds,
  }) async {
    final date = normalize(localDate);
    if (!problem.dailyPolicies.containsKey(date)) {
      throw const DayExceptionValidationException({
        'localDate': '该日期不在本次规划窗口内',
      });
    }
    if (!await dayExceptions.canProposeExtension(date)) {
      throw const DayExceptionValidationException({
        'localDate': '该日期不满足临时延长日的连续日或滚动配额限制',
      });
    }
    final dailyPolicy = problem.policyForLocalDate(date);
    final sleep = dailyPolicy.resolvedRules.sleepRange;
    final original = sleep.startMinute;
    final wake = sleep.crossesMidnight
        ? sleep.endMinute + 24 * 60
        : sleep.endMinute;
    final minimumSleep = await settings.loadAbsoluteMinimumSleepMinutes();
    if (temporarySleepStartOffsetMinutes <= original) {
      throw const DayExceptionValidationException({
        'temporarySleepStartOffsetMinutes': '延长后的入睡时间必须晚于原入睡时间',
      });
    }
    if (temporarySleepStartOffsetMinutes > wake - minimumSleep) {
      throw const DayExceptionValidationException({
        'temporarySleepStartOffsetMinutes': '不得突破绝对最低睡眠',
      });
    }
    final triggering = [
      for (final id in triggeringTaskIds)
        for (final task in problem.tasks)
          if (task.id == id) task,
    ];
    if (triggering.isEmpty) {
      throw const DayExceptionValidationException({
        'triggeringTaskIds': '至少需要一件未安排任务作为延长触发任务',
      });
    }
    final window = _offsetWindow(
      date,
      original,
      temporarySleepStartOffsetMinutes,
      problem,
    );
    if (_overlapsHardOccupancy(problem, window)) {
      throw const DayExceptionValidationException({
        'temporarySleepStartOffsetMinutes': '该时段与固定日程、保护时间或锁定块重叠',
      });
    }
    final usable = triggering.any(
      (task) =>
          (task.dueAtUtc == null || task.dueAtUtc!.isAfter(window.startUtc)) &&
          (task.availableFromUtc == null ||
              task.availableFromUtc!.isBefore(window.endUtc)),
    );
    if (!usable) {
      throw const DayExceptionValidationException({
        'temporarySleepStartOffsetMinutes': '触发任务在该时段的截止或最早开始之外',
      });
    }
    final built = policy.buildCandidates(
      problem: problem,
      triggeringTasks: triggering,
      allowedDates: {date},
      absoluteMinimumSleepMinutes: minimumSleep,
      zones: zones,
      nowUtc: clock.nowUtc(),
    );
    final match = built
        .where(
          (candidate) =>
              candidate.temporarySleepStartOffsetMinutes ==
              temporarySleepStartOffsetMinutes,
        )
        .firstOrNull;
    if (match != null) return match;
    // 自定义时间是用户**精确选择**的，不能因为默认候选偏爱"更短睡眠"而丢掉。
    // 用同一个窗口重新计算可增加的分钟数；硬边界已经在上方校验过。
    var added = 0;
    for (final task in triggering) {
      final gain = _gainForTask(
        task,
        window,
        dailyPolicy.resolvedRules.granularityMinutes,
      );
      if (gain > added) added = gain;
    }
    return ExtensionDayCandidate(
      localDate: date,
      originalSleepStartOffsetMinutes: original,
      temporarySleepStartOffsetMinutes: temporarySleepStartOffsetMinutes,
      fixedWakeOffsetMinutes: wake,
      addedPlaceableMinutes: added,
      sleepLossMinutes: temporarySleepStartOffsetMinutes - original,
      triggeringTaskIds: [...triggeringTaskIds]..sort(),
      stableKey:
          '${formatLocalDate(date)}|$temporarySleepStartOffsetMinutes|'
          '$wake|${([...triggeringTaskIds]..sort()).join(',')}',
    );
  }
}

extension on ExtensionDayService {
  TimeRange _offsetWindow(
    DateTime date,
    int start,
    int end,
    ScheduleProblem problem,
  ) => TimeRange(
    startUtc: _offsetToUtc(date, start, problem),
    endUtc: _offsetToUtc(date, end, problem),
  );

  DateTime _offsetToUtc(DateTime date, int offset, ScheduleProblem problem) {
    final dayOffset = offset ~/ (24 * 60);
    final minute = offset % (24 * 60);
    return zones.localDateTimeToUtc(
      DateTime(date.year, date.month, date.day + dayOffset),
      minute,
      problem.timeZoneId,
    );
  }

  bool _overlapsHardOccupancy(ScheduleProblem problem, TimeRange window) {
    bool overlaps(TimeRange other) =>
        window.startUtc.isBefore(other.endUtc) &&
        other.startUtc.isBefore(window.endUtc);
    return problem.fixedIntervals.any((item) => overlaps(item.range)) ||
        problem.protectedIntervals.any((item) => overlaps(item.range)) ||
        problem.lockedBlocks.any((item) => overlaps(item.range));
  }

  int _gainForTask(SchedulableTask task, TimeRange window, int granularity) {
    final due = task.dueAtUtc;
    var end = window.endUtc;
    if (due != null && due.isBefore(end)) end = due;
    final minutes = end.difference(window.startUtc).inMinutes;
    if (minutes <= 0) return 0;
    final usable = (minutes ~/ granularity) * granularity;
    if (task.splitMode == TaskSplitMode.continuous) {
      return usable >= task.requiredMinutes ? task.requiredMinutes : 0;
    }
    final minChunk = task.minChunkMinutes <= 0
        ? granularity
        : task.minChunkMinutes;
    if (usable < minChunk) return 0;
    return usable < task.requiredMinutes ? usable : task.requiredMinutes;
  }
}
