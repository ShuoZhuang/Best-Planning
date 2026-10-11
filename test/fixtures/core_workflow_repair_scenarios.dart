/// 1.8.0「核心工作流修复」的共享场景夹具（计划 Task 1 Step 2）。
///
/// **本文件只放纯数据构造器，不放断言、不放 `test()`。** 后续任务
/// （Task 2 时间轴、Task 3 通知、Task 7 schema、Task 11–14 延后与局部修复）
/// 从这里取同一组时刻、同一组 id 和同一组标题，目的是让"上海 12:00 的卡片"
/// 这句话在所有测试里指同一个 UTC 瞬间，而不是各写各的字面量。
///
/// **为什么时刻由 `TimeZoneDatabase` 算出来、而不是写成 UTC 字面量**：
/// 设计规范 §3 第 1 条要求"日期、星期和按天延后的日历语义使用事项自己的 IANA
/// 时区"。把 `DateTime.utc(2026, 10, 12, 4)` 直接写在夹具里，等于把
/// Asia/Shanghai 的 +08:00 硬编码进了测试，柏林夏令时那几条就再也测不出
/// "本地钟点保持"与"经过时长"的区别——而这正是规范 §4.2 与 §11.2 的分界线。
library;

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 夹具里用到的时区 id。写成常量是为了让测试的 `expect` 与夹具不会各写一份字符串。
abstract final class RepairZones {
  static const shanghai = 'Asia/Shanghai';
  static const berlin = 'Europe/Berlin';
  static const utc = 'UTC';
}

/// 夹具里的引用 id。
///
/// **刻意用可读字符串而不是 UUID**：规范 §13.1 禁止界面上出现裸 UUID，
/// 而"界面上没有 UUID"这类断言只有在夹具本身不含 UUID 形状的字符串时才有意义
/// （否则测试会因为夹具里有个长得像 UUID 的标题而假失败）。
abstract final class RepairIds {
  static const lunchEvent = 'evt-lunch-shanghai';
  static const overnightEvent = 'evt-overnight-cleaning';
  static const deferredBlock = 'block-deep-work-1510';
  static const deferredTask = 'task-deep-work';
  static const blockerEvent = 'evt-blocker-1540';
  static const blockerTask = 'task-blocker';
  static const fillerTask = 'task-filler';

  // 课程：两门**同名但不同 logicalCourseId** 的课，用来钉"管理这门课按 id 深链"。
  static const calculusCourseA = 'course-calculus-a';
  static const calculusCourseB = 'course-calculus-b';
  static const physicsCourse = 'course-physics-a';
  static const importBatchAutumn = 'batch-autumn-2026';
  static const termAutumn = 'term-2026-autumn';

  // 通知：五类各一条，全部带 `planner.` 前缀；另有一条**非本应用**的通知，
  // 用来钉"总开关只能取消本应用的待处理项"。
  static const foreignNotification = 'other-app.digest.daily';
}

/// 时间轴夹具：一次转换后的**本地日内分钟**与产生它的 UTC 区间。
///
/// `startMinute` / `endMinute` 就是规范 §4.1 说的"单一时间表示"：
/// 位置、卡片文字、悬浮提示与无障碍语义都必须读这一对值。
final class TimelineScenario {
  const TimelineScenario({
    required this.label,
    required this.timeZoneId,
    required this.localDate,
    required this.startUtc,
    required this.endUtc,
    required this.startMinute,
    required this.endMinute,
    this.expectedLabel,
  });

  /// 人类可读的场景名，出现在测试名里。
  final String label;
  final String timeZoneId;

  /// 事项所在的那个**本地日期**（只有年月日有意义）。
  final DateTime localDate;
  final DateTime startUtc;
  final DateTime endUtc;
  final int startMinute;
  final int endMinute;

  /// 期望的卡片文字；为空时由 [startMinute] / [endMinute] 推导。
  final String? expectedLabel;

  bool get crossesMidnight => endMinute > LocalTimeRange.minutesPerDay;
}

