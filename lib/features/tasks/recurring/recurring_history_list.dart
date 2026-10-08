import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';

/// 一条历史周期的展示数据：周期实例 ＋ 它那一周的进度。
///
/// **为什么把两者打包成一个值对象**：历史列表要显示的是"某周完成了多少"，而
/// `RecurringTaskCycle` 本身**没有**完成分钟（那是从 `time_entries` 汇总出来的，见 §4.2）。
/// 让列表自己去查分钟，会把一次 N+1 查询和一段格式化逻辑塞进 Widget；由调用方一次算好、
/// 列表只负责画，是这一层唯一该做的事。
final class RecurringHistoryEntry {
  const RecurringHistoryEntry({
    required this.cycle,
    required this.recordedMinutes,
  });

  final RecurringTaskCycle cycle;
  final int recordedMinutes;

  DateTime get periodStartLocalDate => cycle.periodStartLocalDate;
  int get targetMinutes => cycle.effectiveTargetMinutes;
  int get remainingMinutes {
    final value = targetMinutes - recordedMinutes;
    return value < 0 ? 0 : value;
  }

  bool get isMet => recordedMinutes >= targetMinutes;
}

/// 周期目标的历史周次列表（路线图 §3.3、§11 Task 7 Step 3）。
///
/// 每一行回答三个问题：**哪一周、完成多少、结果是什么**。结果用文字而不是只靠颜色
/// （达标 / 未达标 / 已跳过），因为颜色是可选的表达方式，而"这一周到底算不算过了"
/// 是必须读得出的信息。
final class RecurringHistoryList extends StatelessWidget {
  const RecurringHistoryList({
    required this.entries,
    this.onOpen,
    this.emptyHint = '还没有历史周次。',
    super.key,
  });

  final List<RecurringHistoryEntry> entries;

  /// 打开某一周的详情。为 `null` 时行不可点——**不留死入口**。
  final void Function(RecurringHistoryEntry entry)? onOpen;

  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Padding(
        key: const Key('recurring-history-empty'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(emptyHint, style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return Column(
      key: const Key('recurring-history-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          ListTile(
            key: Key(
              'recurring-history-${formatLocalDate(entry.periodStartLocalDate)}',
            ),
            contentPadding: EdgeInsets.zero,
            onTap: onOpen == null ? null : () => onOpen!(entry),
            title: Text('${formatLocalDate(entry.periodStartLocalDate)} 起那一周'),
            subtitle: Text(
              '已完成 ${entry.recordedMinutes}/${entry.targetMinutes} 分钟'
              '${entry.cycle.carryInMinutes > 0 ? '（含结转 ${entry.cycle.carryInMinutes} 分钟）' : ''}',
            ),
            trailing: Text(
              _statusLabel(entry.cycle.status, entry.isMet),
              style: TextStyle(
                color: entry.isMet
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

String _statusLabel(RecurringCycleStatus status, bool isMet) =>
    switch (status) {
      RecurringCycleStatus.met => '已达标',
      RecurringCycleStatus.skipped => '已跳过',
      // `open` 的那一周还在进行中：**不能写成"未达标"**，那是结算之后才成立的说法。
      RecurringCycleStatus.open => isMet ? '已达标' : '进行中',
      RecurringCycleStatus.missed => '未达标',
    };
