import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final class InputSnapshot {
  const InputSnapshot({required this.problem, this.uiState = const {}});

  final ScheduleProblem problem;
  final Map<String, Object?> uiState;
}

final class InputSnapshotBuilder {
  const InputSnapshotBuilder();

  String hash(InputSnapshot snapshot) {
    final bytes = utf8.encode(jsonEncode(_canonical(snapshot.problem)));
    return sha256.convert(bytes).toString();
  }

  Map<String, Object?> _canonical(ScheduleProblem problem) => {
    'planningWindow': {
      'startUtc': problem.planningWindow.startUtc.microsecondsSinceEpoch,
      'endUtc': problem.planningWindow.endUtc.microsecondsSinceEpoch,
    },
    'timeZoneId': problem.timeZoneId,
    'tasks': [
      for (final task in [
        ...problem.tasks,
      ]..sort((a, b) => a.id.compareTo(b.id)))
        {
          'id': task.id,
          'requiredMinutes': task.requiredMinutes,
          'dueAtUtc': task.dueAtUtc?.microsecondsSinceEpoch,
          'availableFromUtc': task.availableFromUtc?.microsecondsSinceEpoch,
          'priority': task.priority.name,
          'energyLevel': task.energyLevel.name,
          'splitMode': task.splitMode.name,
          'minChunkMinutes': task.minChunkMinutes,
          'maxChunkMinutes': task.maxChunkMinutes,
          'isLifeTask': task.isLifeTask,
          // 期望时段参与评分，因此改变它必须改变输入哈希，否则会命中旧提案。
          'preferredStartMinute': task.preferredWindow?.startMinute,
          'preferredEndMinute': task.preferredWindow?.endMinute,
        },
    ],
    'fixedIntervals': _intervals(problem.fixedIntervals),
    'protectedIntervals': _intervals(problem.protectedIntervals),
    'lockedBlocks': [
      for (final block in [
        ...problem.lockedBlocks,
      ]..sort((a, b) => a.id.compareTo(b.id)))
        {
          'id': block.id,
          'taskId': block.taskId,
          'startUtc': block.startUtc.microsecondsSinceEpoch,
          'endUtc': block.endUtc.microsecondsSinceEpoch,
          'locked': block.locked,
        },
    ],
    // 已确认但未锁定的块同样影响排程结果（移动代价），因此必须进入快照哈希。
    'existingBlocks': [
      for (final block in [
        ...problem.existingBlocks,
      ]..sort((a, b) => a.id.compareTo(b.id)))
        {
          'id': block.id,
          'taskId': block.taskId,
          'startUtc': block.startUtc.microsecondsSinceEpoch,
          'endUtc': block.endUtc.microsecondsSinceEpoch,
          'locked': block.locked,
        },
    ],
    // 手动拖动产生的"钉住但落地为未锁定"的块（FR-CAL-05）。它改变输出里的 `locked`
    // 与当日可移动预算，因此必须进哈希——否则同一份 `lockedBlocks` 在两种解释下会算出
    // 同一个哈希，确认阶段就可能接受一份按另一种解释生成的提案。
    'pinnedUnlockedBlockIds': [...problem.pinnedUnlockedBlockIds]..sort(),
    'rules': _rules(problem.rules),
    // ── 逐日规则进哈希（算法 17，计划 Task 2 Step 6）─────────────────────────────
    //
    // **为什么必须进**：算法 17 的排程结果按"每一天自己的规则"变化，而
    // `problem.rules` 只是窗口首日的兼容快照。若只哈希首日规则，用户把**周末**的
    // 每日上限或睡眠改掉之后，同一个哈希仍然命中，确认阶段就会接受一份按旧规则
    // 生成的提案——症状是"我改了设置，预览却说没变化"。
    //
    // 序列化方式必须与插入顺序无关：先按日期升序，再逐日写出完整规则。
    // 反转 `dailyPolicies` 的插入顺序必须得到同一个哈希（由
    // `input_snapshot_builder_test.dart` 钉住）。
    'dailyPolicies': [
      for (final date in problem.dailyPolicies.keys.toList()..sort())
        {
          'localDate': _localDateKey(date),
          'softReserveTargetMinutes':
              problem.dailyPolicies[date]!.softReserveTargetMinutes,
          'rules': _rules(problem.dailyPolicies[date]!.resolvedRules),
        },
    ],
    // 逐周生活配额同理：窗口跨周时后半周属于下一周的规则。
    'weeklyLifeQuotaByWeekStart': [
      for (final monday
          in problem.weeklyLifeQuotaByWeekStart.keys.toList()..sort())
        {
          'weekStart': _localDateKey(monday),
          'quotaMinutes': problem.weeklyLifeQuotaByWeekStart[monday],
        },
    ],
    'preferences': {
      'enabled': problem.preferences.enabled,
      'preferredFocusMinutes': problem.preferences.preferredFocusMinutes,
      'preferredEnergyWindows':
          problem.preferences.preferredEnergyWindows == null
          ? null
          : _energyWindows(problem.preferences.preferredEnergyWindows!),
    },
    // 已确认学习偏好快照：版本由规则内容派生，确认/撤销/停用都会改变哈希
    // （规范 §9.5 / ALG20-066）。
    'preferenceSnapshot': problem.preferenceSnapshot == null
        ? null
        : {
            'enabled': problem.preferenceSnapshot!.enabled,
            'evidenceVersion': problem.preferenceSnapshot!.evidenceVersion,
            'subjects': [
              for (final key
                  in problem.preferenceSnapshot!.bySubject.keys.toList()
                    ..sort())
                {
                  'subjectKey': key,
                  'startMinute': problem
                      .preferenceSnapshot!
                      .bySubject[key]!
                      .preferredWindow
                      ?.startMinute,
                  'endMinute': problem
                      .preferenceSnapshot!
                      .bySubject[key]!
                      .preferredWindow
                      ?.endMinute,
                  'focusMinutes': problem
                      .preferenceSnapshot!
                      .bySubject[key]!
                      .preferredFocusMinutes,
                },
            ],
          },
    // ── 特殊日事实进哈希（算法 20，规范 §5.1 / ALG20-010）──────────────────────
    //
    // 只序列化**影响排程的取值**，不把审计时间戳或来源文本混进来：用户只是撤销一条
    // 从未生效的草稿，不应该让一份合法提案被判为过期。草稿/撤销在装配层已被过滤，
    // 因此这里看到的都是 confirmed。
    'dayExceptions': [
      for (final value in problem.dayExceptions)
        {
          'id': value.id,
          'localDate': _localDateKey(value.localDate),
          'kind': value.kind.name,
          'originalSleepStartOffsetMinutes':
              value.originalSleepStartOffsetMinutes,
          'temporarySleepStartOffsetMinutes':
              value.temporarySleepStartOffsetMinutes,
          'fixedWakeOffsetMinutes': value.fixedWakeOffsetMinutes,
          'recoveryChoice': value.recoveryChoice.name,
          'recoveryLocalDate': value.recoveryLocalDate == null
              ? null
              : _localDateKey(value.recoveryLocalDate!),
        },
    ],
  };