/// 一条通知夹具：id 与它所属的分类。
final class NotificationScenario {
  const NotificationScenario({
    required this.id,
    required this.category,
    required this.isManagedByPlanner,
  });

  final String id;
  final String category;

  /// 是否以 `planner.` 开头（即由本应用排入、总开关必须能取消）。
  final bool isManagedByPlanner;
}

/// 一个可复用的排程输入 + 它绑定的"延后"期望下界。
///
/// Task 11 起"延后"不再是全局 pending 草稿，而是 proposal 绑定的显式请求；
/// Task 12 的局部修复要按字典序选方案。两者都需要同一个输入，因此夹具在这里
/// 给出**不是**排程器实现的一部分的纯构造器。
final class DeferScenario {
  const DeferScenario({
    required this.problem,
    required this.blockId,
    required this.notBeforeUtc,
    required this.expectedStartUtc,
  });

  final ScheduleProblem problem;

  /// 被延后的那个块（在 [ScheduleProblem.existingBlocks] 里）。
  final String blockId;

  /// 延后请求给出的**下界**，不是必须精确占用的点（规范 §11.2）。
  final DateTime notBeforeUtc;

  /// 目标之后最近的合法落点。
  final DateTime expectedStartUtc;
}

final class CoreWorkflowRepairScenarios {
  CoreWorkflowRepairScenarios({TimeZoneDatabase? zones})
    : _zones = zones ?? TimeZoneDatabase();

  final TimeZoneDatabase _zones;

  /// 夹具用的时区服务。后续任务的测试要构造 `DeterministicScheduleEngine`
  /// 时应当复用**同一个**实例，避免"夹具算出的 UTC"与"引擎解释的时区"来自
  /// 两份配置。
  TimeZoneDatabase get zones => _zones;

  // ---------------------------------------------------------------- 时间轴

  /// 规范 §17 第 1 行：上海时区午餐 12:00–13:00。
  ///
  /// 这个场景的价值在于**它同时钉住两个值**：UTC `04:00` 与本地 `12:00`。
  /// 修复前的时间轴把"本地分钟"再包成 `DateTime.utc` 调一次 `toLocal`，
  /// 于是在上海多偏 8 小时——只有同时断言 UTC 与本地分钟才抓得住。
  TimelineScenario shanghaiLunch() {
    const startMinute = 12 * 60;
    const endMinute = 13 * 60;
    final localDate = DateTime(2026, 10, 12);
    return TimelineScenario(
      label: '上海 2026-10-12 午餐 12:00–13:00',
      timeZoneId: RepairZones.shanghai,
      localDate: localDate,
      startUtc: _zones.localDateTimeToUtc(
        localDate,
        startMinute,
        RepairZones.shanghai,
      ),
      endUtc: _zones.localDateTimeToUtc(
        localDate,
        endMinute,
        RepairZones.shanghai,
      ),
      startMinute: startMinute,
      endMinute: endMinute,
      expectedLabel: '12:00–13:00',
    );
  }

  /// 规范 §4.2：跨午夜 23:30–00:30 分两段，分别落在两天。
  ///
  /// 返回的第二个元素是次日 00:00–00:30 那一段；两段的分钟区间各自都在
  /// `0 ≤ value ≤ 1440` 之内（规范 §4.1 的单列范围约束）。
  List<TimelineScenario> shanghaiCrossMidnight() {
    final firstDate = DateTime(2026, 10, 12);
    final secondDate = DateTime(2026, 10, 13);
    const startMinute = 23 * 60 + 30;
    return [
      TimelineScenario(
        label: '跨午夜第一段 2026-10-12 23:30–24:00',
        timeZoneId: RepairZones.shanghai,
        localDate: firstDate,
        startUtc: _zones.localDateTimeToUtc(
          firstDate,
          startMinute,
          RepairZones.shanghai,
        ),
        endUtc: _zones.localDateTimeToUtc(secondDate, 0, RepairZones.shanghai),
        // 区间终点用 1440 而不是 0：0 会把"到当天结束"回绕成"零长度"，
        // 计划 Task 2 Step 4 明确要求 `1440` 显示成 `24:00`。
        startMinute: startMinute,
        endMinute: LocalTimeRange.minutesPerDay,
        expectedLabel: '23:30–24:00',
      ),
      TimelineScenario(
        label: '跨午夜第二段 2026-10-13 00:00–00:30',
        timeZoneId: RepairZones.shanghai,
        localDate: secondDate,
        startUtc: _zones.localDateTimeToUtc(
          secondDate,
          0,
          RepairZones.shanghai,
        ),
        endUtc: _zones.localDateTimeToUtc(secondDate, 30, RepairZones.shanghai),
        startMinute: 0,
        endMinute: 30,
        expectedLabel: '00:00–00:30',
      ),
    ];
  }

