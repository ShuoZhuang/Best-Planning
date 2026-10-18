import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';

final class AvailabilityInput {
  AvailabilityInput({
    required this.planningWindow,
    required this.timeZoneId,
    required this.rules,
    required Map<DateTime, DailySchedulingPolicy> dailyPolicies,
    List<TimeRange> fixedIntervals = const [],
    List<TimeRange> protectedIntervals = const [],
    List<TimeRange> lockedBlocks = const [],
    List<TimeRange> chargedMovableBlocks = const [],
  }) : dailyPolicies = UnmodifiableMapView({
         for (final entry in dailyPolicies.entries)
           normalizeLocalDate(entry.key): entry.value,
       }),
       fixedIntervals = UnmodifiableListView(fixedIntervals),
       protectedIntervals = UnmodifiableListView(protectedIntervals),
       lockedBlocks = UnmodifiableListView(lockedBlocks),
       chargedMovableBlocks = UnmodifiableListView(chargedMovableBlocks) {
    if (dailyPolicies.isEmpty) {
      throw ArgumentError.value(
        dailyPolicies,
        'dailyPolicies',
        '可用时间分析必须按日取规则，不得回退到窗口首日',
      );
    }
  }

  final TimeRange planningWindow;
  final String timeZoneId;

  /// **兼容快照**：算法 17 里它只用于"任务默认值"一类的兜底读取。
  ///
  /// 任何**按日期变化**的量（睡眠、粒度、保护时间、每日上限）都必须改读
  /// [dailyPolicies]，否则会再次出现"周末套用周一上限"这一整类缺陷。
  final PlanningRules rules;

  /// 逐日完整解析后的规则。**这是本层唯一的事实源。**
  final Map<DateTime, DailySchedulingPolicy> dailyPolicies;

  final List<TimeRange> fixedIntervals;
  final List<TimeRange> protectedIntervals;
  final List<TimeRange> lockedBlocks;

  /// 已经占住时间、**但落地为未锁定**的块（FR-CAL-05 里"拖动了但没锁定"的那一支）。
  ///
  /// 它们与 `lockedBlocks` 一样从可用时间里扣除（因此候选不会压上去），但**必须计入当日
  /// 可移动任务预算**：`PlanValidator` 是按"未锁定块"统计每日上限的，若这里不扣，同一段时长
  /// 在两侧算法不同，会凭空产生 `dailyLimitExceeded`，把一次合法的手动移动判为无效提案。
  final List<TimeRange> chargedMovableBlocks;
}

final class AvailabilitySlot {
  const AvailabilitySlot({required this.range, required this.localDate});

  final TimeRange range;
  final DateTime localDate;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;

  @override
  bool operator ==(Object other) =>
      other is AvailabilitySlot &&
      other.range == range &&
      other.localDate == localDate;

  @override
  int get hashCode => Object.hash(range, localDate);
}

/// 一段空闲被**哪几类**硬占用挡住的标签（1.8.0，「可见空闲却报容量不足」专项）。
///
/// 四个取值与 `ScheduleProblem` 的四类占用一一对应。睡眠之所以与保护时间分开：
/// 它们的来源、可编辑性与用户要做的处置都不同（"早点睡"与"改保护时间"是两回事）。
enum AvailabilityBlockerKind {
  /// 固定日程（含课表课程结束后的缓冲）。
  fixed,

  /// 保护时间：规则来源（午餐／晚餐／固定休息）与用户自建的日历事项。
  protected,

  /// 睡眠。
  sleep,

  /// 锁定计划块，以及"拖动了但没锁定"（`chargedMovableBlocks`）的那些。
  locked,
}

/// 一段被占用且**带来源标签**的区间。
///
/// [kinds] 是集合而不是单值：同一段分钟可能同时被固定日程与保护时间覆盖
/// （课表的缓冲时间叠在午餐上），而容量只能扣一次。修复前这件事没有任何可核对的形式 ——
/// "总容量扣了几次"只能靠读代码猜。
final class BlockedAvailabilitySegment {
  BlockedAvailabilitySegment({
    required this.range,
    required Set<AvailabilityBlockerKind> kinds,
  }) : kinds = UnmodifiableSetView(Set.of(kinds));

  final TimeRange range;
  final Set<AvailabilityBlockerKind> kinds;

  int get durationMinutes => range.durationMinutes;
}

