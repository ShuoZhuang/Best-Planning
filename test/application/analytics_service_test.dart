import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/daos/analytics_dao.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';

void main() {
  final start = DateTime.utc(2026, 10, 2, 10);
  final end = DateTime.utc(2026, 10, 9, 10);

  test('用户自建的保护时间**计入**「休息保护」那一节（1.8.0，规范 §9.1 末条）', () async {
    // 走的是**服务层**：`AnalyticsDao` 产出 `protectedInstances`，
    // 由 `AnalyticsService` 的展开器与规则来源的保护时间**合并**计入同一节。
    // 只测 DAO 只能证明"数据取到了"，测不到"有没有被算进去"。
    //
    // **必须传 `zones` 与 `timeZoneId`**：服务刻意不在缺少时区时按 UTC 归桶，
    // 缺了它们时所有与保护时间有关的小节都返回 `null`。
    // 第一版漏了这两个参数，断言于是在 `!` 上崩掉——**夹具比断言更容易错**。
    const customHours = 2;
    final withCustom = await AnalyticsService(
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      source: _MemoryAnalyticsSource(
        _dataset(
          start,
          protectedInstances: [
            AnalyticsProtectedInstance(
              label: '每周二下午不排事',
              startUtc: start.add(const Duration(hours: 2)),
              endUtc: start.add(const Duration(hours: 2 + customHours)),
            ),
          ],
        ),
      ),
    ).query(AnalyticsFilter(startUtc: start, endUtc: end));

    expect(
      withCustom.restSummary,
      isNotNull,
      reason:
          '窗口里**只有**用户自建的保护时间时，「休息保护」这一节也必须出现；'
          '否则用户建了保护时间却在统计里看不到——等于被悄悄丢掉',
    );
    expect(
      withCustom.restSummary!.totalMinutes,
      greaterThanOrEqualTo(customHours * 60),
      reason: '那一节的分钟数至少要把这 2 小时算进去',
    );
  });

  test('完全没有保护时间时「休息保护」这一节不出现（空节的语义）', () async {
    final report = await AnalyticsService(
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      source: _MemoryAnalyticsSource(_dataset(start)),
    ).query(AnalyticsFilter(startUtc: start, endUtc: end));

    expect(
      report.restSummary,
      isNull,
      reason: '没有保护时间就没有这一节——这与"这一节是 0 分钟"是两件事',
    );
  });

  test('用户自建的保护时间计入「工作／休息」的休息分钟（1.8.0，规范 §9.1 末条）', () async {
    // **这是 `_restSummary` 那条缺陷的邻座**：`_protectedMinutes` 同样声明了
    // `customInstances`、同样在守卫里检查了它，却同样**没有转发**给展开器。
    //
    // 它是「工作／休息」里休息量的来源，也就是那个比例的分母之一——
    // 算少了会让"休息占比"偏低，而这正是用户会据以判断"是不是太拼了"的数字。
    const customHours = 2;
    final report = await AnalyticsService(
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      source: _MemoryAnalyticsSource(
        _dataset(
          start,
          protectedInstances: [
            AnalyticsProtectedInstance(
              label: '每周二下午不排事',
              startUtc: start.add(const Duration(hours: 2)),
              endUtc: start.add(const Duration(hours: 2 + customHours)),
            ),
          ],
        ),
      ),
    ).query(AnalyticsFilter(startUtc: start, endUtc: end));

    expect(report.workRest, isNotNull, reason: '有保护时间时这一节应当出现');
    // **期望值 60 不是 120，而且这是对的**：`_dataset` 里有一条 `life` 计划块
    // 落在 start+2h…+3h，与我这条保护时间（start+2h…+4h）**重叠 60 分钟**。
    // 「工作／休息」的休息量是"保护容量 − 被安排侵占的部分"，
    // 因此 120 − 60 = 60。第一版我按 120 写，红了——**夹具比断言更容易错**，
    // 这已经是本轮第三次了，所以把算式写在用例里而不是只写数字。
    expect(
      report.workRest!.restMinutes,
      60,
      reason:
          '自建保护时间 120 分钟 − 被 life 计划块侵占的 60 分钟 = 60；'
          '若这一项完全没算进去，这里会是 0（而且整节因 protectedMinutes <= 0 而消失）',
    );
  });

  test('自定义范围按交集区分计划和实际，并公开所有比例分母', () async {
    final service = AnalyticsService(
      source: _MemoryAnalyticsSource(_dataset(start)),
    );

    final report = await service.query(
      AnalyticsFilter(startUtc: start, endUtc: end),
    );

    expect(report.plannedMinutes, 150);
    expect(report.actualMinutes, 105);
    expect(report.completionRate.numerator, 2);
    expect(report.completionRate.denominator, 3);
    expect(report.completionRate.isAvailable, isTrue);
    expect(report.onTimeCompletionRate.numerator, 1);
    expect(report.onTimeCompletionRate.denominator, 2);
    expect(report.estimateVariance.numerator, -60);
    expect(report.estimateVariance.denominator, 120);
    expect(report.lifeQuota.targetMinutes, 360);
    expect(report.lifeQuota.plannedMinutes, 60);
    expect(report.lifeQuota.actualMinutes, 45);
    expect(
      report.domainDistribution
          .singleWhere((item) => item.id == 'area-study')
          .plannedMinutes,
      90,
    );
    expect(
      report.domainDistribution
          .singleWhere((item) => item.id == 'area-life')
          .actualMinutes,
      45,
    );
    expect(report.commonInterruptions.first, const RankedMetric('network', 2));
    expect(report.replanReasons.first, const RankedMetric('overrun', 2));
    expect(report.suggestionBehavior.accepted, 2);
    expect(report.suggestionBehavior.modified, 1);
    expect(report.suggestionBehavior.rejected, 1);
    expect(report.suggestionBehavior.acceptanceRate.numerator, 2);
    expect(report.suggestionBehavior.acceptanceRate.denominator, 4);
    expect(
      report.trend.fold<int>(0, (sum, day) => sum + day.plannedMinutes),
      150,
    );
    expect(
      report.trend.fold<int>(0, (sum, day) => sum + day.actualMinutes),
      105,
    );
  });

  test('预计分钟为零时不伪造预估偏差百分比', () async {
    final zeroEstimate = AnalyticsDataset(
      weeklyLifeQuotaMinutes: 360,
      tasks: [
        AnalyticsTaskFact(
          id: 'zero',
          title: '临时事项',
          areaId: 'area-study',
          areaName: '学业',
          projectId: 'project-zero',
          tags: const {'临时'},
          status: TaskStatus.completed,
          estimatedMinutes: 0,
          completedAtUtc: start.add(const Duration(hours: 1)),
          isLifeTask: false,
        ),
      ],
      actualEntries: [
        AnalyticsActualFact(
          taskId: 'zero',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          activeMinutes: 30,
        ),
      ],
    );
    final report = await AnalyticsService(
      source: _MemoryAnalyticsSource(zeroEstimate),
    ).query(AnalyticsFilter(startUtc: start, endUtc: end));

    expect(report.estimateVariance.numerator, 0);
    expect(report.estimateVariance.denominator, 0);
    expect(report.estimateVariance.isAvailable, isFalse);
    expect(report.estimateVariance.ratio, isNull);
  });

  test('领域、项目、标签和状态筛选同时生效', () async {
    final report =
        await AnalyticsService(source: _MemoryAnalyticsSource(_dataset(start)))
            .query(
              AnalyticsFilter(
                startUtc: start,
                endUtc: end,
                areaIds: const {'area-study'},
                projectIds: const {'project-course'},
                tags: const {'课程'},
                statuses: const {TaskStatus.completed},
              ),
            );

    expect(report.plannedMinutes, 90);
    expect(report.actualMinutes, 60);
    expect(report.domainDistribution.map((item) => item.id), ['area-study']);
  });

  test('10,000 条实际记录的一年查询输出基准耗时', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final yearStart = DateTime.utc(2025);
    final yearEnd = DateTime.utc(2026);
    await database.customInsert("""
      INSERT INTO areas (id, name, color, sort_order)
      VALUES ('area-study', '学业', 0, 0)
    """);
    await database.customInsert("""
      INSERT INTO projects (id, area_id, name)
      VALUES ('project-course', 'area-study', '课程')
    """);
    await database.customInsert("""
      INSERT INTO tasks (
        id, project_id, title, notes, priority, estimated_minutes,
        remaining_minutes, energy_level, split_mode, min_chunk_minutes,
        max_chunk_minutes, status, created_at_utc, updated_at_utc
      ) VALUES (
        'task-1', 'project-course', '复习', '', 'medium', 60,
        60, 'medium', 'splittable', 30, 90, 'completed', 0, 0
      )
    """);
    final rows = List.generate(10000, (index) {
      final entryStart = yearStart.add(Duration(minutes: index * 50));
      return TimeEntriesCompanion.insert(
        id: 'entry-$index',
        taskId: 'task-1',
        startedAtUtc: entryStart.microsecondsSinceEpoch,
        endedAtUtc: Value(
          entryStart.add(const Duration(minutes: 30)).microsecondsSinceEpoch,
        ),
        pausedMinutes: const Value(0),
        source: '{"activeMicroseconds":1800000000}',
        recoveryState: 'confirmed',
      );
    });
    await database.batch(
      (batch) => batch.insertAll(database.timeEntries, rows),
    );

    // 同一条命令里整轮并发跑时，真实耗时会叠加调度噪声：本用例曾以 345ms 撞上 300ms 的
    // 上界而失败，单独连跑三次却是 144/138/145ms（见 §13.0 的 T7）。一个会随机失败的
    // 门禁不是门禁，因此这里改为"预热一次 + 三次取最小值"，并把上界放宽到能跨过负载噪声、
    // 但仍能抓住数量级退化的水平。它是**防线**（例如不小心写出 N+1 会到秒级），
    // 不是性能门禁——真正的性能门禁需要独立的基准装置，而不是混在功能用例里。
    final service = AnalyticsService(
      source: AnalyticsDao(
        database,
        calendar: DriftCalendarRepository(database),
      ),
    );
    final filter = AnalyticsFilter(startUtc: yearStart, endUtc: yearEnd);
    // 预热：把首次查询的解析与预编译成本排除在测量之外。
    await service.query(filter);

    var best = 1 << 30;
    AnalyticsReport? report;
    for (var attempt = 0; attempt < 3; attempt++) {
      final stopwatch = Stopwatch()..start();
      report = await service.query(filter);
      stopwatch.stop();
      best = math.min(best, stopwatch.elapsedMilliseconds);
    }

    debugPrint(
      'Analytics benchmark: 10,000 entries / 1 year = $best ms（三次最小值）',
    );
    expect(report!.actualMinutes, 300000);
    expect(best, lessThan(3000));
  });
}