  /// 规范 §4.2：Europe/Berlin 夏令时切换日的位置与文字一致。
  ///
  /// 2026 年柏林在 **3 月 29 日** 02:00 本地时间从 CET(+1) 跳到 CEST(+2)，
  /// 因此那一天的 01:00–03:00 本地时长只有 60 分钟。夹具给出切换日和一个
  /// 普通日各一条，用来对比"本地钟点"与"经过时长"。
  TimelineScenario berlinSpringForward() {
    final localDate = DateTime(2026, 3, 29);
    const startMinute = 3 * 60;
    const endMinute = 4 * 60;
    return TimelineScenario(
      label: '柏林 2026-03-29 夏令时切换日 03:00–04:00',
      timeZoneId: RepairZones.berlin,
      localDate: localDate,
      startUtc: _zones.localDateTimeToUtc(
        localDate,
        startMinute,
        RepairZones.berlin,
      ),
      endUtc: _zones.localDateTimeToUtc(
        localDate,
        endMinute,
        RepairZones.berlin,
      ),
      startMinute: startMinute,
      endMinute: endMinute,
      expectedLabel: '03:00–04:00',
    );
  }

  /// 切换日**之前**的同一钟点，用来证明上一条的结果不是"随便都能过"。
  TimelineScenario berlinBeforeSpringForward() {
    final localDate = DateTime(2026, 3, 28);
    const startMinute = 3 * 60;
    const endMinute = 4 * 60;
    return TimelineScenario(
      label: '柏林 2026-03-28 夏令时切换前一日 03:00–04:00',
      timeZoneId: RepairZones.berlin,
      localDate: localDate,
      startUtc: _zones.localDateTimeToUtc(
        localDate,
        startMinute,
        RepairZones.berlin,
      ),
      endUtc: _zones.localDateTimeToUtc(
        localDate,
        endMinute,
        RepairZones.berlin,
      ),
      startMinute: startMinute,
      endMinute: endMinute,
      expectedLabel: '03:00–04:00',
    );
  }

  // ---------------------------------------------------------------- 通知

  /// 规范 §17 第 2 行与计划 Task 3 Step 1：五类 `planner.*` + 一条外部通知。
  ///
  /// 五类 id 前缀与两个服务里的常量一致：`NotificationService._managedPrefix`
  /// 覆盖前四类，`RecurringNotificationService._managedPrefix` 覆盖
  /// `planner.recurring.`。第五条**同样以 `planner.` 开头**，因此总开关必须
  /// 用统一前缀判断，而不是只列四类。
  List<NotificationScenario> notificationCategories() => const [
    NotificationScenario(
      id: 'planner.task_start.block-deep-work-1510',
      category: 'taskStart',
      isManagedByPlanner: true,
    ),
    NotificationScenario(
      id: 'planner.calendar_start.evt-lunch-shanghai',
      category: 'calendarStart',
      isManagedByPlanner: true,
    ),
    NotificationScenario(
      id: 'planner.deadline.task-deep-work',
      category: 'deadline',
      isManagedByPlanner: true,
    ),
    NotificationScenario(
      id: 'planner.conflict.pending',
      category: 'conflict',
      isManagedByPlanner: true,
    ),
    NotificationScenario(
      id: 'planner.recurring.weeklyProgress.tpl-weekly-goal.2026-10-12',
      category: 'recurringGoal',
      isManagedByPlanner: true,
    ),
    NotificationScenario(
      id: RepairIds.foreignNotification,
      category: 'foreign',
      isManagedByPlanner: false,
    ),
  ];