/// 规划窗口内空闲与占用的**完整分析**（`AvailabilityBuilder.build` 的详细形式）。
final class AvailabilityAnalysis {
  AvailabilityAnalysis({
    required List<AvailabilitySlot> slots,
    required List<AvailabilitySlot> hardFreeSlots,
    required List<BlockedAvailabilitySegment> blockedSegments,
    required this.calendarGapMinutes,
    required this.hardFreeMinutes,
  }) : slots = UnmodifiableListView(List.of(slots)),
       hardFreeSlots = UnmodifiableListView(List.of(hardFreeSlots)),
       blockedSegments = UnmodifiableListView(List.of(blockedSegments));

  /// 与 `build(input)` **逐值相同**的空闲时段（见 `build` 的转发）。
  ///
  /// 算法 17 里它的准确名字是**视觉空白**：窗口扣除固定、保护、睡眠、课程过渡
  /// **以及基线里占住时间的任务块**之后，按粒度对齐的区间并集（计划 §2 术语表）。
  final List<AvailabilitySlot> slots;

  /// **日硬空闲**：只扣固定、保护、睡眠与课程过渡，**不扣任何任务块**（计划 §2 术语表）。
  ///
  /// 与 [slots] 出自**同一次扫线**，因此两者不可能各算一套口径——这正是计划
  /// §1.2 第 1 条与 §11「不允许让容量分析器、诊断器和引擎各自重算一份空闲时间」
  /// 所要求的形式。
  ///
  /// 锁定块与"拖动了但没锁定"的块只缩小 [slots]，不缩小 [hardFreeSlots]；
  /// 它们同时进入当日**已用量**（`usedMovableMinutes`），于是"硬空闲 240、
  /// 锁定任务 60、每日上限 180"会得到 `hardFree=240`、`calendarGap=180`、
  /// `licensed=180`、`used=60`、`remaining=120`，而不是 60。
  final List<AvailabilitySlot> hardFreeSlots;

  /// 规划窗口内被占用的分段，带来源标签，按起点升序、互不重叠。
  final List<BlockedAvailabilitySegment> blockedSegments;

  /// 规划窗口扣除全部占用（含 `chargedMovableBlocks`）并按粒度对齐后的空闲分钟并集。
  ///
  /// **它恒等于 `slots.sum(durationMinutes)`**，这条等式由
  /// `availability_builder_test.dart` 钉住：两个数字一旦不一致，就说明有人把
  /// "空闲"算成了两件事。
  final int calendarGapMinutes;

  /// 规划窗口扣除**非任务**硬占用并按粒度对齐后的空闲分钟并集。
  ///
  /// **它恒等于 `hardFreeSlots.sum(durationMinutes)`**（同一条等式纪律）。
  final int hardFreeMinutes;
}

final class AvailabilityBuilder {
  const AvailabilityBuilder(this._zones);

  final TimeZoneDatabase _zones;

  /// 构造规划窗口内的**全部真实空闲区间**，按本地日期切片。
  ///
  /// ## 不再按每日上限截断候选时间轴（1.7.1 修复，计划 §2.4 / Task 2）
  ///
  /// 此前这里把 `dailyMovableTaskLimitMinutes` 当成"最多保留多少分钟空闲候选"，
  /// 从清晨开始依次消费：一天上限 360 分钟时，前 360 分钟空闲被保留，**后面的空闲区间
  /// 直接不进入候选集**。
  ///
  /// 三条理由说明那不是这条规则的含义：
  ///
  /// 1. **上限约束的是最终结果，不是可见性。** 它的语义是"这一天最终安排的可移动任务总时长
  ///    不超过 N"，而 `PlanValidator` 早就是这条约束的最终防线（按未锁定块汇总）。
  ///    在构造阶段把它当预算花掉，等于用"少看见一些空档"来实现一条本该在结果上校验的规则。
  /// 2. **候选可见性会依赖空档顺序。** 同样是一天 540 分钟空闲，拆成"早中晚三段各 180"
  ///    与"一整段 540"，旧实现给出的候选集完全不同——而真实可用时间是一样的。
  /// 3. **用户看到的空闲与引擎能选的空闲必须一致。** 界面按真实空闲画，引擎按截断后的候选
  ///    排，于是"这块明明空着，为什么排不进去"就成了无法解释的现象。
  ///
  /// 因此现在只做四件事：规划窗口裁剪、固定/保护/睡眠/锁定区间扣除、粒度对齐、本地日期切片。
  ///
  /// **注意 `chargedMovableBlocks` 仍然扣除**：它们占住时间（候选不会压上去），而它们计入
  /// 每日上限的事由 `ScheduleEngine` 与 `PlanValidator` 负责——见 `AvailabilityInput` 的说明。
  ///
  /// **本方法是 [analyze] 的转发**（1.8.0 专项）：详细分析要产出同一批空闲时段，
  /// 若两处各实现一遍，"界面看到的空闲"与"容量证据里的空闲"迟早会漂。
  /// 这条转发由 `availability_builder_test.dart` 的逐值一致性用例守着。
  List<AvailabilitySlot> build(AvailabilityInput input) => analyze(input).slots;

