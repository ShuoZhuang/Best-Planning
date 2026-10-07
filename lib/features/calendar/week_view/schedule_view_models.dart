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
}

/// "调整归属"对话框的领域选项：`id` 用于保存，`name` 用于显示。
final class ScheduleAreaOption {
  const ScheduleAreaOption({required this.id, required this.name});

  final String id;
  final String name;
}

/// 周视图与日视图里相邻日程条目之间的纵向间距。
///
/// 两处共用同一个值：它们展示的是同一批条目，间距不同会让"同日历的两个视图"看起来像
/// 两套界面。此前两处都是 0，卡片彼此紧贴，扫读时容易把上一条的时间读成下一条的。
const double scheduleItemGap = 10;

final class ScheduleViewItem {
  const ScheduleViewItem({
    required this.id,
    required this.title,
    required this.kind,
    required this.range,
    required this.categoryKey,
    required this.categoryLabel,
    required this.categoryColorArgb,
    required this.categorySortOrder,
    this.explanation,
    this.areaId,
    this.isCompleted = false,
  });

  final String id;
  final String title;
  final ScheduleItemKind kind;
  final TimeRange range;
  final String categoryKey;
  final String categoryLabel;
  final int categoryColorArgb;
  final int categorySortOrder;
  final String? explanation;

  /// 这条计划块所属的任务**已经完成**。
  ///
  /// 存在的理由：已确认计划里的块不会因为勾选完成而消失（只有重排才会把它去掉），但它所属的任务
  /// 离开了"未结束任务"集合——此前数据源因此查不到它的标题与领域，卡片退化成标题「已安排任务」、
  /// 分类「无领域任务」，看起来像"勾完之后任务变成了另一个分类"。现在这类块照常显示真实标题与
  /// 领域色，只多一个"已完成"标记。
  final bool isCompleted;

  Color get categoryColor => Color(categoryColorArgb);

  /// 条目所属领域的 id（固定日程用于"调整归属"时预选当前值）。
  ///
  /// 归属由数据源解析成上面的分类展示字段；页面不能再自行查询领域或判断颜色。
  final String? areaId;
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

/// 固定日程条目 id 的命名空间前缀。
///
/// 视图列表把固定日程、保护时间与计划块混在一起，所以条目 id 必须带命名空间；但
/// **日程端口只认领域事件 id**。取用时一律走 [fixedEventId]，不要自己切字符串。
const String scheduleFixedItemPrefix = 'fixed:';

/// 给领域事件 id 套上视图条目的命名空间。
String scheduleFixedItemId(String eventId) =>
    '$scheduleFixedItemPrefix$eventId';

/// 从视图条目里取出**固定日程的领域 id**（去掉命名空间前缀）。
///
/// 只有 `ScheduleItemKind.fixed` 能交给日程删除／改写端口：保护时间是按规则算出来的区间，
/// 任务块属于计划（应当撤销计划，而不是删一条日程）。返回 `null` 表示这一类**不该**走日程
/// 端口，调用方应当不显示该入口。
///
/// **这个函数存在的理由**：把条目 id 原样交给仓储会执行
/// `DELETE ... WHERE id = 'fixed:<uuid>'`——匹配 0 行、不报错，而服务层按幂等语义返回成功，
/// 界面于是显示"已删除"却什么都没删。拖动那条路径早就用 [movableTaskBlockId] 做同样的拆解，
/// 删除与改写此前漏了。
String? fixedEventId(ScheduleViewItem item) {
  if (item.kind != ScheduleItemKind.fixed) return null;
  if (!item.id.startsWith(scheduleFixedItemPrefix)) return null;
  final eventId = item.id.substring(scheduleFixedItemPrefix.length);
  return eventId.isEmpty ? null : eventId;
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