  /// 本地日期的稳定文本键（`2026-10-05`）。
  ///
  /// 不用 `DateTime.toIso8601String()`：它把 `DateTime(y, m, d)` 序列化成
  /// `2026-10-05T00:00:00.000`，多出的时分秒对哈希没有坏处，但这个键同时是
  /// 人类可读的诊断字段，短形式更容易在 diff 里核对。
  String _localDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  List<Map<String, Object?>> _intervals(List<BusyInterval> intervals) => [
    for (final item in [...intervals]..sort((a, b) => a.id.compareTo(b.id)))
      {
        'id': item.id,
        'startUtc': item.range.startUtc.microsecondsSinceEpoch,
        'endUtc': item.range.endUtc.microsecondsSinceEpoch,
      },
  ];

  Map<String, Object?> _rules(PlanningRules rules) => {
    'energyWindows': _energyWindows(rules.energyWindows),
    'protectedTimes': [
      for (final item
          in [...rules.protectedTimes]..sort((a, b) {
            final dayOrder = a.dayKind.index.compareTo(b.dayKind.index);
            if (dayOrder != 0) return dayOrder;
            final kindOrder = a.kind.index.compareTo(b.kind.index);
            if (kindOrder != 0) return kindOrder;
            final startOrder = a.range.startMinute.compareTo(
              b.range.startMinute,
            );
            if (startOrder != 0) return startOrder;
            return a.range.endMinute.compareTo(b.range.endMinute);
          }))
        {
          'kind': item.kind.name,
          'dayKind': item.dayKind.name,
          'startMinute': item.range.startMinute,
          'endMinute': item.range.endMinute,
          'enabled': item.enabled,
        },
    ],
    'sleepStartMinute': rules.sleepRange.startMinute,
    'sleepEndMinute': rules.sleepRange.endMinute,
    'minimumSleepMinutes': rules.minimumSleepMinutes,
    'defaultFocusMinutes': rules.defaultFocusMinutes,
    'breakMinutes': rules.breakMinutes,
    'dailyMovableTaskLimitMinutes': rules.dailyMovableTaskLimitMinutes,
    'weeklyLifeQuotaMinutes': rules.weeklyLifeQuotaMinutes,
    'minChunkMinutes': rules.minChunkMinutes,
    'maxChunkMinutes': rules.maxChunkMinutes,
    'granularityMinutes': rules.granularityMinutes,
  };

  List<Map<String, Object?>> _energyWindows(List<EnergyWindow> windows) {
    final ordered = [...windows]
      ..sort((a, b) {
        final dayOrder = a.dayKind.index.compareTo(b.dayKind.index);
        if (dayOrder != 0) return dayOrder;
        final startOrder = a.range.startMinute.compareTo(b.range.startMinute);
        if (startOrder != 0) return startOrder;
        final endOrder = a.range.endMinute.compareTo(b.range.endMinute);
        if (endOrder != 0) return endOrder;
        return a.level.index.compareTo(b.level.index);
      });
    return [
      for (final window in ordered)
        {
          'dayKind': window.dayKind.name,
          'startMinute': window.range.startMinute,
          'endMinute': window.range.endMinute,
          'level': window.level.name,
        },
    ];
  }
}