  /// [build] 的详细形式：除空闲时段外，还返回带来源标签的占用分段与空闲分钟总数。
  ///
  /// 算法 17 的**两处结构变化**（计划 §3.1 / Task 2 Step 5）：
  ///
  /// 1. **同一次扫线产出两组切片**：[hardFreeSlots] 只扣非任务硬占用，[slots]
  ///    再扣锁定/钉住的任务块。修复前只有一组，于是"日历可见空白"与"任务合规容量"
  ///    无法分开，用户看到的是"明明空着却说容量不足"。
  /// 2. **粒度按空闲段所属的本地日取**（`dailyPolicies[localDate]`），不再用窗口首日
  ///    的 `rules.granularityMinutes`。周末粒度与工作日不同时（用户在设置里可以这样配），
  ///    旧写法会把周末按工作日的网格对齐。
  AvailabilityAnalysis analyze(AvailabilityInput input) {
    // ── 带标签的占用合并（扫线）──────────────────────────────────────────────
    //
    // **同一分钟只从总容量扣一次**：先把四类"命名占用"按区间合并，合并时保留各自的标签
    // 集合；`chargedMovableBlocks` 只是占用（没有标签），单独合并后与前者求并。
    //
    // 合并规则（与 `_merge` 完全一致，因此 `slots` 不会因为多了标签而漂）：
    // `next.start <= current.end` 视为相接，取较晚的结束时刻。
    final labeled = <TimeRange, Set<AvailabilityBlockerKind>>{};
    void addLabeled(Iterable<TimeRange> ranges, AvailabilityBlockerKind kind) {
      for (final range in ranges) {
        final clipped = _intersection(range, input.planningWindow);
        if (clipped == null) continue;
        labeled.update(
          clipped,
          (kinds) => kinds..add(kind),
          ifAbsent: () => {kind},
        );
      }
    }

    // ── 睡眠：**按每天自己的规则展开一次**（计划 Task 2 Step 5）─────────────────
    //
    // 计划要求"`AvailabilityBuilder` 不再从全局 `problem.rules` 私自展开第二份睡眠"。
    // 关键的两个字是**全局**：修复前的写法是
    //
    //     ProtectedTimeExpander(_zones).sleep(rules: input.rules, ...)
    //
    // 它用**一份**规则（窗口首日）展开整个窗口，于是"周末睡眠不同"整周不生效——
    // 这正是计划 §1.2 第 1 条说的结构缺口。
    //
    // 现在改为**逐日**：每一天用它自己那份 `resolvedRules.sleepRange` 展开。
    // 口径因此只有一个（这一天自己的规则），而且**不再需要调用方重复提供睡眠区间**：
    // 装配层仍然把睡眠放进 `protectedIntervals`（`PlanValidator` 要靠它判"块压在
    // 睡眠上"是不是冲突），两者是**同一份展开结果**，`_merge` 会把重叠并掉，
    // 因此"同一分钟只扣一次"依然成立。
    final sleepRaw = <TimeRange>[];
    final sleepDates = _localDatesOf(
      input.planningWindow,
      input.timeZoneId,
    ).toList();
    if (sleepDates.isNotEmpty) {
      // **起点前一天也要展开**：窗口若从本地 00:00 开始，"00:00–07:30" 属于
      // **前一天** 23:30 开始的那一夜。逐日只展开当天会把它整段漏掉。
      sleepDates.insert(
        0,
        DateTime(
          sleepDates.first.year,
          sleepDates.first.month,
          sleepDates.first.day - 1,
        ),
      );
    }
    for (final date in sleepDates) {
      final policy =
          input.dailyPolicies[date] ?? input.dailyPolicies[sleepDates[1]];
      final rules = policy?.resolvedRules;
      if (rules == null) continue;
      // **按日调用 `sleepForDate`**：它只展开这一天的睡眠，因此"周末睡眠不同"
      // 与"特殊日只覆盖当天"都不会被前后各一天的循环带偏。
      sleepRaw.addAll(
        ProtectedTimeExpander(_zones)
            .sleepForDate(
              localDate: date,
              rules: rules,
              timeZoneId: input.timeZoneId,
              dayException: policy?.dayException,
            )
            .map((interval) => interval.range),
      );
    }

    addLabeled(input.fixedIntervals, AvailabilityBlockerKind.fixed);
    addLabeled(input.protectedIntervals, AvailabilityBlockerKind.protected);
    addLabeled(sleepRaw, AvailabilityBlockerKind.sleep);
    addLabeled(input.lockedBlocks, AvailabilityBlockerKind.locked);
    // **锁定任务块也要带标签**：`chargedMovableBlocks` 装的是"锁定块 + 拖动了但没锁定"
    // 的那些，它们与固定日程、保护时间一样占住这段时间。少了这个标签，
    // `blockedSegments` 就说不清"这一分钟为什么不能用"——而那是预览唯一的解释依据。
    //
    // 重复不会导致重复扣除：它们与 `lockedBlocks` 里的同一段区间合并，
    // 而 `busy` 是**并集**（见下面 `_merge`）。
    addLabeled(input.chargedMovableBlocks, AvailabilityBlockerKind.locked);

    // 带标签的两两合并：相邻或重叠且标签集合**相同**的区间先各自合并，
    // 再把"标签集合不同但区间重叠"的部分拆开——拆开是必要的，否则一段
    // "固定日程 + 保护时间"重叠 30 分钟的区间会丢掉其中一个标签。
    final blockedSegments = _labeledSegments(labeled);

    // 归入 [AvailabilityBlockerKind.locked] 标签的区间里，**真正的任务块**是
    // `chargedMovableBlocks`（锁定块与"拖动了但没锁定"的块）。装配层放进
    // `lockedBlocks` 的固定日程与保护时间同样带 locked 标签，而"日硬空闲不扣任何
    // 任务块"（计划 §2 术语表）只扣它们，因此下面直接用来源求并集而不是做集合减法。
    final charged = _merge([
      for (final range in input.chargedMovableBlocks)
        ?_intersection(range, input.planningWindow),
    ]);
    // 空闲 = 窗口 − （带标签占用 ∪ charged）。
    //
    // 用**并集**而不是把两组分别求补再相减：后者会把"两组重叠的那几分钟"扣两次，
    // 而"同一分钟只能扣一次"是这一层的硬约束。
    final busy = _merge([
      for (final segment in blockedSegments) segment.range,
      ...charged,
    ]);

    // ── 日硬空闲的占用集合：**非任务硬占用的并集**（计划 §2 术语表）─────────────
    //
    // 不用"把带标签分段减去 charged"这种集合减法：那样要处理部分重叠，容易在重叠
    // 边界上多扣或漏扣。反过来直接从**来源**求并集更简单也更可核对：固定 + 保护 + 睡眠
    // 就是"非任务硬占用"的全部来源，而它们本来就已按区间合并过（同一分钟只扣一次）。
    //
    // 装配层已经把逐日睡眠展开后传进来（计划 Task 2 Step 5），因此睡眠仍然被扣到——
    // 只是不再由本层展开第二份。
    final hardBusy = _merge([
      for (final range in input.fixedIntervals)
        ?_intersection(range, input.planningWindow),
      for (final range in input.protectedIntervals)
        ?_intersection(range, input.planningWindow),
      for (final range in sleepRaw) ?_intersection(range, input.planningWindow),
    ]);
    final output = <AvailabilitySlot>[];
    final hardFreeOutput = <AvailabilitySlot>[];
    var localDate = _dateOnly(
      _zones.toLocal(input.planningWindow.startUtc, input.timeZoneId),
    );
    final lastLocalDate = _dateOnly(
      _zones.toLocal(
        input.planningWindow.endUtc.subtract(const Duration(microseconds: 1)),
        input.timeZoneId,
      ),
    );

    while (!localDate.isAfter(lastLocalDate)) {
      // **粒度按这一天自己的策略**（计划 Task 2 Step 5 末段）。
      // 缺日即装配不变量破坏：这里抛错而不是回退窗口首日。
      final granularity = input
          .dailyPolicies[normalizeLocalDate(localDate)]
          ?.resolvedRules
          .granularityMinutes;
      if (granularity == null) {
        throw StateError(
          '可用时间分析缺少本地日期 '
          '${localDate.year}-${localDate.month}-${localDate.day} 的每日策略',
        );
      }
      final dayStart = _zones.localMidnightToUtc(localDate, input.timeZoneId);
      // **按本地自然日推进**，不用 `add(Duration(days: 1))`：后者加的是绝对 24 小时，
      // DST 切换日会落在前一天的 23:00 或当天的 01:00，于是同一天被枚举两次、
      // 另一天被跳过（计划 Task 2 Step 4 的 DST 用例钉的就是这件事）。
      final nextDate = DateTime(
        localDate.year,
        localDate.month,
        localDate.day + 1,
      );
      final dayEnd = _zones.localMidnightToUtc(nextDate, input.timeZoneId);
      final dayWindow = _intersection(
        TimeRange(startUtc: dayStart, endUtc: dayEnd),
        input.planningWindow,
      );
      if (dayWindow != null) {
        // 视觉空白：扣除全部占用（含任务块）。
        final dayBusy = busy
            .map((range) => _intersection(range, dayWindow))
            .nonNulls
            .toList();
        for (final range in _complement(dayWindow, dayBusy)) {
          // 粒度对齐只缩短**尾部**：空闲区间的起点不动，因此候选起点仍然落在真实空闲内。
          // 对齐后不足一个粒度的碎片直接丢弃——它连最小片段都放不下。
          final alignedMinutes =
              (range.durationMinutes ~/ granularity) * granularity;
          if (alignedMinutes <= 0) continue;
          output.add(
            AvailabilitySlot(
              localDate: localDate,
              range: TimeRange(
                startUtc: range.startUtc,
                endUtc: range.startUtc.add(Duration(minutes: alignedMinutes)),
              ),
            ),
          );
        }
        // 日硬空闲：只扣非任务硬占用。
        final dayHardBusy = hardBusy
            .map((range) => _intersection(range, dayWindow))
            .nonNulls
            .toList();
        for (final range in _complement(dayWindow, dayHardBusy)) {
          final alignedMinutes =
              (range.durationMinutes ~/ granularity) * granularity;
          if (alignedMinutes <= 0) continue;
          hardFreeOutput.add(
            AvailabilitySlot(
              localDate: localDate,
              range: TimeRange(
                startUtc: range.startUtc,
                endUtc: range.startUtc.add(Duration(minutes: alignedMinutes)),
              ),
            ),
          );
        }
      }
      localDate = nextDate;
    }

    final slots = UnmodifiableListView(output);
    final hardFreeSlots = UnmodifiableListView(hardFreeOutput);
    return AvailabilityAnalysis(
      slots: slots,
      hardFreeSlots: hardFreeSlots,
      blockedSegments: blockedSegments,
      calendarGapMinutes: slots.fold<int>(
        0,
        (sum, slot) => sum + slot.durationMinutes,
      ),
      hardFreeMinutes: hardFreeSlots.fold<int>(
        0,
        (sum, slot) => sum + slot.durationMinutes,
      ),
    );
  }
}

