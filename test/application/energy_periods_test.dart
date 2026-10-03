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
}
