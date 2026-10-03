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
    'rules': _rules(problem.rules),
    'preferences': {
      'enabled': problem.preferences.enabled,
      'preferredFocusMinutes': problem.preferences.preferredFocusMinutes,
      'preferredEnergyWindows':
          problem.preferences.preferredEnergyWindows == null
          ? null
          : _energyWindows(problem.preferences.preferredEnergyWindows!),
    },
  };

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