/// 本方法需要展开睡眠的**本地日期集合**：规划窗口覆盖到的那些天。
///
/// 用窗口端点换算、按日历日推进（不用 `add(Duration(days: 1))`：DST 切换日会
/// 落在前一天的 23:00）。与 `ScheduleProblem.dailyPolicies` 的日期集合一致，
/// 因此逐日策略一定命中。
List<DateTime> _localDatesOf(TimeRange window, String timeZoneId) {
  final zones = TimeZoneDatabase();
  final first = _dateOnly(zones.toLocal(window.startUtc, timeZoneId));
  final last = _dateOnly(
    zones.toLocal(
      window.endUtc.subtract(const Duration(microseconds: 1)),
      timeZoneId,
    ),
  );
  final dates = <DateTime>[];
  for (var date = first; !date.isAfter(last);) {
    dates.add(date);
    date = DateTime(date.year, date.month, date.day + 1);
  }
  return dates;
}

List<TimeRange> _merge(List<TimeRange> ranges) {
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final merged = <TimeRange>[];
  var current = ranges.first;
  for (final next in ranges.skip(1)) {
    if (!next.startUtc.isAfter(current.endUtc)) {
      // **取两者的最大范围**：`next` 可能完全落在 `current` 之内（终点更早），
      // 也可能把 `current` 完全包住（起点相同或更早、终点更晚）；
      // 还可能是"起点落在 `current` 内、终点超出 `current`"。
      //
      // 判据与 `_labeledSegments` 的相邻合并**必须逐字一致**（那边也用最大范围），
      // 否则 `slots` 与 `blockedSegments` 会给出两套口径——那正是
      // "容量分析器、诊断器和引擎各算一份空闲"的入口。
      final start = next.startUtc.isBefore(current.startUtc)
          ? next.startUtc
          : current.startUtc;
      final end = next.endUtc.isAfter(current.endUtc)
          ? next.endUtc
          : current.endUtc;
      current = TimeRange(startUtc: start, endUtc: end);
      continue;
    }
    merged.add(current);
    current = next;
  }
  merged.add(current);
  return merged;
}

