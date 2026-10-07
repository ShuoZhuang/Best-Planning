// 2026-10-06 统计复盘改版的四项新指标。
//
// 用户确认的清单是：规划合理性 =「领域覆盖缺口」+「完成率/按期完成/逾期率」；
// 好好休息 = A 休息时长本身、C 作息规律性、D 工作与休息比例。
// 三项都必须**只依赖计划侧数据**——用户明确要求把实际投入从统计里拿掉，因此下面每一条都
// 刻意不喂 `actualEntries`：只要实现里偷偷读了它，断言就会失败。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';

/// 固定返回一份数据集的数据源。
final class _Source implements AnalyticsDataSource {
  const _Source(this.dataset);
  final AnalyticsDataset dataset;

  @override
  Future<AnalyticsDataset> load(AnalyticsFilter filter) async => dataset;
}

// 七天范围：本地 2026-10-05 00:00 → 2026-10-12 00:00（东八区）。
final _start = DateTime.utc(2026, 10, 4, 16);
final _end = DateTime.utc(2026, 10, 11, 16);
final _zones = TimeZoneDatabase();
const _zoneId = 'Asia/Shanghai';

AnalyticsFilter _filter() => AnalyticsFilter(startUtc: _start, endUtc: _end);

/// 本地时刻 → UTC（东八区固定 +08:00，测试里直接用减法，避免依赖时区库的内部行为）。
DateTime _local(int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(2026, month, day, hour - 8, minute);

AnalyticsTaskFact _task(
  String id, {
  required bool life,
  String? areaName,
  String? areaId,
}) => AnalyticsTaskFact(
  id: id,
  title: '任务 $id',
  areaId: areaId ?? (areaName == null ? null : 'area-$id'),
  areaName: areaName,
  projectId: null,
  status: TaskStatus.open,
  estimatedMinutes: 60,
  isLifeTask: life,
);

void main() {
  Future<AnalyticsReport> run(AnalyticsDataset dataset) => AnalyticsService(
    source: _Source(dataset),
    zones: _zones,
    timeZoneId: _zoneId,
  ).query(_filter());

  test('A：休息时长按天累加，且首夜的跨午夜后半段不能被漏掉', () async {
    // 睡眠 23:00–07:00 = 每天 480 分钟，跨午夜。七天应当是 7 × 480 = 3360。
    // 此前逐日展开从**范围首日**开始，于是首日 00:00–07:00 那一段（锚定在**前一天**）被整个
    // 漏掉，只报 2940 —— 界面上一除就成"平均每天只睡 6 小时"。
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        protectedWindows: const [
          AnalyticsProtectedWindow(
            label: '睡眠',
            startMinute: 23 * 60,
            endMinute: 7 * 60,
            isWeekend: null,
          ),
        ],
      ),
    );

    final rest = report.restSummary!;
    expect(rest.windows, hasLength(1));
    expect(rest.windows.single.label, '睡眠');
    expect(rest.windows.single.minutes, 3360);
    expect(rest.windows.single.invadedMinutes, 0);
    expect(rest.days, 7, reason: '排他上界不能多算一天');
    expect(rest.averageDailyMinutes, 480);
    expect(rest.achievedRatio, 1);
  });

  test('A：排进睡眠时段的计划算作被侵占，达成率随之下降', () async {
    // 一段 23:30–00:30（本地）的计划落在睡眠里，侵占 60 分钟。
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        protectedWindows: const [
          AnalyticsProtectedWindow(
            label: '睡眠',
            startMinute: 23 * 60,
            endMinute: 7 * 60,
            isWeekend: null,
          ),
        ],
        tasks: [_task('a', life: false, areaName: '学业')],
        plannedBlocks: [
          AnalyticsPlannedFact(
            taskId: 'a',
            startUtc: _local(10, 6, 23, 30),
            endUtc: _local(10, 7, 0, 30),
          ),
        ],
      ),
    );

    final rest = report.restSummary!;
    expect(rest.windows.single.minutes, 3360);
    expect(rest.windows.single.invadedMinutes, 60);
    expect(rest.invadedMinutes, 60);
    expect(rest.freeMinutes, 3300);
    expect(rest.achievedRatio, closeTo(3300 / 3360, 1e-9));
  });

  test('A：09:00–24:00 这种 endMinute=1440 的保护段不会让整次查询炸掉', () async {
    // §13.0 的 C11：`localDateTimeToUtc` 只接受 [0, 1439]，把 1440 直接传下去会抛参数错误，
    // 而 `LocalTimeRange` 明确允许 1440。这里钉住"统计侧的展开器也处理了它"。
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        protectedWindows: const [
          AnalyticsProtectedWindow(
            label: '固定休息',
            startMinute: 9 * 60,
            endMinute: 24 * 60,
            isWeekend: null,
          ),
        ],
      ),
    );

    // 09:00–24:00 = 900 分钟/天 × 7 天。
    expect(report.restSummary!.windows.single.minutes, 6300);
  });

  test('C：作息规律性看的是开工/收工时刻的散布，而不是"几点最密"', () async {
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        fixedEvents: [
          // 第 1 天：08:00–09:40
          AnalyticsFixedFact(
            title: '早课',
            areaId: 'study',
            areaName: '学业',
            isLife: false,
            startUtc: _local(10, 5, 8),
            endUtc: _local(10, 5, 9, 40),
          ),
          // 第 2 天：19:00–20:40
          AnalyticsFixedFact(
            title: '晚课',
            areaId: 'study',
            areaName: '学业',
            isLife: false,
            startUtc: _local(10, 6, 19),
            endUtc: _local(10, 6, 20, 40),
          ),
        ],
      ),
    );

    final routine = report.routine;
    expect(routine.perDay, hasLength(2));
    expect(routine.earliestMinute, 8 * 60);
    expect(routine.latestMinute, 20 * 60 + 40);
    // 开工相差 11 小时、收工相差 11 小时 —— 这就是"不规律"的可读形式。
    expect(routine.startSpreadMinutes, 11 * 60);
    expect(routine.endSpreadMinutes, 11 * 60);
    expect(routine.averageStartMinute, (8 * 60 + 19 * 60) ~/ 2);
    expect(routine.averageEndMinute, ((9 * 60 + 40) + (20 * 60 + 40)) ~/ 2);
  });

  test('C：没有安排的日子不出现在作息里，也不是"0 点开工"', () async {
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        fixedEvents: [
          AnalyticsFixedFact(
            title: '唯一一节课',
            areaId: 'study',
            areaName: '学业',
            isLife: false,
            startUtc: _local(10, 7, 10),
            endUtc: _local(10, 7, 11),
          ),
        ],
      ),
    );

    expect(report.routine.perDay, hasLength(1));
    expect(report.routine.perDay.single.firstMinute, 10 * 60);
    expect(report.routine.startSpreadMinutes, 0);
  });

  test('D：工作/生活/休息/未安排四段加起来正好是整个范围', () async {
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        protectedWindows: const [
          AnalyticsProtectedWindow(
            label: '睡眠',
            startMinute: 23 * 60,
            endMinute: 7 * 60,
            isWeekend: null,
          ),
        ],
        tasks: [
          _task('work', life: false, areaName: '学业'),
          _task('life', life: true, areaName: '生活'),
        ],
        plannedBlocks: [
          // 非生活领域：09:00–10:00 = 60 分钟工作
          AnalyticsPlannedFact(
            taskId: 'work',
            startUtc: _local(10, 5, 9),
            endUtc: _local(10, 5, 10),
          ),
        ],
        fixedEvents: [
          // 生活领域：12:00–13:00 = 60 分钟生活
          AnalyticsFixedFact(
            title: '午休散步',
            areaId: 'life-area',
            areaName: '生活',
            isLife: true,
            startUtc: _local(10, 5, 12),
            endUtc: _local(10, 5, 13),
          ),
        ],
      ),
    );

    final ratio = report.workRest!;
    expect(ratio.workMinutes, 60);
    expect(ratio.lifeMinutes, 60);
    // 睡眠 3360 全空着（没有任何安排排进去）。
    expect(ratio.restMinutes, 3360);
    expect(ratio.idleMinutes, 7 * 1440 - 60 - 60 - 3360);
    expect(ratio.totalMinutes, 7 * 1440, reason: '四段必须不重不漏地覆盖整个范围');
    expect(ratio.restRatio, closeTo((60 + 3360) / (7 * 1440), 1e-9));
  });

  test('D：把任务排进睡眠会同时减少"休息"——不能因为排了就算休息充足', () async {
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        protectedWindows: const [
          AnalyticsProtectedWindow(
            label: '睡眠',
            startMinute: 23 * 60,
            endMinute: 7 * 60,
            isWeekend: null,
          ),
        ],
        tasks: [_task('work', life: false, areaName: '学业')],
        plannedBlocks: [
          AnalyticsPlannedFact(
            taskId: 'work',
            startUtc: _local(10, 6, 23, 0),
            endUtc: _local(10, 7, 1, 0),
          ),
        ],
      ),
    );

    final ratio = report.workRest!;
    expect(ratio.workMinutes, 120);
    expect(ratio.restMinutes, 3360 - 120, reason: '被占的两小时不算休息');
    expect(ratio.totalMinutes, 7 * 1440);
  });

  test('#2：领域覆盖缺口指出零占用的领域', () async {
    final report = await run(
      AnalyticsDataset(
        weeklyLifeQuotaMinutes: 0,
        areas: const [
          AnalyticsAreaFact(id: 'a1', name: '学业', isLife: false),
          AnalyticsAreaFact(id: 'a2', name: '科研', isLife: false),
          AnalyticsAreaFact(id: 'a3', name: '生活', isLife: true),
        ],
        // 只有"学业"有占用：另外两个领域应当出现在缺口里。
        tasks: [_task('t1', life: false, areaName: '学业', areaId: 'a1')],
        plannedBlocks: [
          AnalyticsPlannedFact(
            taskId: 't1',
            startUtc: _local(10, 5, 9),
            endUtc: _local(10, 5, 10),
          ),
        ],
      ),
    );

    final coverage = report.areaCoverage!;
    expect(coverage.totalAreas, 3);
    expect(coverage.covered, ['学业']);
    expect(coverage.uncovered, ['生活', '科研']);
    expect(coverage.coverageRatio, closeTo(1 / 3, 1e-9));
    expect(coverage.allCovered, isFalse);
  });

  test('没有任何保护时间时 D 返回 null，而不是一个分母残缺的比例', () async {
    final report = await run(AnalyticsDataset(weeklyLifeQuotaMinutes: 0));

    expect(report.restSummary, isNull);
    expect(report.workRest, isNull);
    expect(report.areaCoverage, isNull, reason: '一个领域都没有时不算覆盖率');
    expect(report.routine.isEmpty, isTrue);
  });
}
