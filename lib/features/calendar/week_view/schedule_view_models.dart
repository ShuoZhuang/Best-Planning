import 'package:flutter/material.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/domain/models/time_range.dart';

enum ScheduleItemKind { fixed, protectedTime, task, life }

extension ScheduleItemKindPresentation on ScheduleItemKind {
  String get label => switch (this) {
    ScheduleItemKind.fixed => '固定日程',
    ScheduleItemKind.protectedTime => '保护时间',
    ScheduleItemKind.task => '任务',
    ScheduleItemKind.life => '生活',
  };

  IconData get icon => switch (this) {
    ScheduleItemKind.fixed => Icons.event,
    ScheduleItemKind.protectedTime => Icons.shield_outlined,
    ScheduleItemKind.task => Icons.task_alt,
    ScheduleItemKind.life => Icons.self_improvement,
  };

  Color color(ColorScheme scheme) => switch (this) {
    ScheduleItemKind.fixed => scheme.primaryContainer,
    ScheduleItemKind.protectedTime => scheme.tertiaryContainer,
    ScheduleItemKind.task => scheme.secondaryContainer,
    ScheduleItemKind.life => scheme.surfaceContainerHighest,
  };
}

final class ScheduleViewItem {
  const ScheduleViewItem({
    required this.id,
    required this.title,
    required this.kind,
    required this.range,
    this.explanation,
  });

  final String id;
  final String title;
  final ScheduleItemKind kind;
  final TimeRange range;
  final String? explanation;
}

abstract interface class ScheduleViewSource {
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc);
}

abstract interface class WeekMoveController {
  Future<String?> proposeMove(ScheduleViewItem item, DateTime localDay);
}

abstract interface class MoveDraftSink {
  Future<void> setRequestedMove(ScheduleViewItem item, DateTime localDay);
}

final class PlanningServiceWeekMoveController implements WeekMoveController {
  const PlanningServiceWeekMoveController({
    required this.drafts,
    required this.planning,
  });

  final MoveDraftSink drafts;
  final PlanningService planning;

  @override
  Future<String> proposeMove(ScheduleViewItem item, DateTime localDay) async {
    await drafts.setRequestedMove(item, localDay);
    final proposal = await planning.createProposal();
    return proposal.proposalId;
  }
}

final class EmptyScheduleViewSource implements ScheduleViewSource {
  const EmptyScheduleViewSource();

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value(const []);
}

final class DisabledWeekMoveController implements WeekMoveController {
  const DisabledWeekMoveController();

  @override
  Future<String?> proposeMove(ScheduleViewItem item, DateTime localDay) async =>
      null;
}