AnalyticsDataset _dataset(
  DateTime start, {
  List<AnalyticsProtectedInstance> protectedInstances = const [],
}) => AnalyticsDataset(
  weeklyLifeQuotaMinutes: 360,
  protectedInstances: protectedInstances,
  tasks: [
    AnalyticsTaskFact(
      id: 'study',
      title: '课程论文',
      areaId: 'area-study',
      areaName: '学业',
      projectId: 'project-course',
      tags: const {'课程', '写作'},
      status: TaskStatus.completed,
      estimatedMinutes: 120,
      dueAtUtc: start.add(const Duration(days: 2)),
      completedAtUtc: start.add(const Duration(days: 1, hours: 23)),
      isLifeTask: false,
    ),
    AnalyticsTaskFact(
      id: 'life',
      title: '看电影',
      areaId: 'area-life',
      areaName: '生活',
      projectId: 'project-fun',
      tags: const {'娱乐'},
      status: TaskStatus.completed,
      estimatedMinutes: 0,
      dueAtUtc: start.add(const Duration(days: 3)),
      completedAtUtc: start.add(const Duration(days: 3, minutes: 30)),
      isLifeTask: true,
    ),
    AnalyticsTaskFact(
      id: 'open',
      title: '竞赛报名',
      areaId: 'area-competition',
      areaName: '竞赛',
      projectId: 'project-contest',
      tags: const {'竞赛'},
      status: TaskStatus.open,
      estimatedMinutes: 30,
      dueAtUtc: start.add(const Duration(days: 4)),
      isLifeTask: false,
    ),
  ],
  plannedBlocks: [
    AnalyticsPlannedFact(
      taskId: 'study',
      startUtc: start.subtract(const Duration(minutes: 30)),
      endUtc: start.add(const Duration(minutes: 30)),
    ),
    AnalyticsPlannedFact(
      taskId: 'study',
      startUtc: start.add(const Duration(hours: 1)),
      endUtc: start.add(const Duration(hours: 2)),
    ),
    AnalyticsPlannedFact(
      taskId: 'life',
      startUtc: start.add(const Duration(hours: 2)),
      endUtc: start.add(const Duration(hours: 3)),
    ),
  ],
  actualEntries: [
    AnalyticsActualFact(
      taskId: 'study',
      startUtc: start.add(const Duration(minutes: 15)),
      endUtc: start.add(const Duration(hours: 1, minutes: 15)),
      activeMinutes: 60,
    ),
    AnalyticsActualFact(
      taskId: 'life',
      startUtc: start.add(const Duration(hours: 2)),
      endUtc: start.add(const Duration(hours: 3)),
      activeMinutes: 45,
    ),
  ],
  events: [
    AnalyticsEventFact(
      kind: AnalyticsEventKind.interruption,
      code: 'network',
      observedAtUtc: start.add(const Duration(hours: 1)),
    ),
    AnalyticsEventFact(
      kind: AnalyticsEventKind.interruption,
      code: 'network',
      observedAtUtc: start.add(const Duration(hours: 2)),
    ),
    AnalyticsEventFact(
      kind: AnalyticsEventKind.interruption,
      code: 'phone',
      observedAtUtc: start.add(const Duration(hours: 3)),
    ),
    AnalyticsEventFact(
      kind: AnalyticsEventKind.replan,
      code: 'overrun',
      observedAtUtc: start.add(const Duration(hours: 4)),
    ),
    AnalyticsEventFact(
      kind: AnalyticsEventKind.replan,
      code: 'overrun',
      observedAtUtc: start.add(const Duration(hours: 5)),
    ),
    AnalyticsEventFact(
      kind: AnalyticsEventKind.replan,
      code: 'deadline',
      observedAtUtc: start.add(const Duration(hours: 6)),
    ),
    for (final action in ['accepted', 'accepted', 'modified', 'rejected'])
      AnalyticsEventFact(
        kind: AnalyticsEventKind.suggestion,
        code: action,
        observedAtUtc: start.add(const Duration(hours: 7)),
      ),
  ],
);

final class _MemoryAnalyticsSource implements AnalyticsDataSource {
  const _MemoryAnalyticsSource(this.dataset);
  final AnalyticsDataset dataset;

  @override
  Future<AnalyticsDataset> load(AnalyticsFilter filter) async => dataset;
}
