import 'dart:collection';

import 'package:personal_planner/domain/models/task.dart';

final class AnalyticsFilter {
  AnalyticsFilter({
    required this.startUtc,
    required this.endUtc,
    Set<String> areaIds = const {},
    Set<String> projectIds = const {},
    Set<String> tags = const {},
    Set<TaskStatus> statuses = const {},
  }) : areaIds = UnmodifiableSetView(Set.of(areaIds)),
       projectIds = UnmodifiableSetView(Set.of(projectIds)),
       tags = UnmodifiableSetView(Set.of(tags)),
       statuses = UnmodifiableSetView(Set.of(statuses)) {
    if (!startUtc.isUtc || !endUtc.isUtc) {
      throw ArgumentError('Analytics range must use UTC instants.');
    }
    if (!startUtc.isBefore(endUtc)) {
      throw ArgumentError('Analytics range must have positive duration.');
    }
  }

  final DateTime startUtc;
  final DateTime endUtc;
  final Set<String> areaIds;
  final Set<String> projectIds;
  final Set<String> tags;
  final Set<TaskStatus> statuses;
}

final class RatioMetric {
  const RatioMetric({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;

  bool get isAvailable => denominator > 0;
  double? get ratio => isAvailable ? numerator / denominator : null;
}

final class LifeQuotaMetric {
  const LifeQuotaMetric({
    required this.targetMinutes,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final int targetMinutes;
  final int plannedMinutes;
  final int actualMinutes;

  RatioMetric get plannedProgress =>
      RatioMetric(numerator: plannedMinutes, denominator: targetMinutes);

  RatioMetric get actualProgress =>
      RatioMetric(numerator: actualMinutes, denominator: targetMinutes);
}

final class DomainTimeMetric {
  const DomainTimeMetric({
    required this.id,
    required this.label,
    required this.plannedMinutes,
    required this.actualMinutes,
    this.fixedMinutes = 0,
    this.storedColorArgb = 0,
    this.sortOrder = 0,
  });

  final String id;
  final String label;

  /// 已确认计划块落在该领域的分钟数（任务侧）。
  final int plannedMinutes;

  /// **固定日程**（课表、会议等）落在该领域的分钟数。
  ///
  /// **为什么必须和计划块分开记**：2026-10-06 的反馈是"领域时间分配为什么不把固定日程统计进去，
  /// 有的固定日程不是也有领域的吗"——此前数据集里**根本没有日历事件**，于是领域占比只统计了任务
  /// 计划块。用户库里固定日程 19 场（16 场带领域）而计划块只有 6 块，占比因此严重失真。
  /// 分开记是为了界面能说清"这个领域的时间里有多少是课表、多少是自己排的"，而不是把两者糊成一个
  /// 说不清来源的数字。
  final int fixedMinutes;

  final int actualMinutes;

  /// 领域上存储的颜色与排序位（见 [AnalyticsAreaFact] 的说明）。
  /// 统计页的「领域占比」用它取色，**不再按下标另编一套**（§11："图表不得重新分配颜色"）。
  final int storedColorArgb;
  final int sortOrder;

  /// 该领域的**总占用时间**：计划块 + 固定日程。
  ///
  /// "领域时间分配"看的是这个——用户要的是"我的时间分给了哪些领域"，不是"我排了多少任务"。
  int get totalMinutes => plannedMinutes + fixedMinutes;
}

/// 一场固定日程（已按重复规则展开、已应用单次例外）。
///
/// 展开与例外处理**不在统计层重做**：`DriftCalendarRepository.occurrencesBetween` 已经把它们和
/// 日历页共用同一套实现，统计层再抄一遍就等于又开了第二份约定。
final class AnalyticsFixedFact {
  const AnalyticsFixedFact({
    required this.title,
    required this.areaId,
    required this.areaName,
    required this.isLife,
    required this.startUtc,
    required this.endUtc,
  });

  final String title;
  final String? areaId;
  final String? areaName;

  /// 所属领域是否被标记为"计入个人生活时间"（与任务侧同一判据，不按名字猜）。
  final bool isLife;

  final DateTime startUtc;
  final DateTime endUtc;
}

final class DailyTimeMetric {
  const DailyTimeMetric({
    required this.dayUtc,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  final DateTime dayUtc;
  final int plannedMinutes;
  final int actualMinutes;
}

final class RankedMetric {
  const RankedMetric(this.code, this.count);

  final String code;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is RankedMetric && other.code == code && other.count == count;

  @override
  int get hashCode => Object.hash(code, count);
}

final class SuggestionBehaviorMetric {
  const SuggestionBehaviorMetric({
    required this.accepted,
    required this.modified,
    required this.rejected,
  });

  final int accepted;
  final int modified;
  final int rejected;

  RatioMetric get acceptanceRate => RatioMetric(
    numerator: accepted,
    denominator: accepted + modified + rejected,
  );
}

/// 一个精力区间，用**本地时刻**的分钟数表示（0–1439）。
///
/// 与排程侧的 `EnergyWindow` 分开定义，而且这里只带**标签字符串**而不是 `EnergyLevel`：
/// 统计模型因此不必依赖排程规则模型，两个模块各自演进时不会互相牵动。
final class AnalyticsEnergyWindow {
  const AnalyticsEnergyWindow({
    required this.label,
    required this.startMinute,
    required this.endMinute,
    required this.isWeekend,
  });

  final String label;
  final int startMinute;
  final int endMinute;

  /// `true` 只适用于周末、`false` 只适用于工作日、**`null` 表示每天都适用**。
  ///
  /// 用三态而不是布尔：用户的默认区间是"不分工作日与周末"（`DayKind.any`），把它当成
  /// "只适用工作日"会让周末的投入全部落进"未标记"，看起来像数据丢了。
  final bool? isWeekend;
}

/// 某个精力时段里的**完成效果**（FR-STAT-05）。
///
/// 两个数字都按**本地时刻**归桶：实际投入按每段专注的开始时刻所在区间计入，完成数按任务
/// 完成时刻所在区间计入——因此"高精力时段"说的是用户自己的生活时间，与库里存的 UTC 无关。
final class EnergyPeriodMetric {
  const EnergyPeriodMetric({
    required this.label,
    required this.actualMinutes,
    required this.completedTasks,
  });

  final String label;
  final int actualMinutes;
  final int completedTasks;
}

/// 一段**保护时间**（睡眠／用餐／固定休息），用本地分钟区间表示。
///
/// 与精力区间同样只带标签字符串，统计模型因此不依赖排程规则模型。
final class AnalyticsProtectedWindow {
  const AnalyticsProtectedWindow({
    required this.label,
    required this.startMinute,
    required this.endMinute,
    required this.isWeekend,
  });

  final String label;
  final int startMinute;
  final int endMinute;

  /// 与 [AnalyticsEnergyWindow.isWeekend] 同为三态：`null` 表示每天都适用。
  final bool? isWeekend;
}

/// 一个领域在统计里的事实：名字与"是否计入个人生活时间"。
///
/// **为什么数据集要带全部领域**：用户要看的「领域覆盖缺口」问的是"哪些领域我根本没排"，
/// 而那些领域的 `domainDistribution` 里**根本不会出现**（没有分钟数就没有行）。只靠有数据的
/// 那一侧永远算不出"零占用的领域"。
final class AnalyticsAreaFact {
  const AnalyticsAreaFact({
    required this.id,
    required this.name,
    required this.isLife,
    this.storedColorArgb = 0,
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  final bool isLife;

  /// 领域上**存储的**颜色（0 表示"用户没选过颜色"）。
  ///
  /// **为什么不在这里就解析成最终 ARGB**：解析规则属于表示层（见
  /// `lib/core/area_palette.dart` 的 `resolveAreaColorArgb`），领域模型不该知道调色板。
  /// 这里原样带出来，由界面用**同一个**解析器算——这样"统计页的颜色"与"今日页、日历页的颜色"
  /// 在定义上就是同一个函数，不可能漂移。
  final int storedColorArgb;

  /// 排序位：`storedColorArgb == 0` 时按它从调色板取默认色（与其它页面同一规则）。
  final int sortOrder;
}

/// **休息时长本身**：每类保护窗口在范围内有多少时间，其中被安排占用多少。
///
/// 这是 2026-10-06 用户确认的"好好休息"三条里的第一条（A）。此前那一节的旧口径是"保护窗口被
/// **实际专注**占用即算被牺牲"，而用户明确要求把实际投入从统计里全部拿掉——因此这里改成看
/// **计划/固定日程有没有排进保护窗口**：那是用户自己规划的结果，也正是"我规划的合不合理"要问的。
final class RestWindowMetric {
  const RestWindowMetric({
    required this.label,
    required this.minutes,
    required this.invadedMinutes,
  });

  /// 睡眠 / 午餐 / 晚餐 / 固定休息。
  final String label;

  /// 该类窗口在筛选范围内的**总时长**（按天累加，整天数 × 每天区间）。
  final int minutes;

  /// 其中**被已确认计划块或固定日程占用**的分钟数。
  final int invadedMinutes;

  int get freeMinutes => minutes - invadedMinutes;
}

/// 休息总览：各类窗口 + 范围内的本地天数。
final class RestSummaryMetric {
  const RestSummaryMetric({required this.windows, required this.days});

  final List<RestWindowMetric> windows;

  /// 范围内的**本地日数**（用本地日界数，不用 UTC 时长除 24——夏令时下不相等）。
  final int days;

  int get totalMinutes =>
      windows.fold<int>(0, (sum, window) => sum + window.minutes);

  int get invadedMinutes =>
      windows.fold<int>(0, (sum, window) => sum + window.invadedMinutes);

  int get freeMinutes => totalMinutes - invadedMinutes;

  /// **休息达成率**：没被安排占用的比例（0..1）。
  ///
  /// 总时长为 0（用户把保护时间全关了）时返回 `1`：不显示成 0% 达成——"没有保护时间"与
  /// "保护时间全被占了"是两件事，混成一个数字会平白吓人一跳。
  double get achievedRatio =>
      totalMinutes <= 0 ? 1 : freeMinutes / totalMinutes;

  /// 平均每天休息多少分钟（含睡眠）。天数为 0 时返回 0。
  int get averageDailyMinutes => days <= 0 ? 0 : (totalMinutes / days).round();
}

/// 某一天的作息：第一条安排从第几分钟开始、最后一条到第几分钟结束（本地分钟）。
final class DailyRoutineMetric {
  const DailyRoutineMetric({
    required this.localDate,
    required this.firstMinute,
    required this.lastMinute,
  });

  /// 本地日期（只取年月日）。
  final DateTime localDate;

  /// 当天第一条安排的开始（0..1439）。
  final int firstMinute;

  /// 当天最后一条安排的结束（0..1440）。
  final int lastMinute;
}

/// **作息规律性**：每天开工与收工时刻的散布（用户确认的"好好休息"第二条，C）。
///
/// **刻意不是"几点最密"那种谁都知道的东西**：看的是**波动**——每天开工时刻差得多不多、
/// 收工时刻是不是天天往后拖。规律作息与"某天特别晚"在这两个极差上才分得开。
final class RoutineMetric {
  const RoutineMetric({required this.perDay});

  /// 有安排的本地日，按日期升序。没有安排的日子**不出现**——它不是"0 点开工"。
  final List<DailyRoutineMetric> perDay;

  bool get isEmpty => perDay.isEmpty;

  int? get earliestMinute => perDay.isEmpty
      ? null
      : perDay.map((day) => day.firstMinute).reduce((a, b) => a < b ? a : b);

  int? get latestMinute => perDay.isEmpty
      ? null
      : perDay.map((day) => day.lastMinute).reduce((a, b) => a > b ? a : b);

  /// 开工时刻的极差（分钟）：越大越不规律。
  int? get startSpreadMinutes {
    if (perDay.isEmpty) return null;
    final values = perDay.map((day) => day.firstMinute);
    return values.reduce((a, b) => a > b ? a : b) -
        values.reduce((a, b) => a < b ? a : b);
  }

  /// 收工时刻的极差（分钟）：越大说明越常熬夜/越不固定。
  int? get endSpreadMinutes {
    if (perDay.isEmpty) return null;
    final values = perDay.map((day) => day.lastMinute);
    return values.reduce((a, b) => a > b ? a : b) -
        values.reduce((a, b) => a < b ? a : b);
  }

  /// 平均开工/收工时刻（取整分钟）。
  int? get averageStartMinute => perDay.isEmpty
      ? null
      : (perDay.map((day) => day.firstMinute).reduce((a, b) => a + b) /
                perDay.length)
            .round();

  int? get averageEndMinute => perDay.isEmpty
      ? null
      : (perDay.map((day) => day.lastMinute).reduce((a, b) => a + b) /
                perDay.length)
            .round();
}

/// **工作与休息的比例**（用户确认的"好好休息"第三条，D）。
///
/// 四段构成一次**划分**（不重不漏）：工作/学习、生活、空闲的休息时间、未安排。
/// - 工作/学习 = 非生活领域的计划块 + 固定日程
/// - 生活 = 生活领域的计划块 + 固定日程
/// - 休息 = 保护窗口时长 **减去**被上述安排占用的部分（真正空着的那些）
/// - 未安排 = 范围总时长 − 上面三段
final class WorkRestMetric {
  const WorkRestMetric({
    required this.workMinutes,
    required this.lifeMinutes,
    required this.restMinutes,
    required this.idleMinutes,
  });

  final int workMinutes;
  final int lifeMinutes;
  final int restMinutes;
  final int idleMinutes;

  int get totalMinutes => workMinutes + lifeMinutes + restMinutes + idleMinutes;

  /// 生活 + 休息占全部时间的比例（0..1）。用户问的"有没有好好休息"最直接的一个数。
  double get restRatio {
    final total = totalMinutes;
    return total <= 0 ? 0 : (lifeMinutes + restMinutes) / total;
  }

  /// 工作/学习占比（0..1）。
  double get workRatio {
    final total = totalMinutes;
    return total <= 0 ? 0 : workMinutes / total;
  }
}

/// **领域覆盖**：哪些领域在范围内有安排、哪些完全没有（用户确认的"我规划得合理吗"第一条）。
///
/// 用户库里 `科研`/`竞赛`/`工作` 三个领域一个计划块都没有——这不是噪音，正是"规划不合理"最直接的
/// 证据：领域建了却没被排进任何时间。
final class AreaCoverageMetric {
  const AreaCoverageMetric({
    required this.covered,
    required this.uncovered,
    required this.totalAreas,
  });

  /// 有占用的领域名（按名升序）。
  final List<String> covered;

  /// **零占用**的领域名（按名升序）。
  final List<String> uncovered;

  final int totalAreas;

  bool get allCovered => uncovered.isEmpty;

  /// 覆盖率（0..1）。没有任何领域时返回 1——没建领域不是"规划失败"。
  double get coverageRatio => totalAreas <= 0 ? 1 : covered.length / totalAreas;
}

/// **休息保护情况**（FR-STAT-05 的第三项）。
///
/// 口径为**默认选定**并写在这里：`protectedMinutes` 是筛选范围内保护时段的总时长，
/// `overlappedMinutes` 是其中**被实际专注覆盖**的分钟数（按每段专注的实际占比折算）。
/// 之所以选这个口径：两项都由**既有数据**算出，不需要任何新采集。
final class RestProtectionMetric {
  const RestProtectionMetric({
    required this.protectedMinutes,
    required this.overlappedMinutes,
    this.relaxedDays = 0,
  });

  final int protectedMinutes;
  final int overlappedMinutes;

  /// 筛选范围内**被用户临时放宽过**的本地日数（FR-REPLAN-07 的处理入口）。
  ///
  /// 这是"休息保护情况"里唯一一处**用户主动改变硬约束**的记录：放宽的是每日可移动任务上限，
  /// 因此不把它显示出来，用户看到的"保护情况"就少了一层他自己造成的解释。数据来源是
  /// `planning.dateOverride.<yyyy-MM-dd>` 这些设置键，**过期即消失**（清除后该键被删除），
  /// 因此它反映的是当前生效的放宽，而不是历史。
  final int relaxedDays;

  int get preservedMinutes => protectedMinutes - overlappedMinutes;

  /// 界面上那一行的文案（FR-STAT-05 的"休息保护情况"）。
  ///
  /// **放在领域模型上而不是页面里**：一是这句话有真实分支（有没有放宽过），放在页面里就只能
  /// 靠 widget 测试去够它——而它所在的那张卡在 `ListView` 里、视口外**根本不会被构建**，
  /// 本轮第一版页面用例因此一无所获；二是本文件的其余口径（哪些算保护、怎么折算）也都写在
  /// 这里，文案与口径放在一起才不会各说各的。
  ///
  /// **必须点明"睡眠与保护时段"**：这个数字**包含睡眠**（每天 8 小时上下），只说"保护 N 分钟"
  /// 会让用户以为它只算午餐和固定休息，从而觉得数字大得离谱。
  ///
  /// 放宽天数单独成句、为 0 时整句不出现：它是用户**自己**改变硬约束的记录，不说就少一层
  /// 解释；但每行都拖一句"其中 0 天"只会让这一行更难读。
  String get summaryLabel {
    final relaxed = relaxedDays == 0 ? '' : '，其中 $relaxedDays 天临时放宽过每日上限';
    return '休息保护：睡眠与保护时段共 $protectedMinutes 分钟，'
        '其中被专注占用 $overlappedMinutes 分钟$relaxed';
  }

  /// 保护时段中**未被占用**的比例。没有保护时段时不可用（而不是 0）。
  RatioMetric get preservedRate =>
      RatioMetric(numerator: preservedMinutes, denominator: protectedMinutes);
}

final class AnalyticsReport {
  AnalyticsReport({
    required this.filter,
    required this.plannedMinutes,
    required this.actualMinutes,
    required this.completionRate,
    required this.onTimeCompletionRate,
    required this.overdueRate,
    required this.estimateVariance,
    required this.lifeQuota,
    required List<DomainTimeMetric> domainDistribution,
    required List<DailyTimeMetric> trend,
    required List<RankedMetric> commonInterruptions,
    required List<RankedMetric> replanReasons,
    // 带默认值：**"没有精力区间这一节"是合法状态**（未设置时区或用户还没设过区间），
    // 因此不强制每个构造点都写出一个空列表。
    List<EnergyPeriodMetric> energyPeriods = const [],
    // 同样是可空带默认：**"用户没设过保护时段"是合法状态**，此时该节不显示。
    this.restProtection,
    required this.suggestionBehavior,
    // 2026-10-06 统计复盘改版新增的四项。都可空/可空列表：**"没有任何领域"或"没有任何保护
    // 时间"都是合法状态**，此时对应那一节不显示，而不是画一个空壳。
    this.restSummary,
    RoutineMetric? routine,
    this.workRest,
    this.areaCoverage,
  }) : domainDistribution = UnmodifiableListView(domainDistribution),
       trend = UnmodifiableListView(trend),
       commonInterruptions = UnmodifiableListView(commonInterruptions),
       replanReasons = UnmodifiableListView(replanReasons),
       energyPeriods = UnmodifiableListView(energyPeriods),
       routine = routine ?? const RoutineMetric(perDay: []);

  final AnalyticsFilter filter;
  final int plannedMinutes;
  final int actualMinutes;
  final RatioMetric completionRate;
  final RatioMetric onTimeCompletionRate;
  final RatioMetric overdueRate;
  final RatioMetric estimateVariance;
  final LifeQuotaMetric lifeQuota;
  final List<DomainTimeMetric> domainDistribution;
  final List<DailyTimeMetric> trend;
  final List<RankedMetric> commonInterruptions;
  final List<RankedMetric> replanReasons;
  final List<EnergyPeriodMetric> energyPeriods;
  final RestProtectionMetric? restProtection;
  final SuggestionBehaviorMetric suggestionBehavior;

  /// 休息时长本身（睡眠/三餐/固定休息的容量与被侵占量）。没有保护时间时为 `null`。
  final RestSummaryMetric? restSummary;

  /// 作息规律性（每天开工/收工时刻的散布）。范围内没有任何安排时 `isEmpty`。
  final RoutineMetric routine;

  /// 工作 / 生活 / 休息 / 未安排的四段比例。没有保护时间时为 `null`（分母不完整）。
  final WorkRestMetric? workRest;

  /// 领域覆盖：哪些领域零占用。没有任何领域时为 `null`。
  final AreaCoverageMetric? areaCoverage;
}

final class AnalyticsTaskFact {
  AnalyticsTaskFact({
    required this.id,
    required this.title,
    required this.areaId,
    required this.areaName,
    required this.projectId,
    Set<String> tags = const {},
    required this.status,
    required this.estimatedMinutes,
    required this.isLifeTask,
    this.dueAtUtc,
    this.completedAtUtc,
  }) : tags = UnmodifiableSetView(Set.of(tags));

  final String id;
  final String title;
  final String? areaId;
  final String? areaName;
  final String? projectId;
  final Set<String> tags;
  final TaskStatus status;
  final int estimatedMinutes;
  final DateTime? dueAtUtc;
  final DateTime? completedAtUtc;
  final bool isLifeTask;
}

final class AnalyticsPlannedFact {
  const AnalyticsPlannedFact({
    required this.taskId,
    required this.startUtc,
    required this.endUtc,
  });

  final String taskId;
  final DateTime startUtc;
  final DateTime endUtc;
}

final class AnalyticsActualFact {
  const AnalyticsActualFact({
    required this.taskId,
    required this.startUtc,
    required this.endUtc,
    required this.activeMinutes,
  });

  final String taskId;
  final DateTime startUtc;
  final DateTime endUtc;
  final int activeMinutes;
}

enum AnalyticsEventKind { interruption, replan, suggestion }

final class AnalyticsEventFact {
  const AnalyticsEventFact({
    required this.kind,
    required this.code,
    required this.observedAtUtc,
  });

  final AnalyticsEventKind kind;
  final String code;
  final DateTime observedAtUtc;
}

final class AnalyticsDataset {
  AnalyticsDataset({
    required this.weeklyLifeQuotaMinutes,
    List<AnalyticsEnergyWindow> energyWindows = const [],
    List<AnalyticsProtectedWindow> protectedWindows = const [],
    List<DateTime> relaxedLocalDates = const [],
    List<AnalyticsTaskFact> tasks = const [],
    List<AnalyticsPlannedFact> plannedBlocks = const [],
    List<AnalyticsActualFact> actualEntries = const [],
    List<AnalyticsFixedFact> fixedEvents = const [],
    List<AnalyticsEventFact> events = const [],
    List<AnalyticsAreaFact> areas = const [],
  }) : energyWindows = UnmodifiableListView(energyWindows),
       protectedWindows = UnmodifiableListView(protectedWindows),
       relaxedLocalDates = UnmodifiableListView(relaxedLocalDates),
       tasks = UnmodifiableListView(tasks),
       plannedBlocks = UnmodifiableListView(plannedBlocks),
       actualEntries = UnmodifiableListView(actualEntries),
       fixedEvents = UnmodifiableListView(fixedEvents),
       events = UnmodifiableListView(events),
       areas = UnmodifiableListView(areas);

  final int weeklyLifeQuotaMinutes;

  /// 用户的精力区间（本地时刻）。为空时统计侧**不显示**该节，而不是显示一个空壳。
  final List<AnalyticsEnergyWindow> energyWindows;

  /// 用户的保护时间（睡眠／用餐／固定休息），本地时刻。为空时不显示"休息保护"一节。
  final List<AnalyticsProtectedWindow> protectedWindows;

  /// 存在**按日临时例外**的本地日期（FR-REPLAN-07 的"临时放宽每日上限"）。
  ///
  /// **只传日期、不在这里判断是否落在筛选范围内**：筛选范围是 UTC 瞬时，而"哪一天"要按用户
  /// 时区解释——时区只有服务层有。数据层因此只交出原始事实（键里本来就写着本地日期），
  /// 由服务层按本地日与之相交。这与"数据层给事实、应用层做解释"的分工一致。
  final List<DateTime> relaxedLocalDates;
  final List<AnalyticsTaskFact> tasks;
  final List<AnalyticsPlannedFact> plannedBlocks;
  final List<AnalyticsActualFact> actualEntries;

  /// 固定日程（已展开重复、已应用单次例外与删除）。
  ///
  /// 2026-10-06 补上：此前数据集里**完全没有日历事件**，于是"领域时间分配"只统计任务计划块，
  /// 把每周占大头的课表漏掉了——那不是取舍，是漏。
  final List<AnalyticsFixedFact> fixedEvents;
  final List<AnalyticsEventFact> events;

  /// **全部**领域（含零占用的那些）。
  ///
  /// 存在的唯一理由：「领域覆盖缺口」问的是"哪些领域我根本没排"，而那些领域在没有分钟数时
  /// 不会出现在任何分布里，只看有数据的一侧永远算不出它们。
  final List<AnalyticsAreaFact> areas;
}