  // ------------------------------------------------------------ 延后与空档

  /// 规范 §17 第 8 行与计划 Task 12 Step 1：**目标点被占**时仍要延后成功。
  ///
  /// 形状（全部 Asia/Shanghai 本地时间）：
  ///
  /// - 已确认但未锁定的块：`15:10–15:25`（深工作，30 分钟剩余）；
  /// - 固定日程：`15:40–16:10`（占住延后 30 分钟之后的目标点）；
  /// - 可移动的填充块：`16:10–16:40`；
  /// - 计划窗口到 `18:00` 结束。
  ///
  /// 请求是"延后 30 分钟"，因此 `notBeforeUtc` 对应本地 `15:40`。那一点被固定日程
  /// 占住，合法落点只能是其后最近的完整片段——`16:10–16:25`。修复前列的语义是
  /// "把 15:40 精确锁定"，于是这里必然报"可用时间不足"；修复后必须落到 16:10。
  ///
  /// **`expectedStartUtc` 是刻意写死的一个推断值**，不是搜索引擎的输出：
  /// 如果实现选了别的位置，这条夹具就失去了"期望"的意义，测试会失败并迫使实现
  /// 与规范 §11.4 的字典序对齐。
  DeferScenario deferredBlockWithOccupiedTarget() {
    final localDate = DateTime(2026, 10, 12);
    DateTime at(int minute) =>
        _zones.localDateTimeToUtc(localDate, minute, RepairZones.shanghai);

    const blockStart = 15 * 60 + 10;
    const blockEnd = 15 * 60 + 25;
    const targetMinute = 15 * 60 + 40;
    const blockerStart = 15 * 60 + 40;
    const blockerEnd = 16 * 60 + 10;
    const fillerStart = 16 * 60 + 10;
    const fillerEnd = 16 * 60 + 40;
    const windowStart = 9 * 60;
    const windowEnd = 18 * 60;

    return DeferScenario(
      problem: ScheduleProblem(
        planningWindow: TimeRange(
          startUtc: at(windowStart),
          endUtc: at(windowEnd),
        ),
        timeZoneId: RepairZones.shanghai,
        tasks: [
          SchedulableTask(
            id: RepairIds.deferredTask,
            requiredMinutes: 15,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 15,
            maxChunkMinutes: 30,
          ),
          SchedulableTask(
            id: RepairIds.blockerTask,
            requiredMinutes: 30,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 15,
            maxChunkMinutes: 30,
          ),
        ],
        fixedIntervals: [
          BusyInterval(
            id: RepairIds.blockerEvent,
            range: TimeRange(
              startUtc: at(blockerStart),
              endUtc: at(blockerEnd),
            ),
          ),
        ],
        protectedIntervals: const [],
        lockedBlocks: const [],
        existingBlocks: [
          PlannedBlock(
            id: RepairIds.deferredBlock,
            taskId: RepairIds.deferredTask,
            range: TimeRange(startUtc: at(blockStart), endUtc: at(blockEnd)),
          ),
          PlannedBlock(
            id: 'block-blocker-1610',
            taskId: RepairIds.blockerTask,
            range: TimeRange(startUtc: at(fillerStart), endUtc: at(fillerEnd)),
          ),
        ],
        rules: repairRules(),
        preferences: const PreferenceProfile(),
        inputHash: 'core-workflow-repair.defer-occupied-target.v1',
      ),
      blockId: RepairIds.deferredBlock,
      notBeforeUtc: at(targetMinute),
      // 固定日程 15:40–16:10 之后最近的合法起点。
      expectedStartUtc: at(fillerStart),
    );
  }