/// 把"区间 → 标签集合"化成**互不重叠、各带完整标签集合**的分段（扫线）。
///
/// 做法是标准的端点切分：取全部起点与终点作为切点，每一对相邻切点之间的分钟数
/// **必然**被同一组区间覆盖，因此它的标签集合是定值。这样重叠的固定日程与保护时间
/// 会得到"两者都在"的一段，而不是丢掉其中一个标签——容量仍然只扣一次（它们被并成了一段）。
///
/// 紧邻且标签集合相同的分段会合并，于是输出是"能合并的都合并了"的最小分段数，
/// 结果与输入顺序无关（切点先排序，标签集合是数学上的交集）。
List<BlockedAvailabilitySegment> _labeledSegments(
  Map<TimeRange, Set<AvailabilityBlockerKind>> labeled,
) {
  if (labeled.isEmpty) return const [];
  final boundaries = <DateTime>{};
  for (final range in labeled.keys) {
    boundaries
      ..add(range.startUtc)
      ..add(range.endUtc);
  }
  final cuts = boundaries.toList()..sort();
  final result = <BlockedAvailabilitySegment>[];
  for (var index = 0; index + 1 < cuts.length; index++) {
    final start = cuts[index];
    final end = cuts[index + 1];
    if (!end.isAfter(start)) continue;
    final kinds = <AvailabilityBlockerKind>{};
    for (final entry in labeled.entries) {
      // 该区间覆盖"这一整对切点之间"的判据：起点不晚于 start，且终点不早于 end。
      // （切点只有这一批区间的端点，因此不存在"只覆盖一半"的情况。）
      if (entry.key.startUtc.isAfter(start)) continue;
      if (entry.key.endUtc.isBefore(end)) continue;
      kinds.addAll(entry.value);
    }
    if (kinds.isEmpty) continue;
    final previous = result.isEmpty ? null : result.last;
    if (previous != null &&
        !previous.range.endUtc.isBefore(start) &&
        previous.kinds.length == kinds.length &&
        previous.kinds.containsAll(kinds)) {
      result[result.length - 1] = BlockedAvailabilitySegment(
        range: TimeRange(startUtc: previous.range.startUtc, endUtc: end),
        kinds: kinds,
      );
      continue;
    }
    result.add(
      BlockedAvailabilitySegment(
        range: TimeRange(startUtc: start, endUtc: end),
        kinds: kinds,
      ),
    );
  }
  return result;
}

List<TimeRange> _complement(TimeRange window, List<TimeRange> busy) {
  final output = <TimeRange>[];
  var cursor = window.startUtc;
  for (final interval in _merge(busy)) {
    if (interval.startUtc.isAfter(cursor)) {
      output.add(TimeRange(startUtc: cursor, endUtc: interval.startUtc));
    }
    if (interval.endUtc.isAfter(cursor)) cursor = interval.endUtc;
  }
  if (cursor.isBefore(window.endUtc)) {
    output.add(TimeRange(startUtc: cursor, endUtc: window.endUtc));
  }
  return output;
}

TimeRange? _intersection(TimeRange a, TimeRange b) {
  final start = a.startUtc.isAfter(b.startUtc) ? a.startUtc : b.startUtc;
  final end = a.endUtc.isBefore(b.endUtc) ? a.endUtc : b.endUtc;
  return end.isAfter(start) ? TimeRange(startUtc: start, endUtc: end) : null;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
