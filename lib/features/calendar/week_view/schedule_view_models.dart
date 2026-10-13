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

/// 周期目标卡片上那一行进度（M6，路线图 §3.3 最后一条）。
///
/// **"本周已完成"与"本段"必须分开写，而且不能用"已安排"这个词**：前者是 `time_entries`
/// 里真实记录下来的投入，后者是排进日历的分钟。§3.3 明确要求"不能把已安排误写成已完成"
/// ——两者的数字在用户眼里几乎一样，措辞是唯一能区分它们的东西。
///
/// 数据由 `RepositoryScheduleViewSource` 从周期服务取（那里有模板与本周实例），页面只负责画。
final class RecurringGoalBadge {
  const RecurringGoalBadge({
    required this.templateId,
    required this.title,
    required this.recordedMinutes,
    required this.targetMinutes,
  });

  final String templateId;
  final String title;

  /// 本周已记录分钟（专注 ＋ 手动补记）。
  final int recordedMinutes;

  /// 本周有效目标（含结转）。
  final int targetMinutes;

  /// 达标文案：**不同的措辞表达"做到了"与"排进了"**。
  bool get isMet => recordedMinutes >= targetMinutes;

  /// 卡片上那一行字。达成与未达成分开写，让用户一眼看出这一周到底做没做到。
  String get label => isMet
      ? '本周已完成 $recordedMinutes/$targetMinutes 分钟（已达标）'
      : '本周已完成 $recordedMinutes/$targetMinutes 分钟';
}

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
    this.taskId,
    this.isCompleted = false,
    this.recurringGoal,
    this.notes = '',
    this.repeats = false,
    this.updatedAtUtc,
    this.fromRules = false,
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

  /// 这一条属于某个**周期目标**那一周的实例时的展示数据（M6，§3.3 最后一条）。
  ///
  /// 为空表示"这不是周期目标的条目"，此时今日页与周视图的卡片保持原样——因此这个字段
  /// 是**纯增量**的，不会改变固定日程与保护时间的显示。
  final RecurringGoalBadge? recurringGoal;

  Color get categoryColor => Color(categoryColorArgb);

  /// 条目所属领域的 id（固定日程用于"调整归属"时预选当前值）。
  ///
  /// 归属由数据源解析成上面的分类展示字段；页面不能再自行查询领域或判断颜色。
  final String? areaId;

  /// 这条**任务块**属于哪个任务；固定日程与保护时间为 `null`。
  ///
  /// 存在的理由（M4，路线图 §8）：今日页要能就地"开始专注／完成／延后／查看详情"，
  /// 而这一切都必须先知道这条安排属于哪个任务。此前任务 id 只藏在 [id] 的 `'block:'`
  /// 前缀之后，页面要么去拆字符串、要么反过来查计划——两种做法都会让视图层重新认识
  /// 领域结构。数据源本来就有 `block.taskId`，顺手带出来最省事。
  ///
  /// 与 [movableTaskBlockId] 的分工：那个函数给的是**计划块 id**（用于拖动与锁定），
  /// 这个字段给的是**任务 id**（用于打开详情、开始专注、改任务状态）。
  final String? taskId;

  /// 事项的备注（`calendar_events.notes`）。
  ///
  /// **为什么现在才带出来**（课程与保护时间管理修复计划 §2.3）：规范要求
  /// "三种范围都允许修改标题、备注、日期与时间"，而改写对话框此前**只有日期与时间** ——
  /// 备注在视图条目里根本不存在，因此对话框无从预填，用户也就无从修改。
  ///
  /// 课表导入还把**教师名**写在这一列里；因此日视图改写对话框预填它时必须让用户
  /// 看得见内容，而不是显示一个空框（空框会让用户以为备注丢了）。
  final String notes;

  /// 这一条背后**有没有重复规则**（计划 Task 8 Step 3）。
  ///
  /// 日视图据此决定要不要显示"仅本次／此次及以后／整个系列"三个范围选项：
  /// 一条一次性事项上摆三个同义选项，用户会以为它们不同，而实际上选哪个都一样。
  ///
  /// **由数据决定，不靠界面猜**：`CalendarOccurrence.repeats` 是展开器读规则时得到的，
  /// 界面拿不到也推不出它（`ScheduleViewItem` 上没有 `recurrenceRuleId`）。
  final bool repeats;

  /// 页面读到这一条时锚点的修订号（Task 7 Step 4 的乐观并发）。
  ///
  /// 改写时原样带回去：数据库里的值变了就说明别处改过，此时应当让用户重新打开，
  /// 而不是把人家的改动覆盖掉。为空表示无从判断（手工构造的条目）。
  final DateTime? updatedAtUtc;

  /// 这一条是**规则来源**的保护时间（睡眠／早餐／午餐／晚餐／固定休息）。
  ///
  /// 计划 Task 8 Step 3 要求日视图区别对待两类保护时间：
  /// **自定义的**显示"编辑／删除"，**规则来源**的显示"去设置"——因为它们没有
  /// `CalendarEvent` 锚点（计划 §2.3 末段），删不掉也改不了，只能去设置页改规则。
  ///
  /// **不能靠 id 前缀推断**：一类是 `fixed:<eventId>` 而另一类是
  /// `protected:<kind>:<date>:…`，按前缀分辨等于把 id 的拼接格式当成契约——
  /// 那个格式一变，这里就会静默地把"删得掉的"和"删不掉的"弄反。
  final bool fromRules;
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

/// 从视图条目里取出**日程（固定日程或保护时间）的领域 id**（去掉命名空间前缀）。
///
/// **1.8.0：保护时间也可以**（规范 §9.3）。它在数据里就是一个 `CalendarEvent`
/// （`kind: protected`），"仅本次 / 此次及以后 / 整个系列"的改写与删除语义**完全相同**，
/// 因为那套语义由 `CalendarService` 按重复规则实现，与 `kind` 无关。
/// 只认 `fixed` 会让保护时间在日视图里**没有任何编辑或删除入口**——用户建完之后改不了。
///
/// 只有 `ScheduleItemKind.task`（计划块）与 `protectedTime` 的**规则来源**区间不能走这条路：
/// 前者属于计划（应当撤销计划，而不是删一条日程），后者是按规则算出来的、库里没有对应行。
/// 返回 `null` 表示这一类**不该**走日程端口，调用方应当不显示该入口。
String? fixedEventId(ScheduleViewItem item) {
  if (item.kind != ScheduleItemKind.fixed &&
      item.kind != ScheduleItemKind.protectedTime) {
    return null;
  }
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