  /// 计划 Task 13 Step 1：两任务之间夹着一个**无法利用的 20 分钟空档**。
  ///
  /// 形状（Asia/Shanghai）：
  ///
  /// - 固定日程 A：`10:00–10:40`；
  /// - 空档：`10:40–11:00`（20 分钟）；
  /// - 固定日程 B：`11:00–11:40`；
  /// - 剩余任务只有一个，最小合法片段 30 分钟。
  ///
  /// 20 分钟放不下 30 分钟的最小片段，而且它两侧都是固定日程、不可移动，因此这是一个
  /// **结构上必须存在**的 orphan gap。规范 §12.2 要求此时界面显示"空闲 20 分钟"，
  /// 而不是声称计划错误；计划 Task 13 Step 1 要求分类器不能使用全局固定阈值来判断
  /// 这个 20 分钟——阈值必须来自"剩余任务的最小合法片段"。
  ScheduleProblem orphanGapBetweenFixedEvents() {
    final localDate = DateTime(2026, 10, 12);
    DateTime at(int minute) =>
        _zones.localDateTimeToUtc(localDate, minute, RepairZones.shanghai);

    return ScheduleProblem(
      planningWindow: TimeRange(startUtc: at(9 * 60), endUtc: at(18 * 60)),
      timeZoneId: RepairZones.shanghai,
      tasks: [
        SchedulableTask(
          id: RepairIds.fillerTask,
          requiredMinutes: 30,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 30,
        ),
      ],
      fixedIntervals: [
        BusyInterval(
          id: 'evt-morning-a',
          range: TimeRange(startUtc: at(10 * 60), endUtc: at(10 * 60 + 40)),
        ),
        BusyInterval(
          id: 'evt-morning-b',
          range: TimeRange(startUtc: at(11 * 60), endUtc: at(11 * 60 + 40)),
        ),
      ],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: repairRules(),
      preferences: const PreferenceProfile(),
      inputHash: 'core-workflow-repair.orphan-gap.v1',
    );
  }

  /// 计划 Task 9 Step 1：同名但不同 `logicalCourseId` 的两门课，加上一门不同名的课。
  ///
  /// 用 `(logicalCourseId, title)` 的**纯数据**表达，不构造 `CalendarEvent`：
  /// Task 7 才会给 `CalendarEvent` 加上 `kind`，在那之前引用它会编译不过。
  /// 这里的重点是"同名不同 id 必须分开"，它与 `kind` 无关，因此提前固定下来。
  List<({String logicalCourseId, String title, String importBatchId})>
  sameNamedDifferentCourses() => const [
    (
      logicalCourseId: RepairIds.calculusCourseA,
      title: '高等数学(上)',
      importBatchId: RepairIds.importBatchAutumn,
    ),
    (
      logicalCourseId: RepairIds.calculusCourseB,
      title: '高等数学(上)',
      importBatchId: RepairIds.importBatchAutumn,
    ),
    (
      logicalCourseId: RepairIds.physicsCourse,
      title: '大学物理',
      importBatchId: RepairIds.importBatchAutumn,
    ),
  ];

  /// 本批次所有排程场景共用的规则。
  ///
  /// **刻意与 `DefaultSettings` 无关**：夹具一旦跟着默认值漂移，"20 分钟放不下"
  /// 这类断言就会在别人调默认值时静默失效。这里的 `minChunkMinutes: 30` 是
  /// orphan gap 场景成立的前提，必须写死。
  static PlanningRules repairRules() => PlanningRules(
    energyWindows: [
      EnergyWindow(
        range: LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
        level: EnergyLevel.high,
      ),
    ],
    sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
    minimumSleepMinutes: 420,
    defaultFocusMinutes: 50,
    breakMinutes: 10,
    dailyMovableTaskLimitMinutes: 600,
    weeklyLifeQuotaMinutes: 0,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    granularityMinutes: 5,
  );
}
