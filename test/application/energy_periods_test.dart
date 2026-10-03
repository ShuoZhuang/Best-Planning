// FR-STAT-05 的"不同精力时段的完成效果"。
//
// 这条链路的价值全在**归桶口径**上，因此用例钉的就是口径本身：按本地时刻、一段专注算在它
// 开始的那个区间、完成数按完成时刻、区间外的投入不计入任何一行。这些都是纯计算，用一个
// 手搭的数据集即可验证，不需要数据库。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';

/// 东八区：本机默认时区，因此"本地 09:30"对应 UTC 01:30。
final _zones = TimeZoneDatabase();
const _timeZoneId = 'Asia/Shanghai';

/// 2026-10-05 是**周一**；下面所有 UTC 时刻都指向这一个本地日。
DateTime _local(int hour, int minute, {int day = 5}) => DateTime.utc(
  2026,
  10,
  day,
  hour - 8,
  minute,
);

final class _Source implements AnalyticsDataSource {
  _Source(this.dataset);
  final AnalyticsDataset dataset;
  @override
  Future<AnalyticsDataset> load(AnalyticsFilter filter) async => dataset;
}

AnalyticsTaskFact _task(String id, {DateTime? completedAtUtc}) => AnalyticsTaskFact(
  id: id,
  title: id,
  areaId: null,
  areaName: null,
  projectId: null,
  status: completedAtUtc == null ? TaskStatus.open : TaskStatus.completed,
  estimatedMinutes: 30,
  isLifeTask: false,
  completedAtUtc: completedAtUtc,
);

