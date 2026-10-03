import 'package:flutter/material.dart';
import 'package:personal_planner/application/pending_moves.dart';
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

/// 拖动一个可移动任务块（FR-CAL-05）。
///
/// [lock] 默认 `true`：手动放置是用户的显式指令，因此默认不让后续自动调整把它挪走；
/// 用户可以在放手后的确认对话框里取消勾选（这正是"手动移动后**可选择**锁定"）。
abstract interface class WeekMoveController {
  Future<String?> proposeMove(
    ScheduleViewItem item,
    DateTime localDay, {
    bool lock,
  });
}

/// 从视图条目里取出**可移动的计划块 id**（FR-CAL-05 的"可移动任务块"）。
///
/// 只有 `ScheduleItemKind.task` 是可移动的：固定日程与保护时间是硬约束（拖它们不是"移动
/// 计划"而是改日程），生活块与任务块同源但当前由任务侧产生。返回 `null` 表示这一类不可拖动，
/// 调用方应当**什么都不做**——而不是把它当成任务块塞给排程。
String? movableTaskBlockId(ScheduleViewItem item) {
  if (item.kind != ScheduleItemKind.task) return null;
  const prefix = 'block:';
  if (!item.id.startsWith(prefix)) return null;
  final blockId = item.id.substring(prefix.length);
  return blockId.isEmpty ? null : blockId;
}

final class PlanningServiceWeekMoveController implements WeekMoveController {
  const PlanningServiceWeekMoveController({
    required this.drafts,
    required this.planning,
  });

  final MoveDraftSink drafts;
  final ProposalCreator planning;

  @override
  Future<String?> proposeMove(
    ScheduleViewItem item,
    DateTime localDay, {
    bool lock = true,
  }) async {
    final blockId = movableTaskBlockId(item);
    // 不可拖动的条目直接返回 null：界面据 `proposalId == null` 不做任何跳转，因此
    // "保护时间拖不动"表现为没有反应，而不是排出一个把保护时间挪走的计划。
    if (blockId == null) return null;
    drafts.setRequestedMove(
      RequestedMove(
        blockId: blockId,
        localDate: DateTime(localDay.year, localDay.month, localDay.day),
        lock: lock,
      ),
    );
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
  Future<String?> proposeMove(
    ScheduleViewItem item,
    DateTime localDay, {
    bool lock = true,
  }) async => null;
}
