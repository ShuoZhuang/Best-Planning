import 'dart:math' as math;

import 'package:personal_planner/application/recurring_notification_service.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';

/// 把 `RecurringTaskRepository` 适配成提醒层要的**只读**视图（1.8.0，设计规范 §5.2）。
///
/// **为什么需要这个文件**：`RecurringNotificationService` 在 1.7 就写好了、也有测试，
/// 但**生产里从来没有被构造过**——`main.dart` 里根本没有它，因此"周期目标提醒"这一类
/// 在真实运行中永远不会出现。测试全绿而功能不存在，这正是规范 §2.2 说的
/// "周期目标提醒组件已经有开关参数，但页面没有完整加载、保存和传入该值"的同源问题：
/// 组件与它的开关之间缺一条装配链。
///
/// 提醒层只该认识"目标、已记录、状态、缺口"（见 `RecurringNotificationCandidate` 的
/// 说明），因此这个适配器负责把仓储里的行**降维**成那几个数，而不是把仓储直接交进去。
final class RepositoryRecurringCycleReader implements RecurringCycleReader {
  const RepositoryRecurringCycleReader({
    required this.repository,
    required this.periods,
  });

  final RecurringTaskRepository repository;

  /// 周界的来源。用 `RecurringTaskService.periodContaining` 的**同一个实现**
  /// （装配时传 `recurringTasks.periodContaining`）：提醒与界面对"这一周从哪天开始"
  /// 必须给出同一个答案，否则会出现"卡片说这周还差 30 分钟、提醒说还差 170"。
  final WeeklyPeriod Function(DateTime nowUtc) periods;

  @override
  WeeklyPeriod periodContaining(DateTime nowUtc) => periods(nowUtc);

  @override
  Future<List<RecurringNotificationCandidate>> candidatesForWeek(
    WeeklyPeriod period,
  ) async {
    // `WeeklyPeriod.endLocalDate` 是**开区间端点**（下一周的周一），而仓储的区间是
    // **含两端**的。直接传进去会把下一周周一那一行也捞出来，于是下周一刚生成的实例
    // 会在本周的提醒里出现一次。减一天回到本周周日。
    final lastLocalDate = shiftLocalDate(period.endLocalDate, -1);
    final cycles = await repository.listCyclesInRange(
      period.startLocalDate,
      lastLocalDate,
    );
    final candidates = <RecurringNotificationCandidate>[];
    for (final cycle in cycles) {
      final template = await repository.findTemplate(cycle.templateId);
      // **模板不存在的周期不进候选**：读不到标题就没法写出一条有意义的提醒，
      // 而"「」这周还差得多"比不提醒更糟。这与"不给一个点了没反应的入口"同一口径。
      if (template == null) continue;
      final recorded = await repository.recordedMinutesForTask(
        cycle.taskId,
        period.startUtc,
        period.endUtc,
      );
      final target = cycle.effectiveTargetMinutes;
      final remaining = math.max(0, target - recorded);
      if (remaining == 0 && cycle.status != RecurringCycleStatus.open) {
        continue;
      }
      candidates.add(
        RecurringNotificationCandidate(
          templateId: template.id,
          title: template.title,
          targetMinutes: target,
          recordedMinutes: recorded,
          remainingMinutes: remaining,
          status: cycle.status,
          // **容量缺口在这里刻意留 0**：它需要跑一遍排程输入才能算出来，而提醒层
          // 绝不该为了发一条通知去跑排程（见 `schedulingShortfallMinutes` 的说明）。
          // 缺的那一类提醒因此由排程侧自己的缺口卡片承担——那是它本来的位置。
        ),
      );
    }
    return candidates;
  }
}