void main() {
  final filter = AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 4),
    endUtc: DateTime.utc(2026, 10, 12),
  );

  AnalyticsDataset datasetWith({
    required List<AnalyticsEnergyWindow> windows,
    List<AnalyticsActualFact> actual = const [],
    List<AnalyticsTaskFact> tasks = const [],
  }) => AnalyticsDataset(
    weeklyLifeQuotaMinutes: 600,
    energyWindows: windows,
    actualEntries: actual,
    tasks: tasks,
  );

  const high = AnalyticsEnergyWindow(
    label: '高精力',
    startMinute: 9 * 60,
    endMinute: 12 * 60,
    isWeekend: false,
  );
  const low = AnalyticsEnergyWindow(
    label: '低精力',
    startMinute: 19 * 60,
    endMinute: 22 * 60,
    isWeekend: false,
  );

  Future<List<EnergyPeriodMetric>> report(AnalyticsDataset dataset) async {
    final service = AnalyticsService(
      source: _Source(dataset),
      zones: _zones,
      timeZoneId: _timeZoneId,
    );
    final result = await service.query(filter);
    return result.energyPeriods;
  }

  test('按本地时刻归桶：本地 09:30 的投入算进高精力区间', () async {
    final periods = await report(
      datasetWith(
        windows: const [high, low],
        // UTC 01:30 = 本地 09:30（周一）。
        actual: [
          AnalyticsActualFact(
            taskId: 'task-1',
            startUtc: _local(9, 30),
            endUtc: _local(10, 30),
            activeMinutes: 60,
          ),
        ],
        tasks: [_task('task-1')],
      ),
    );

    final highPeriod = periods.firstWhere((item) => item.label == '高精力');
    final lowPeriod = periods.firstWhere((item) => item.label == '低精力');
    // 若按 UTC 归桶，01:30 会落到任何区间之外，两行都会是 0——这条断言就是判别点。
    expect(highPeriod.actualMinutes, 60);
    expect(lowPeriod.actualMinutes, 0);
  });

  test('区间之外的投入不计入任何一行，而不是被塞进最近的一行', () async {
    final periods = await report(
      datasetWith(
        windows: const [high, low],
        // 本地 15:00：两个区间都不覆盖，属于"未标记时段"。
        actual: [
          AnalyticsActualFact(
            taskId: 'task-1',
            startUtc: _local(15, 0),
            endUtc: _local(16, 0),
            activeMinutes: 45,
          ),
        ],
        tasks: [_task('task-1')],
      ),
    );

    expect(periods.every((item) => item.actualMinutes == 0), isTrue);
  });

  test('完成数按**完成时刻**归桶，且只算筛选范围内的完成', () async {
    final periods = await report(
      datasetWith(
        windows: const [high, low],
        tasks: [
          _task('done-in-high', completedAtUtc: _local(10, 0)),
          _task('done-in-low', completedAtUtc: _local(20, 0)),
          // 范围之外（11 月）的完成不该计入。
          _task('done-outside', completedAtUtc: DateTime.utc(2026, 11, 2, 2)),
        ],
      ),
    );

    expect(
      periods.firstWhere((item) => item.label == '高精力').completedTasks,
      1,
    );
    expect(
      periods.firstWhere((item) => item.label == '低精力').completedTasks,
      1,
    );
  });

  test('isWeekend 为 null 的区间每天都适用，周末的投入不会被丢掉', () async {
    final periods = await report(
      datasetWith(
        windows: const [
          AnalyticsEnergyWindow(
            label: '不分平日周末',
            startMinute: 9 * 60,
            endMinute: 12 * 60,
            isWeekend: null,
          ),
        ],
        // 2026-10-10 是周六；本地 09:30。
        actual: [
          AnalyticsActualFact(
            taskId: 'task-1',
            startUtc: _local(9, 30, day: 10),
            endUtc: _local(10, 30, day: 10),
            activeMinutes: 30,
          ),
        ],
        tasks: [_task('task-1')],
      ),
    );

    expect(periods.single.actualMinutes, 30);
  });

  test('未装配时区时不产生该节，而不是按 UTC 给出错误时段', () async {
    final service = AnalyticsService(
      source: _Source(
        datasetWith(
          windows: const [high],
          actual: [
            AnalyticsActualFact(
              taskId: 'task-1',
              startUtc: _local(9, 30),
              endUtc: _local(10, 30),
              activeMinutes: 60,
            ),
          ],
          tasks: [_task('task-1')],
        ),
      ),
    );

    final result = await service.query(filter);
    expect(result.energyPeriods, isEmpty);
  });

  // FR-STAT-05 的"休息保护情况"。
  //
  // 口径：保护总时长是本地保护段与筛选范围的交集之和；被占用是这些区间与实际专注的重叠，
  // 并按每段专注的**实际占比**折算。后者是本文件里最容易做错的一处，因此专门钉一条。
  const lunch = AnalyticsProtectedWindow(
    label: '午餐',
    startMinute: 12 * 60,
    endMinute: 13 * 60,
    isWeekend: null,
  );

  AnalyticsDataset withLunch({
    List<AnalyticsActualFact> actual = const [],
  }) => AnalyticsDataset(
    weeklyLifeQuotaMinutes: 600,
    protectedWindows: const [lunch],
    actualEntries: actual,
    // 服务会先按**筛选出的任务**过滤实际投入，因此这些条目必须带有对应任务，否则会被整条
    // 丢掉——本文件第一版夹具正是漏了这一点，"被占用"因此恒为 0，是用例把错误顶了出来。
    tasks: [for (final entry in actual) _task(entry.taskId)],
  );

  Future<RestProtectionMetric?> protection(AnalyticsDataset dataset) async {
    final service = AnalyticsService(
      source: _Source(dataset),
      zones: _zones,
      timeZoneId: _timeZoneId,
    );
    final result = await service.query(filter);
    return result.restProtection;
  }

  test('休息保护：保护总时长按本地日累计（含周末，因为 dayKind 为 any）', () async {
    // 2026-10-04 到 10-12 共 8 个本地日，每天 60 分钟午餐保护。
    final metric = await protection(withLunch());

    expect(metric!.protectedMinutes, 60 * 8);
    expect(metric.overlappedMinutes, 0);
    expect(metric.preservedMinutes, 60 * 8);
  });

  test('休息保护：被专注占用按**实际时长**折算，而不是按挂钟时长', () async {
    // 本地 12:30–12:40 的专注：挂钟 10 分钟，但实际只专注了 4 分钟（其余是暂停）。
    // 若按挂钟算，被占用会记 10 分钟——这条断言就是判别点。
    final metric = await protection(
      withLunch(
        actual: [
          AnalyticsActualFact(
            taskId: 'task-1',
            startUtc: _local(12, 30),
            endUtc: _local(12, 40),
            activeMinutes: 4,
          ),
        ],
      ),
    );

    expect(metric!.overlappedMinutes, 4);
    expect(metric.protectedMinutes, 60 * 8);
  });

  test('休息保护：保护时段之外的专注不算占用休息', () async {
    final metric = await protection(
      withLunch(
        actual: [
          AnalyticsActualFact(
            taskId: 'task-1',
            startUtc: _local(9, 0),
            endUtc: _local(10, 0),
            activeMinutes: 60,
          ),
        ],
      ),
    );

    expect(metric!.overlappedMinutes, 0);
  });

  test('休息保护：没有保护时段或没有时区时不产生该节', () async {
    final withoutWindows = await protection(
      AnalyticsDataset(weeklyLifeQuotaMinutes: 600, tasks: const []),
    );
    expect(withoutWindows, isNull);

    final withoutZones = AnalyticsService(
      source: _Source(withLunch()),
    );
    final report = await withoutZones.query(filter);
    expect(report.restProtection, isNull);
  });

  test('休息保护：跨午夜的保护段按"跨到次日"计算（睡眠就是这一段）', () async {
    // 睡眠默认 23:00–07:00，是这个产品里最主要的一段"休息"，而它跨午夜。此前服务侧对
    // `endMinute <= startMinute` 直接 `continue` 跳过——那句话对当时的数据（只有午餐、晚餐、
    // 固定休息）是对的，但睡眠恰恰必须被算进来。
    const sleep = AnalyticsProtectedWindow(
      label: '睡眠',
      startMinute: 23 * 60,
      endMinute: 7 * 60,
      isWeekend: null,
    );
    final dataset = AnalyticsDataset(
      weeklyLifeQuotaMinutes: 600,
      protectedWindows: const [sleep],
      tasks: const [],
    );

    final metric = await protection(dataset);

    // 筛选范围是 10-04 到 10-12 共 8 个本地日，每天 8 小时 = 480 分钟，合计 3840。
    // 首日 23:00 起的窗口落在范围内，末日 23:00 起的窗口在次日 07:00 结束——
    // 服务侧会把超出筛选范围的部分裁掉，因此这里逐日累加得到 8×480。
    expect(metric!.protectedMinutes, 480 * 8);
    expect(metric.overlappedMinutes, 0);
  });

  test('休息保护：把夜里的专注算作占用睡眠', () async {
    const sleep = AnalyticsProtectedWindow(
      label: '睡眠',
      startMinute: 23 * 60,
      endMinute: 7 * 60,
      isWeekend: null,
    );
    final dataset = AnalyticsDataset(
      weeklyLifeQuotaMinutes: 600,
      protectedWindows: const [sleep],
      // 本地 10-05 00:30–01:00（夜里）实际专注 20 分钟。
      actualEntries: [
        AnalyticsActualFact(
          taskId: 'task-1',
          startUtc: _local(0, 30, day: 5),
          endUtc: _local(1, 0, day: 5),
          activeMinutes: 20,
        ),
      ],
      tasks: [_task('task-1')],
    );

    final metric = await protection(dataset);

    expect(
      metric!.overlappedMinutes,
      20,
      reason: '零点之后的专注属于**前一天** 23:00 起的那段睡眠，跨午夜判定错就会漏掉它',
    );
    expect(metric.protectedMinutes, 480 * 8);
  });

  test('休息保护：只统计落在筛选范围内的临时放宽日', () async {
    // 数据层把"哪些天有按日例外"原样交出，是否落在范围内由服务层按**本地日**判断
    // （时区只有服务层有）。用 UTC 瞬时去比会在时区偏移下把边界那天算错。
    final dataset = AnalyticsDataset(
      weeklyLifeQuotaMinutes: 600,
      protectedWindows: const [lunch],
      relaxedLocalDates: [
        DateTime.utc(2026, 10, 5), // 范围内
        DateTime.utc(2026, 10, 12), // 末日，仍在范围内
        DateTime.utc(2026, 10, 20), // 范围外
        DateTime.utc(2026, 10, 3), // 范围前
      ],
      tasks: const [],
    );

    final metric = await protection(dataset);

    expect(metric!.relaxedDays, 2);
  });

  test('休息保护：没有放宽时计数为 0（界面据此不显示那句话）', () async {
    final metric = await protection(withLunch());

    expect(metric!.relaxedDays, 0);
  });

  test('休息保护：文案点明数字包含睡眠，放宽过才提放宽天数', () {
    // 文案有真实分支，因此放在领域模型上直接断言——放在页面里就只能靠 widget 测试去够它，
    // 而它所在的那张卡在 `ListView` 里、视口外**根本不会被构建**（本轮第一版页面用例正是
    // 因此一无所获）。**必须点明"睡眠与保护时段"**：这个数字包含睡眠（每天 8 小时上下），
    // 只说"保护 N 分钟"会让用户以为它只算午餐和固定休息。
    expect(
      const RestProtectionMetric(
        protectedMinutes: 3840,
        overlappedMinutes: 20,
        relaxedDays: 2,
      ).summaryLabel,
      '休息保护：睡眠与保护时段共 3840 分钟，其中被专注占用 20 分钟，'
      '其中 2 天临时放宽过每日上限',
    );
    // 没有放宽过时不拖一句"0 天"。
    expect(
      const RestProtectionMetric(
        protectedMinutes: 3840,
        overlappedMinutes: 0,
      ).summaryLabel,
      '休息保护：睡眠与保护时段共 3840 分钟，其中被专注占用 0 分钟',
    );
  });

  test('休息保护：以 24:00 结束的保护段不会炸，也不会被算成跨午夜', () async {
    // `LocalTimeRange` 允许 `endMinute == 1440`（09:00–24:00 合法且**不**跨午夜），而
    // `localDateTimeToUtc` 只接受 [0, 1439]。统计侧此前直接把 endMinute 传进去，遇到 24:00
    // 会抛参数错误让整个查询失败——§13.0 的 C11 在保护时间展开器上记过同一处（"类型允许、
    // 运行必炸"），统计侧只是从未被触发。
    const evening = AnalyticsProtectedWindow(
      label: '固定休息',
      startMinute: 22 * 60,
      endMinute: 24 * 60,
      isWeekend: null,
    );
    final metric = await protection(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 600,
        protectedWindows: const [evening],
        tasks: const [],
      ),
    );

    // 每天 2 小时 = 120 分钟，8 天。
    expect(metric!.protectedMinutes, 120 * 8);
  });
}
